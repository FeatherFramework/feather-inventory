local function copy(v) if type(v)~='table' then return v end; local r={}; for k,x in pairs(v) do r[k]=copy(x) end; return r end
local docs,n={},0
json={encode=function(v) n=n+1; docs[tostring(n)]=copy(v); return tostring(n) end,decode=function(v) return copy(assert(docs[v])) end}
Result={Codes={INVALID_INPUT='invalid',DENIED='denied',NOT_FOUND='missing',CONFLICT='conflict'},
 Ok=function(v) return {ok=true,value=v} end,Err=function(c,m) return {ok=false,error={code=c,message=m}} end}
Config={DevMode=true,CharacterAmmunitionEnabled=true}
InventoryIdentity={NormalizeCharacterId=function(v) return v=='john' and v end}
RegisterCommand=function() end
local gate=1
GetConvarInt=function(name) return name=='feather_native_throwable_pickup' and gate or 0 end
dofile('server/services/character_ammunition.lua')
dofile('server/services/native_throwable_native_pickup_credits.lua')
local claim=dofile('server/internal/native_throwable_native_pickup_claim.lua')
local limits={ammo_tomahawk_regular=1,ammo_repeater_regular=10}
local context={characterId='john',sessionId='s',runtimeEpoch='e',runtimeTicket='ticket'}
local db,authority,assigned,fail,updates,lose
NativeThrowableEquipment={Read=function(_,cid,_,current)
 assert(cid=='john' and current())
 return Result.Ok({expected=assigned and {weapon_throwable={itemId=165,revision=0}} or {},
  equipment=assigned and {throwable={id=165,revision=0,itemName='weapon_thrown_tomahawk',
   metadata={schemaVersion=2,weaponDefinitionId='throwable_tomahawk',serialNumber='T',condition=100,
    ammo={ownership='character',type='ammo_tomahawk_regular'}}}} or {}})
end}
local tx={query=function(sql,p)
 if sql:find('SELECT id FROM inventory',1,true) then return {{id=5}} end
 if sql:find('SELECT revision, pools',1,true) then return {{revision=db.revision,pools=json.encode(db.pools)}} end
 if sql:find('INSERT IGNORE',1,true) then
  db.receipt=db.receipt or {request_fingerprint=p[3]}; return {affectedRows=1}
 end
 if sql:find('SELECT request_fingerprint',1,true) or sql:find('SELECT result_json',1,true) then return db.receipt and {copy(db.receipt)} or {} end
 updates=updates+1; if updates==fail then return {affectedRows=0} end
 if sql:find('UPDATE feather_character_ammunition',1,true) then
  assert(p[4]==db.revision); db.pools=json.decode(p[1]); db.revision=p[2]
 elseif sql:find('UPDATE inventory_grant_receipts',1,true) then db.receipt.result_json=p[1]
 else error('forbidden SQL/grant: '..sql) end
 if updates==lose then authority=false end
 return {affectedRows=1}
end}
local function reset()
 db={revision=10,pools={ammo_tomahawk_regular=1,ammo_repeater_regular=3}}
 gate=1; authority=true; assigned=true; fail=nil; updates=0; lose=nil
end
local function observe(extra)
 local spec={expectedRevision=10,pools={ammo_tomahawk_regular=0,ammo_repeater_regular=3},limits=limits}
 if extra then for k,v in pairs(extra) do spec[k]=v end end
 local before=copy(db)
 local ok,result=pcall(CharacterAmmunitionAPI.ApplyObservation,tx,context,spec,function() return authority end)
 if not ok or not result.ok then db=before end
 assert(ok,result); return result
end
reset(); local result=observe()
assert(result.ok and result.value.nativePickupSpendReceiptId=='spend:165:11' and db.revision==11)
local record=json.decode(db.receipt.result_json)
assert(record.phase=='committed_unclaimed' and record.before.pools.ammo_tomahawk_regular==1
 and record.after.pools.ammo_tomahawk_regular==0 and record.candidate.identity.epoch=='e'
 and record.candidate.key.revisionAfter==11 and record.snapshot.expected.weapon_throwable.itemId==165)
local plan={version=1,kind='native_pickup_ledger_plan',policy=record.policy,units=1,requiresAtomicSpendClaim=true,
 requiresLedgerCAS=true,looseInventoryDelta=0,nativeAmmoDelta=0,pickupCredits=false,originConfirmed=false,
 spendReceiptId=record.receiptId,spendKey=copy(record.candidate.key),identity=copy(record.candidate.identity),
 itemId=165,itemRevision=0,serialNumber='T',expectedRevision=11,revision=12,
 pools={ammo_tomahawk_regular=1,ammo_repeater_regular=3}}
local recovered=claim.Apply(tx,{characterId='john',sessionId='s',epoch='e'},plan,limits,function() return authority end)
assert(recovered.ok and db.revision==12 and db.pools.ammo_tomahawk_regular==1)
db.revision=13; db.pools.ammo_tomahawk_regular=0
local replay=claim.Apply(tx,{characterId='john',sessionId='s',epoch='e'},plan,limits,function() return authority end)
assert(replay.ok and replay.value.replayed and db.revision==13 and db.pools.ammo_tomahawk_regular==0)
local before={revision=10,pools=copy(record.before.pools)}
local after={revision=11,pools=copy(record.after.pools)}
db.revision=11 -- independently test recorded-receipt replay after claim cannot reopen it
assert(not NativeThrowableNativePickupCredits.Record(tx,context,before,after,limits,function() return true end).ok)
assert(json.decode(db.receipt.result_json).phase=='claimed')
for _,mutate in ipairs({function() fail=1 end,function() fail=2 end,function() lose=1 end,function() lose=2 end,function() assigned=false end,
 function() authority=false end}) do
 reset(); mutate(); assert(not observe().ok and db.revision==10 and db.receipt==nil)
end
reset(); gate=0; assert(observe().ok and db.revision==11 and db.receipt==nil,'disabled writer preserves existing consumption')
reset(); assert(observe({finalWear={}}).ok and db.receipt==nil,'death/final seal cannot mint pickup allowance')
reset(); assert(observe({pools={ammo_tomahawk_regular=1,ammo_repeater_regular=3}}).ok and db.revision==10 and db.receipt==nil)
reset(); assert(not observe({pools={ammo_tomahawk_regular=2,ammo_repeater_regular=3}}).ok and db.revision==10 and db.receipt==nil)
reset()
local cfx=setmetatable({__cfx_functionReference='local-test'},{__call=function() return authority end})
assert(CharacterAmmunitionAPI.ApplyObservation(tx,context,
 {expectedRevision=10,pools={ammo_tomahawk_regular=0,ammo_repeater_regular=3},limits=limits},cfx).ok,
 'callable CFX authority references are supported')
print('native pickup spend composition PASS: actual observation+receipt+claim bodies, rollback, replay, final/idle/default-off isolation; mocked SQL')
