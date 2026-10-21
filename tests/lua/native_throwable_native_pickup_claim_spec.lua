local function copy(v) if type(v)~='table' then return v end; local r={}; for k,x in pairs(v) do r[k]=copy(x) end; return r end
local docs,n={},0
json={encode=function(v) n=n+1; docs[tostring(n)]=copy(v); return tostring(n) end,decode=function(v) return copy(assert(docs[v])) end}
Result={Ok=function(v) return {ok=true,value=v} end,Err=function(c,m) return {ok=false,error={code=c,message=m}} end}
local claim=dofile('server/internal/native_throwable_native_pickup_claim.lua')
local context={characterId='john',sessionId='s',epoch='e'}
local limits={ammo_tomahawk_regular=1,ammo_repeater_regular=10}
local plan={version=1,kind='native_pickup_ledger_plan',policy='same_session_native_spend_credit_v1',units=1,
 requiresAtomicSpendClaim=true,requiresLedgerCAS=true,looseInventoryDelta=0,nativeAmmoDelta=0,
 pickupCredits=false,originConfirmed=false,spendReceiptId='s11',identity=copy(context),itemId=165,itemRevision=0,
 serialNumber='T',expectedRevision=11,revision=12,pools={ammo_tomahawk_regular=1,ammo_repeater_regular=3},
 spendKey={characterId='john',sessionId='s',epoch='e',ammunitionId='ammo_tomahawk_regular',revisionBefore=10,revisionAfter=11}}
local db,authority,fail,lose,updates,assigned
local function reset()
 authority=true; fail=nil; lose=nil; updates=0; assigned=true
 db={ledger={characterId='john',revision=11,pools={ammo_tomahawk_regular=0,ammo_repeater_regular=3}},
  credit={receiptId='s11',policy=plan.policy,phase='committed_unclaimed',candidate={identity=copy(context),
   key=copy(plan.spendKey),itemId=165,itemRevision=0,serialNumber='T',units=1,definitionId='throwable_tomahawk'}}}
end
CharacterAmmunitionAPI={ReadSnapshot=function(_,cid,ls,equipment)
 assert(cid=='john' and ls.ammo_tomahawk_regular==1 and equipment==false)
 return Result.Ok(copy(db.ledger))
end}
NativeThrowableEquipment={Read=function(_,cid,id,current)
 assert(cid=='john' and id==165 and current())
 return Result.Ok({equipment=assigned and {throwable={id=165,revision=0,metadata={serialNumber='T'}}} or {},
  expected=assigned and {weapon_throwable={itemId=165,revision=0}} or {}})
end}
local tx={query=function(sql,p)
 if sql:find('SELECT result_json',1,true) then
  assert(p[1]=='native-tomahawk-native-spend-v1' and p[2]=='s11')
  return db.credit and {{result_json=json.encode(db.credit)}} or {}
 end
 updates=updates+1
 if updates==fail then return {affectedRows=0} end
 if sql:find('UPDATE feather_character_ammunition',1,true) then
  assert(p[3]=='john' and p[4]==db.ledger.revision)
  db.ledger.pools=json.decode(p[1]); db.ledger.revision=p[2]
 elseif sql:find('UPDATE inventory_grant_receipts',1,true) then db.credit=json.decode(p[1])
 else error('forbidden SQL/native/loose grant: '..sql) end
 if updates==lose then authority=false end
 return {affectedRows=1}
end}
local function run(p,c)
 local before=copy(db)
 local ok,r=pcall(claim.Apply,tx,c or context,p or plan,limits,function() return authority end)
 if not ok or not r.ok then db=before end
 assert(ok,r); return r
end
reset(); assert(run().ok and db.ledger.revision==12 and db.ledger.pools.ammo_tomahawk_regular==1 and db.credit.phase=='claimed')
db.ledger.revision=13; db.ledger.pools.ammo_tomahawk_regular=0
local writesBeforeReplay=updates
local replay=run(); assert(replay.ok and replay.value.replayed and db.ledger.revision==13 and db.ledger.pools.ammo_tomahawk_regular==0,
 'duplicate claim after another spend cannot replenish')
assert(updates==writesBeforeReplay,'exact receipt replay performs no economic writes')
for _,mutate in ipairs({
 function(p) p.identity.sessionId='replacement' end,
 function(p) p.identity.epoch='replacement' end,
 function(p) p.itemId=166 end,
 function(p) p.itemRevision=1 end,
 function(p) p.serialNumber='replacement' end,
 function(p) p.pools.ammo_repeater_regular=4 end,
 function(p) p.spendKey.revisionAfter=12 end,
}) do
 local p=copy(plan); mutate(p)
 assert(not run(p).ok and updates==writesBeforeReplay,
  'claimed receipt cannot be rebound to a modified identity, carrier, key or balance')
end
-- Returning a stored result must not expose the persisted receipt to mutation.
replay.value.pools.ammo_tomahawk_regular=999
local replayAgain=run()
assert(replayAgain.ok and replayAgain.value.pools.ammo_tomahawk_regular==1
 and db.ledger.pools.ammo_tomahawk_regular==0 and updates==writesBeforeReplay)
local altered=copy(plan); altered.expectedRevision=13; altered.revision=14
assert(not run(altered).ok,'fresh request cannot reuse claimed spend')
for i=1,2 do
 reset(); fail=i; assert(not run().ok and db.ledger.revision==11 and db.credit.phase=='committed_unclaimed')
 fail=nil; assert(run().ok)
 reset(); lose=i; assert(not run().ok and db.ledger.revision==11 and db.credit.phase=='committed_unclaimed')
end
for _,mutate in ipairs({function() db.credit=nil end,function() db.credit.phase='other' end,
 function() db.credit.candidate.identity.epoch='other' end,function() db.credit.candidate.key.revisionAfter=12 end,
 function() db.credit.candidate.serialNumber='other' end,function() db.ledger.revision=12 end,
 function() assigned=false end,function() authority=false end}) do
 reset(); mutate(); assert(not run().ok)
end
for _,mutate in ipairs({function(p) p.pools.ammo_repeater_regular=4 end,function(p) p.pools.ammo_repeater_regular=nil end,
 function(p) p.pools.foreign=0 end,function(p) p.units=2 end,function(p) p.nativeAmmoDelta=1 end,
 function(p) p.looseInventoryDelta=1 end,function(p) p.originConfirmed=true end}) do
 reset(); local p=copy(plan); mutate(p); assert(not run(p).ok and db.ledger.revision==11)
end
reset(); local other=copy(context); other.sessionId='new'; assert(not run(nil,other).ok)
print('inactive native pickup claim PASS: ledger CAS + spend claim transaction, replay no replenishment, rollback/authority/carrier isolation')
