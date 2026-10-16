local registered={}
local authority,session=true,true
local invoking='feather-weapons'
Config={DevMode=true,CharacterAmmunitionEnabled=true}
GetInvokingResource=function() return invoking end
GetResourceState=function() return 'started' end
Result={Err=function(code,message) return {ok=false,error={code=code,message=message}} end,
 Ok=function(value) return {ok=true,value=value} end}
exports=setmetatable({
 ['feather-core']={IsSessionCurrent=function() return session end},
 ['feather-weapons']={ValidateNativeEquipmentCommit=function(_,context,spec)
  return authority and context.ticket=='ticket' and spec.itemId==112
 end}
},{__call=function(_,name,fn) registered[name]=fn end})
local writes,transactions=0,0
local lose=false
ConditionalEquipment={Apply=function(_,spec,current)
 assert(spec.itemId==112 and current())
 writes=writes+1
 if lose then authority=false end
 return {ok=true,value={slot='weapon',itemId=112}}
end}
TransactionAPI={Transaction=function(_,fn)
 transactions=transactions+1
 local before=writes
 local result=fn({})
 if not result.ok then writes=before end
 return result
end}
dofile('server/services/native_equipment_commit.lua')
local commit=registered.CommitNativeEquipmentTransition
local context={actorSource=1,characterId='jane',sessionId='session',epoch='epoch',ticket='ticket'}
local spec={characterId='jane',action='equip',slot='weapon',itemId=112,itemRevision=1,expected={}}
invoking='other'; assert(not commit(context,spec).ok and transactions==0); invoking='feather-weapons'
Config.CharacterAmmunitionEnabled=false; assert(not commit(context,spec).ok); Config.CharacterAmmunitionEnabled=true
authority=false; assert(not commit(context,spec).ok and transactions==0); authority=true
session=false; assert(not commit(context,spec).ok and transactions==0); session=true
assert(commit(context,spec).ok and writes==1)
lose=true; assert(not commit(context,spec).ok and writes==1,'authority loss rolls back')
print('native equipment commit PASS (caller/flags/current release authority, Inventory transaction, post-write rollback)')
NativeRepairCommit={Apply=function(_,repair,current)
 assert(repair.action=='repair' and current())
 writes=writes+1
 if lose then authority=false end
 return {ok=true,value={condition=100}}
end}
local repair=registered.CommitNativeRepairTransition
spec.action='repair'; authority=true; lose=false
invoking='other'; assert(not repair(context,spec).ok); invoking='feather-weapons'
session=false; assert(not repair(context,spec).ok); session=true
local oldWrites=writes
assert(repair(context,spec).ok and writes==oldWrites+1)
lose=true; assert(not repair(context,spec).ok and writes==oldWrites+1,'repair post-write authority loss rolls back')
print('native repair export PASS (caller/current reserved release gate, own transaction and post-write rollback)')
local failEquipment=false
NativeLifecycleWear={Apply=function(_,intent,current)
 assert(current() and intent.lifecycleWear); writes=writes+1
 return {ok=true,value=intent}
end}
ConditionalEquipment.Apply=function(_,intent,current)
 assert(current()); if failEquipment then return Result.Err('conflict','Equipment changed') end
 writes=writes+1; return {ok=true,value={}}
end
authority=true; lose=false; spec.action='unequip'; spec.lifecycleSnapshot={}; spec.lifecycleWear={}
oldWrites=writes
assert(commit(context,spec).ok and writes==oldWrites+2)
failEquipment=true
assert(not commit(context,spec).ok and writes==oldWrites+2,'failed equipment write rolls back preceding wear write')
spec.action='shutdown'; oldWrites=writes
assert(commit(context,spec).ok and writes==oldWrites+1,'orderly stop commits wear without equipment write')
print('atomic lifecycle wear export PASS (same transaction wear/equipment rollback and shutdown metadata-only commit)')
