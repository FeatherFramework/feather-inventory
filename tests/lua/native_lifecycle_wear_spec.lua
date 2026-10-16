Result={Ok=function(v) return {ok=true,value=v} end,Err=function(c,m) return {ok=false,error={code=c,message=m}} end}
dofile('server/services/native_lifecycle_wear.lua')
local calls,active=0,true
NativeRepairCommit={Apply=function(_,change,current)
 assert(change.action=='maintenance' and change.material==nil and current())
 calls=calls+1
 if calls==1 then assert(change.expected.weapon.revision==2)
 else assert(change.expected.weapon.revision==3 and change.expected.weapon_offhand.revision==4) end
 return Result.Ok({})
end}
local spec={action='unequip',characterId='jane',slot='weapon',expected={weapon={itemId=128,revision=2},weapon_offhand={itemId=130,revision=4}},
 lifecycleWear={{itemId=128,itemRevision=2,before={},after={}},{itemId=130,itemRevision=4,before={},after={}}}}
local tx={query=function(sql)
 if sql:find('FROM inventory ',1,true) then return {{id=2}} end
 return {{slot='weapon',inventory_items_id=128,row_revision=2,owner_character='jane'},
  {slot='weapon_offhand',inventory_items_id=130,row_revision=4,owner_character='jane'}}
end}
local result=NativeLifecycleWear.Apply(tx,spec,function() return active end)
assert(result.ok and calls==2 and result.value.expected.weapon.revision==3 and result.value.expected.weapon_offhand.revision==5)
assert(spec.expected.weapon.revision==2,'reserved pre-write descriptor must not mutate')
spec.lifecycleWear[2]=spec.lifecycleWear[1]; calls=0
assert(not NativeLifecycleWear.Apply(tx,spec,function() return active end).ok and calls==0)
spec.lifecycleWear={}; active=false
assert(not NativeLifecycleWear.Apply(tx,spec,function() return active end).ok)
print('native_lifecycle_wear_spec PASS (same transaction revision rebasing, immutable reservation, no materials, duplicate/authority refusal)')
