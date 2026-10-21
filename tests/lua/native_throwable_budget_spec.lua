local john='4560a489-ca6c-11f1-9ad4-e0d55eaa2deb'
Config={DevMode=true,CharacterAmmunitionEnabled=true,TrustedIdempotentGrantCallers={}}
InventoryReadiness={state='ready'}
Result={Ok=function(v) return {ok=true,value=v} end,Err=function(c,m) return {ok=false,error={code=c,message=m}} end}
InventoryIdentity={NormalizeCharacterId=function(v) return v==john and v or nil end}
IsCallable=nil -- production grants scope has no shared callable helper
local commands,scope,current,character={},'0',true,john
local deathScope,pickupScope,expectedQuantity='0','0',2
RegisterCommand=function(n,f) commands[n]=f end
GetConvar=function(n) return n=='feather_native_throwable_budget' and scope
 or n=='feather_native_throwable_death_budget' and deathScope
 or n=='feather_native_throwable_pickup_budget' and pickupScope or '0' end
GetResourceState=function() return 'stopped' end
exports={['feather-core']={GetSessionContext=function() return {ok=true,value={characterId=character,sessionId='s'}} end,
 IsSessionCurrent=function() return current end}}
ItemControllers={GetItemDefinitionByName=function() return {id=8,type='item_ammo',instance_mode='stack'} end}
local receipt,loose,transactions=nil,0,0
local docs,n={},0
local function copy(v) if type(v)~='table' then return v end; local r={}; for k,x in pairs(v) do r[k]=copy(x) end; return r end
json={encode=function(v) n=n+1; docs[tostring(n)]=copy(v); return tostring(n) end,decode=function(v) return copy(docs[v]) end}
local failReceipt,lose=false,false
local tx={query=function(sql,p)
 if sql:find('INSERT IGNORE',1,true) then receipt=receipt or {request_fingerprint=p[3]}; return {} end
 if sql:find('SELECT `request_fingerprint`',1,true) then return {copy(receipt)} end
 if sql:find('FROM `items`',1,true) then return {{id=8,name='ammo_tomahawk_regular',type='item_ammo',instance_mode='stack'}} end
 if sql:find('FROM `inventory`',1,true) then return {{id=5}} end
 if sql:find('UPDATE `inventory_grant_receipts`',1,true) then
  if failReceipt then return {affectedRows=0} end
  receipt.result_json=p[1]; return {affectedRows=1}
 end
 error(sql)
end,AddQuantity=function(_,inv,id,amount)
 assert(inv==5 and id==8 and amount==expectedQuantity); loose=loose+amount
 if lose then current=false end; return Result.Ok({101})
end}
TransactionAPI={Transaction=function(_,fn)
 transactions=transactions+1; local beforeReceipt,beforeLoose=copy(receipt),loose
 local r=fn(tx); if not r.ok then receipt,loose=beforeReceipt,beforeLoose end; return r
end}
local oldPrint=print; print=function() end
dofile('server/services/grants_once.lua')
local run=commands.InvNativeThrowableBudget
run(0,{'7',john}); assert(transactions==0)
scope='1'; run(7,{'7',john}); run(0,{'7','jane'}); run(0,{'7',john,'extra'}); assert(transactions==0)
character='jane'; run(0,{'7',john}); assert(transactions==0); character=john
lose=true; run(0,{'7',john}); assert(loose==0 and receipt==nil)
lose=false; current=true; failReceipt=true; run(0,{'7',john}); assert(loose==0 and receipt==nil)
failReceipt=false; run(0,{'7',john}); assert(loose==2 and receipt.result_json)
loose=0 -- allowance spent/transferred; replay must not replenish
run(0,{'7',john}); assert(loose==0)
docs[receipt.result_json].quantity=99; run(0,{'7',john}); assert(loose==0)
local count=transactions; scope='0'; run(0,{'7',john}); assert(transactions==count)
local death=commands.InvNativeThrowableDeathBudget
scope='1'; death(0,{'7',john}); assert(transactions==count,'ordinary flag cannot enable death budget')
scope='0'; deathScope='1'; expectedQuantity=1
local originalReceipt=copy(receipt); receipt=nil
failReceipt=true; death(0,{'7',john}); assert(loose==0 and receipt==nil); failReceipt=false
lose=true; death(0,{'7',john}); assert(loose==0 and receipt==nil); lose=false; current=true
death(0,{'7',john}); assert(loose==1 and receipt.result_json)
assert(docs[receipt.result_json].grantId=='native-tomahawk-death-budget-v1' and docs[receipt.result_json].quantity==1)
loose=0; death(0,{'7',john}); assert(loose==0,'death budget replay never replenishes')
assert(originalReceipt.request_fingerprint~=receipt.request_fingerprint,'distinct quantity-bound receipt')
deathScope='0'; count=transactions; death(0,{'7',john}); assert(transactions==count)
local pickup=assert(commands.InvNativeThrowablePickupBudget)
scope='1'; deathScope='1'; pickup(0,{'7',john})
assert(transactions==count,'earlier budget flags cannot enable pickup allowance')
scope='0'; deathScope='0'; pickupScope='1'; receipt=nil
pickup(7,{'7',john}); pickup(0,{'7','jane'}); pickup(0,{'7',john,'extra'})
assert(transactions==count,'pickup budget is console-only and exact John/two arguments')
failReceipt=true; pickup(0,{'7',john}); assert(loose==0 and receipt==nil); failReceipt=false
lose=true; pickup(0,{'7',john}); assert(loose==0 and receipt==nil); lose=false; current=true
pickup(0,{'7',john}); assert(loose==1 and receipt.result_json)
assert(docs[receipt.result_json].grantId=='native-tomahawk-pickup-budget-v1' and docs[receipt.result_json].quantity==1)
loose=0; pickup(0,{'7',john}); assert(loose==0,'pickup budget replay cannot replenish spent or transferred units')
pickupScope='0'; count=transactions; pickup(0,{'7',john}); assert(transactions==count)
print=oldPrint
print('Tomahawk loose budget PASS: fixed John/two stacks/private key/gate, canonical receipt replay, no replenishment, receipt/session rollback; mocked SQL')
