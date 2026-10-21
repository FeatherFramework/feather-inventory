local registered={}
local flags={feather_native_knife=1,feather_native_melee=0}
local authority,session,caller=true,true,'feather-weapons'
local writes,transactions=0,0
Config={DevMode=true,CharacterAmmunitionEnabled=true}
Result={Ok=function(v) return {ok=true,value=v} end,Err=function(c,m) return {ok=false,error={code=c,message=m}} end}
GetInvokingResource=function() return caller end
GetConvarInt=function(name,default) return flags[name] or default end
GetResourceState=function() return 'started' end
exports=setmetatable({['feather-core']={IsSessionCurrent=function() return session end},
 ['feather-weapons']={ValidateNativeEquipmentCommit=function(_,context,spec)
  return authority and context.ticket=='ticket' and spec.knifeId==90
 end}}, {__call=function(_,n,fn) registered[n]=fn end})
local fail,lose,dropFlag=false,false,false
NativeMeleeEquipment={Read=function(_,character,id,current)
 assert(character=='john' and current()); return Result.Ok({candidate={id=id}})
end,Apply=function(_,spec,current)
 assert(spec.slot=='weapon_melee_quinary' and current())
 if fail then return Result.Err('conflict','changed') end
 writes=writes+1
 if lose then authority=false end
 if dropFlag then flags.feather_native_melee=0 end
 return Result.Ok({itemId=90})
end}
NativeKnifeEquipment={Read=function() return Result.Ok({}) end,Apply=function() error('wrong adapter') end}
NativeLifecycleWear={Apply=function(_,spec,current)
 assert(current()); writes=writes+1; return Result.Ok(spec)
end}
TransactionAPI={Transaction=function(_,fn)
 transactions=transactions+1; local before=writes; local result=fn({})
 if not result.ok then writes=before end; return result
end}
dofile('server/services/native_equipment_commit.lua')
local context={actorSource=3,characterId='john',sessionId='s',epoch='e',ticket='ticket'}
local spec={characterId='john',action='equip',slot='weapon_melee_quinary',knifeId=90,lifecycleSnapshot={},lifecycleWear={}}
local read,commit=registered.ReadNativeMeleeEquipment,registered.CommitNativeMeleeEquipment
assert(not read(context,90).ok and not commit(context,spec).ok and transactions==0,'knife flag cannot enable full melee')
flags.feather_native_melee=1
caller='other'; assert(not read(context,90).ok and not commit(context,spec).ok); caller='feather-weapons'
session=false; assert(not read(context,90).ok and not commit(context,spec).ok); session=true
authority=false; assert(not commit(context,spec).ok); authority=true
assert(read(context,90).ok and writes==0)
assert(commit(context,spec).ok and writes==2)
assert(not registered.CommitNativeKnifeEquipment(context,spec).ok,'knife route stays single slot')
local count=writes
fail=true; assert(not commit(context,spec).ok and writes==count); fail=false
lose=true; assert(not commit(context,spec).ok and writes==count); lose=false; authority=true
dropFlag=true; assert(not commit(context,spec).ok and writes==count); dropFlag=false; flags.feather_native_melee=1
spec.slot='weapon'; assert(not commit(context,spec).ok)
print('staged melee exports PASS: independent default-off gate, trusted caller/exact ticket, same-transaction wear/equipment rollback')
