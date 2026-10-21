local registered={}
local flag,authority,session,caller=0,true,true,'feather-weapons'
local writes,transactions=0,0
Config={DevMode=true,CharacterAmmunitionEnabled=true}
Result={Ok=function(v) return {ok=true,value=v} end,Err=function(c,m) return {ok=false,error={code=c,message=m}} end}
GetInvokingResource=function() return caller end
GetConvarInt=function() return flag end
GetResourceState=function() return 'started' end
exports=setmetatable({['feather-core']={IsSessionCurrent=function() return session end},
 ['feather-weapons']={ValidateNativeEquipmentCommit=function(_,context,spec)
  return authority and context.ticket=='ticket' and spec.knifeId==90
 end}}, {__call=function(_,n,fn) registered[n]=fn end})
local failKnife,lose=false,false
NativeKnifeEquipment={Read=function(_,character,id,current)
 assert(character=='john' and current()); return Result.Ok({candidate={id=id}})
end,Apply=function(_,spec,current)
 assert(spec.slot=='weapon_melee' and current()); if failKnife then return Result.Err('conflict','knife changed') end
 writes=writes+1; if lose then authority=false end; return Result.Ok({itemId=90})
end}
NativeLifecycleWear={Apply=function(_,spec,current)
 assert(current()); writes=writes+1; return Result.Ok(spec)
end}
TransactionAPI={Transaction=function(_,fn)
 transactions=transactions+1; local before=writes; local result=fn({})
 if not result.ok then writes=before end; return result
end}
dofile('server/services/native_equipment_commit.lua')
local context={actorSource=3,characterId='john',sessionId='s',epoch='e',ticket='ticket'}
local spec={characterId='john',action='equip',slot='weapon_melee',knifeId=90,lifecycleSnapshot={},lifecycleWear={}}
local read,commit=registered.ReadNativeKnifeEquipment,registered.CommitNativeKnifeEquipment
assert(not read(context,90).ok and not commit(context,spec).ok and transactions==0)
flag=1; caller='other'; assert(not read(context,90).ok and not commit(context,spec).ok); caller='feather-weapons'
session=false; assert(not read(context,90).ok and not commit(context,spec).ok); session=true
authority=false; assert(not commit(context,spec).ok); authority=true
assert(read(context,90).ok and writes==0)
assert(commit(context,spec).ok and writes==2,'same transaction final wear and equipment')
local count=writes; failKnife=true
assert(not commit(context,spec).ok and writes==count,'knife conflict rolls back preceding wear')
failKnife=false; lose=true
assert(not commit(context,spec).ok and writes==count,'post-write reserved-authority loss rolls back both')
print('knife exports PASS (default-off/trusted caller/current ticket, same-transaction final-wear+knife rollback; mock transaction)')
