local registered={}
Config={DevMode=true,CharacterAmmunitionEnabled=true}
Result={Ok=function(v) return {ok=true,value=v} end,Err=function(c,m) return {ok=false,error={code=c,message=m}} end}
local current,quantity,caller=true,1,'feather-weapons'
GetInvokingResource=function() return caller end
GetConvarInt=function() return 1 end
exports=setmetatable({['feather-core']={IsSessionCurrent=function() return current end}},
 {__call=function(_,name,fn) registered[name]=fn end})
local tx={query=function(sql,args)
 assert(sql:find('SELECT',1,true),'material preflight must be read-only')
 if sql:find('FROM inventory WHERE',1,true) then assert(args[1]=='Jane'); return {{id=2}} end
 assert(args[1]=='carbine_wide_sight'); return {{id=9,name='carbine_wide_sight'}}
end}
function tx:GetQuantity(inventory,id) assert(inventory==2 and id==9); return quantity end
TransactionAPI={Transaction=function(_,fn) return fn(tx) end}
dofile('server/services/native_equipment_commit.lua')
local read=registered.ReadNativeAttachmentMaterial
local context={actorSource=1,characterId='Jane',sessionId='s'}
local result=read(context); assert(result.ok and result.value.quantity==1 and result.value.noWrites)
quantity=0; assert(read(context).value.quantity==0,'zero availability is data, never a grant')
quantity=-1; assert(not read(context).ok)
current=false; assert(not read(context).ok); current=true
caller='foreign'; assert(not read(context).ok)
print('attachment material preflight PASS (own inventory, fixed definition, SELECT-only quantity, zero/invalid/current/caller handling)')
