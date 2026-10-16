local registered={}
Config={DevMode=true,CharacterAmmunitionEnabled=true}
Result={Ok=function(v) return {ok=true,value=v} end,Err=function(c,m) return {ok=false,error={code=c,message=m}} end}
local active,quantity,caller=true,1,'feather-weapons'
GetInvokingResource=function() return caller end
exports=setmetatable({['feather-core']={IsSessionCurrent=function() return active end}},
 {__call=function(_,name,fn) registered[name]=fn end})
local tx={query=function(sql,args)
 assert(sql:find('SELECT',1,true) and not sql:find('FOR UPDATE',1,true),'preflight is SELECT-only')
 if sql:find('FROM inventory WHERE',1,true) then assert(args[1]=='Jane'); return {{id=2}} end
 assert(args[1]=='gun_oil'); return {{id=9,name='gun_oil'}}
end}
function tx:GetQuantity(inventoryId,itemId) assert(inventoryId==2 and itemId==9); return quantity end
TransactionAPI={Transaction=function(_,body) return body(tx) end}
dofile('server/services/native_equipment_commit.lua')
local read=registered.ReadNativeRepairMaterial
local context={actorSource=2,characterId='Jane',sessionId='s'}
local result=read(context,'gun_oil')
assert(result.ok and result.value.quantity==1 and result.value.noWrites)
quantity=0; assert(read(context,'gun_oil').value.quantity==0)
quantity=-1; assert(not read(context,'gun_oil').ok)
quantity=0/0; assert(not read(context,'gun_oil').ok)
quantity=1
tx.GetQuantity=function() active=false; return 1 end
assert(not read(context,'gun_oil').ok,'session recheck after quantity read')
active=true; caller='foreign'; assert(not read(context,'gun_oil').ok)
print('Repair material preflight PASS (own quantity, SELECT-only, zero/invalid/current/foreign refusal; no economy writes)')
