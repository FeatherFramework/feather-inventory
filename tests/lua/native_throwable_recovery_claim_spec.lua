-- Real claim body, mocked transactional SQL/Inventory ports; no live origin proof.
local function copy(v) if type(v)~='table' then return v end; local r={}; for k,x in pairs(v) do r[k]=copy(x) end; return r end
local docs,n={},0
json={encode=function(v) n=n+1; docs[tostring(n)]=copy(v); return tostring(n) end,
 decode=function(v) return copy(assert(docs[v])) end}
Result={Ok=function(v) return {ok=true,value=v} end,Err=function(c,m) return {ok=false,error={code=c,message=m}} end}
local claim=dofile('server/internal/native_throwable_recovery_claim.lua')
local context={characterId='john',sessionId='session',epoch='epoch'}
local plan={version=1,kind='projectile_binding_plan',units=1,pickupCredits=false,requiresAtomicSingleClaim=true,
 requiresCurrentProjectile=true,requiresPickupProximity=true,spendReceiptId='s11',projectileInstanceId='boot:1',originEventId='o1',
 identity=copy(context),itemId=165,itemRevision=0,serialNumber='T',networkId=70,
 spendKey={characterId='john',sessionId='session',epoch='epoch',revisionBefore=10,revisionAfter=11,ammunitionId='ammo_tomahawk_regular'}}
local db,authority,failUpdate,failAdd,lose,updates
local function key(ns,id) return ns..'/'..id end
local function seed(p)
 db.rows[key('native-tomahawk-spend-v1',p.spendReceiptId)]={request_fingerprint='spend',result_json=json.encode({
  receiptId=p.spendReceiptId,phase='committed_unclaimed',candidate={identity=copy(p.identity),key=copy(p.spendKey),
   itemId=p.itemId,itemRevision=p.itemRevision,serialNumber=p.serialNumber,units=1,definitionId='throwable_tomahawk'}})}
 db.rows[key('native-tomahawk-binding-v1',p.spendReceiptId)]={request_fingerprint='binding',result_json=json.encode({verified=true,plan=copy(p)})}
end
local function reset()
 db={rows={},loose=0}; authority=true; failUpdate=nil; failAdd=false; lose=false; updates=0; seed(plan)
end
local tx={}
function tx.query(sql,p)
 if sql:find('SELECT id FROM inventory',1,true) then return {{id=5}} end
 if sql:find('SELECT request_fingerprint',1,true) then
  local row=db.rows[key(p[1],p[2])]; return row and {copy(row)} or {}
 end
 if sql:find('INSERT IGNORE',1,true) then
  local k=key(p[1],p[2]); db.rows[k]=db.rows[k] or {request_fingerprint=p[3]}; return {affectedRows=1}
 end
 if sql:find('SELECT id,type,instance_mode',1,true) then return {{id=93,type='item_ammo',instance_mode='stack'}} end
 if sql:find('UPDATE inventory_grant_receipts',1,true) then
  updates=updates+1; if updates==failUpdate then return {affectedRows=0} end
  db.rows[key(p[2],p[3])].result_json=p[1]; return {affectedRows=1}
 end
 error('unexpected SQL or forbidden carried-ammo/native/item metadata write: '..sql)
end
function tx:AddQuantity(inv,id,qty)
 assert(inv==5 and id==93 and qty==1)
 if failAdd then return Result.Err('capacity','full') end
 db.loose=db.loose+1; if lose then authority=false end; return Result.Ok({170})
end
local function run(p,c)
 local before=copy(db); local ok,r=pcall(claim.Apply,tx,c or context,p or plan,function() return authority end)
 if not ok or not r.ok then db=before end
 assert(ok,r); return r
end
reset(); assert(run().ok and db.loose==1)
db.loose=0; local replay=run(); assert(replay.ok and replay.value.replayed and db.loose==0,'retry after spending cannot replenish')
local alternative=copy(plan); alternative.spendReceiptId='s12'; alternative.spendKey.revisionBefore=11; alternative.spendKey.revisionAfter=12
seed(alternative); assert(not run(alternative).ok and db.loose==0,'second spend cannot reuse projectile or origin')
alternative.projectileInstanceId='boot:2'; seed(alternative)
assert(not run(alternative).ok and db.loose==0,'new projectile ID cannot reuse claimed origin')
for failure=1,4 do
 reset(); failUpdate=failure; assert(not run().ok and db.loose==0)
 for k in pairs(db.rows) do assert(not k:find('native-tomahawk-claim-v1',1,true),'rollback removes partial receipt reservations') end
 failUpdate=nil; assert(run().ok and db.loose==1)
end
reset(); lose=true; assert(not run().ok and db.loose==0); authority=true; lose=false; assert(run().ok and db.loose==1)
reset(); failAdd=true; assert(not run().ok and db.loose==0)
reset(); authority=false; assert(not run().ok and db.loose==0)
reset(); local other=copy(context); other.characterId='jane'; assert(not run(nil,other).ok)
reset(); db.rows[key('native-tomahawk-binding-v1','s11')]=nil; assert(not run().ok)
reset(); db.rows[key('native-tomahawk-spend-v1','s11')]=nil; assert(not run().ok)
reset(); local forged=copy(plan); forged.itemId=166; assert(not run(forged).ok)
local f=assert(io.open('fxmanifest.lua')); local manifest=f:read('*a'); f:close()
assert(not manifest:find('server/internal/native_throwable_recovery_claim.lua',1,true),'exact-origin loose-item recovery primitive remains inactive')
print('inactive recovery claim PASS: durable spend/binding required, three unique receipts, loose-only credit/replay, rollback and replacement-origin refusal; mocked SQL')
