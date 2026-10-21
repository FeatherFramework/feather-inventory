local registered={}
local flag,authority,session,caller=0,true,true,'feather-weapons'
local writes,fail,lose=0,false,false
Config={DevMode=true,CharacterAmmunitionEnabled=true}
Result={Ok=function(v) return {ok=true,value=v} end,Err=function(c,m) return {ok=false,error={code=c,message=m}} end}
GetInvokingResource=function() return caller end
GetConvarInt=function(name) return name=='feather_native_throwable' and flag or 0 end
GetResourceState=function() return 'started' end
exports=setmetatable({['feather-core']={IsSessionCurrent=function() return session end},
 ['feather-weapons']={ValidateNativeEquipmentCommit=function(_,context,spec)
  return authority and context.ticket=='ticket' and spec.throwableId==170
 end}}, {__call=function(_,name,fn) registered[name]=fn end})
NativeThrowableEquipment={Read=function(_,character,id,current)
 assert(character=='john' and current()); return Result.Ok({candidate={id=id}})
end,Apply=function(_,spec,current)
 assert(spec.slot=='weapon_throwable' and current())
 if fail then return Result.Err('conflict','changed') end
 writes=writes+1; if lose then authority=false end
 return Result.Ok({itemId=170})
end}
NativeLifecycleWear={Apply=function(_,spec,current) assert(current()); writes=writes+1; return Result.Ok(spec) end}
TransactionAPI={Transaction=function(_,fn)
 local before=writes; local result=fn({}); if not result.ok then writes=before end; return result
end}
dofile('server/services/native_equipment_commit.lua')
local context={actorSource=7,characterId='john',sessionId='s',epoch='e',ticket='ticket'}
local spec={characterId='john',action='equip',slot='weapon_throwable',throwableId=170,lifecycleSnapshot={},lifecycleWear={}}
local read,commit=registered.ReadNativeThrowableEquipment,registered.CommitNativeThrowableEquipment
assert(not read(context,170).ok and not commit(context,spec).ok and writes==0)
flag=1; caller='other'; assert(not commit(context,spec).ok); caller='feather-weapons'
session=false; assert(not read(context,170).ok); session=true
assert(read(context,170).ok and writes==0)
assert(commit(context,spec).ok and writes==2)
fail=true; assert(not commit(context,spec).ok and writes==2); fail=false
lose=true; assert(not commit(context,spec).ok and writes==2); lose=false; authority=true
spec.slot='weapon_melee'; assert(not commit(context,spec).ok)
spec.slot='weapon_throwable'; spec.action='throwable-funding'; spec.throwable=true
local funding=registered.CommitNativeThrowableFunding
CharacterAmmunitionAPI={ApplyThrowableFunding=function(_,bound,working,current)
 assert(bound.characterId=='john' and working==spec or working.throwableId==170)
 writes=writes+1
 if lose then authority=false end
 if fail or not current() then return Result.Err('conflict','funding refused') end
 return Result.Ok({revision=1})
end}
flag=0; assert(not funding(context,spec).ok and writes==2); flag=1
assert(funding(context,spec).ok and writes==4)
fail=true; assert(not funding(context,spec).ok and writes==4); fail=false
lose=true; assert(not funding(context,spec).ok and writes==4); lose=false; authority=true
local readTx={query=function(sql)
 if sql:find('SELECT id FROM inventory',1,true) then return {{id=5}} end
 if sql:find('SELECT ce.slot',1,true) then return {} end
 error(sql)
end}
TransactionAPI.Transaction=function(_,fn) return fn(readTx) end
NativeThrowableEquipment.Read=function(tx) assert(tx==readTx); return Result.Ok({expected={},equipment={}}) end
CharacterAmmunitionAPI.ReadRuntimeEquipment=function(tx) assert(tx==readTx); return Result.Ok({}) end
CharacterAmmunitionAPI.ReadSnapshot=function(tx,character,limits,equipment)
 assert(tx==readTx and character=='john' and limits.ammo_tomahawk_regular==1 and equipment==false)
 return Result.Ok({revision=10,pools={ammo_tomahawk_regular=1}})
end
local ordinary=registered.ReadNativeEquipmentTransition(context,nil)
assert(ordinary.ok and ordinary.value.throwableEquipment.revision==nil)
local complete=registered.ReadNativeEquipmentTransition(context,nil,{ammo_tomahawk_regular=1})
assert(complete.ok and complete.value.throwableEquipment.revision==10
 and complete.value.throwableEquipment.pools.ammo_tomahawk_regular==1 and writes==4)
assert(not registered.ReadNativeEquipmentTransition(context,nil,{ammo_tomahawk_regular=2}).ok)
print('throwable trusted exports PASS: separate gate/caller/reservation, same final-wear+equipment transaction, no writes on conflict/authority loss')
