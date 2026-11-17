local registered={}
local invoking,valid,stage='feather-weapons',true,0
exports=setmetatable({['feather-core']={IsSessionCurrent=function() return valid end},
 ['feather-weapons']={ValidateNativeEquipmentCommit=function(_,context,spec) return valid and context.ticket=='reserved' and spec.pickupClaim.itemId==42 end}},
 {__call=function(_,n,f) registered[n]=f end})
GetInvokingResource=function() return invoking end
GetResourceState=function() return 'started' end
Config={CharacterAmmunitionEnabled=true}
Result={Err=function(code) return {ok=false,code=code} end,Ok=function(value) return {ok=true,value=value} end}
local db=0;local fail=false
TransactionAPI={Transaction=function(context,fn)
 assert(context.resource=='feather-weapons' and context.actorSource==1)
 local before=db;local ok,result=pcall(fn,{})
 if not ok or not result.ok then db=before end
 return ok and result or Result.Err('interrupted')
end}
NativeLifecycleWear={Apply=function(_,spec,current) assert(current());stage=1;db=db+1;return Result.Ok(spec) end}
NativeThrowableSharedClaim={Apply=function(_,context,plan,limits,current)
 assert(stage==1 and context.characterId=='jane' and context.resource=='feather-weapons' and plan.itemId==42 and limits.ammo_tomahawk_regular==3)
 assert(current());db=db+1
 if fail then error('claim interrupted') end
 return Result.Ok({itemId=42})
end}
dofile('server/services/native_equipment_commit.lua')
local context={actorSource=1,characterId='jane',sessionId='sid',epoch='old',ticket='reserved'}
local spec={characterId='jane',action='throwable-pickup',pickupContract=1,pickupClaim={version=3,itemId=42},
 lifecycleSnapshot={},lifecycleWear={},limits={ammo_tomahawk_regular=3}}
invoking='other';assert(not registered.CommitNativeThrowablePromptPickup(context,spec).ok and db==0)
invoking='feather-weapons';valid=false;assert(not registered.CommitNativeThrowablePromptPickup(context,spec).ok and db==0)
valid=true;fail=true;assert(not registered.CommitNativeThrowablePromptPickup(context,spec).ok and db==0,'wear rolls back with failed claim')
fail=false;assert(registered.CommitNativeThrowablePromptPickup(context,spec).ok and db==2)
print('PASS actual pickup export: trusted resource/current released ticket and atomic wear+claim failure rollback; modeled transaction')
local nativeGate=0
GetConvarInt=function() return nativeGate end
db=0
local native={characterId='jane',action='throwable-pickup',pickupContract=2,
 pickupClaim={version=4,presentation='native',kind='physical_throwable_native_claim',itemId=42,expectedPools={ammo_tomahawk_regular=0}},
 lifecycleSnapshot={},lifecycleWear={},limits={ammo_tomahawk_regular=3}}
assert(not registered.CommitNativeThrowableNativePickup(context,native).ok and db==0)
nativeGate=1
assert(not registered.CommitNativeThrowablePromptPickup(context,native).ok and db==0)
assert(not registered.CommitNativeThrowableNativePickup(context,spec).ok and db==0)
fail=true;assert(not registered.CommitNativeThrowableNativePickup(context,native).ok and db==0)
fail=false;assert(registered.CommitNativeThrowableNativePickup(context,native).ok and db==2)
db=0
local originalWear=NativeLifecycleWear.Apply
NativeLifecycleWear.Apply=function(_,value,current)
 assert(current());db=db+1;nativeGate=0;return Result.Ok(value)
end
assert(not registered.CommitNativeThrowableNativePickup(context,native).ok and db==0,'gate loss during wear rolls back native claim')
print('PASS native pickup export: default-off, separate contract/version, shared atomic wear+claim and gate-change rollback')
NativeLifecycleWear.Apply=originalWear
dofile('server/internal/native_collection_timing.lua')
local newTiming=NativeCollectionTiming.New
local reports={};local clock=0
NativeCollectionTiming.New=function(stage,source,itemId)
 return newTiming(stage,source,itemId,{enabled=true,now=function() clock=clock+1;return clock end,
  emit=function(r) reports[#reports+1]=r end})
end
nativeGate=1;db=0
assert(registered.CommitNativeThrowableNativePickup(context,native).ok and db==2)
assert(#reports==1 and reports[1].stage=='claim' and reports[1].ok and reports[1].authority.calls>=3 and reports[1].body.calls==1)
db=0;fail=true
assert(not registered.CommitNativeThrowableNativePickup(context,native).ok and db==0 and #reports==2 and not reports[2].ok)
