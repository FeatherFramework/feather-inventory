local registered={}
local authority,session=true,true
local invoking='feather-weapons'
Config={DevMode=false,CharacterAmmunitionEnabled=true}
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
spec.action='move'; spec.fromSlot='weapon'; spec.slot='weapon_offhand'
spec.expected={weapon={itemId=112,revision=1},weapon_offhand={itemId=231,revision=4}}
local detach=false
NativeLifecycleWear.Apply=function(_,intent,current)
 assert(current()); writes=writes+1
 local working={}; for k,v in pairs(intent) do working[k]=v end
 working.expected={weapon={itemId=112,revision=2},weapon_offhand={itemId=231,revision=5}}
 if detach then working.expected.weapon=nil end
 return Result.Ok(working)
end
ConditionalEquipment.Apply=function(_,intent,current)
 assert(current() and intent.itemRevision==2 and intent.expected.weapon_offhand.revision==5)
 writes=writes+1; return Result.Ok({})
end
oldWrites=writes
assert(commit(context,spec).ok and writes==oldWrites+2 and spec.itemRevision==1,'swap rebases final wear revision without changing signed caller intent')
detach=true; oldWrites=writes
assert(not commit(context,spec).ok and writes==oldWrites,'final wear detachment rolls back rather than swapping a promoted replacement')
print('sidearm swap wear composition PASS (exact instance rebasing and rollback on broken assignment)')
spec.action='unequip_primary'; spec.slot='weapon'; spec.fromSlot=nil; spec.itemId=nil; spec.itemRevision=nil
exports['feather-weapons'].ValidateNativeEquipmentCommit=function(_,ctx,intent)
 return authority and ctx.ticket=='ticket' and intent.action=='unequip_primary'
end
ConditionalEquipment.Apply=function(_,intent,current)
 assert(current() and intent.action=='unequip_primary' and not intent.itemId
  and intent.expected.weapon.revision==2 and intent.expected.weapon_offhand.revision==5)
 writes=writes+1; return Result.Ok({})
end
detach=false; oldWrites=writes
assert(commit(context,spec).ok and writes==oldWrites+2,'Primary removal and promotion use updated wear revisions in same transaction')
detach=true; oldWrites=writes
assert(not commit(context,spec).ok and writes==oldWrites,'broken assignment refuses promotion and rolls back wear')
print('Primary removal wear composition PASS (atomic final wear/promotion and no implicit broken replacement)')
