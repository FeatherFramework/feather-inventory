local registered,invoking,allowed={},'feather-weapons',true
local queries=0
Config={CharacterAmmunitionEnabled=true}
Result={Err=function(code) return {ok=false,code=code} end,Ok=function(value) return {ok=true,value=value} end}
GetInvokingResource=function() return invoking end;GetResourceState=function() return 'started' end
exports=setmetatable({['feather-weapons']={ValidateNativeThrowablePickupStorage=function(_,kind,context,record)
 if kind=='bind' then return allowed and context.characterId=='jane' and record.pickupId=='paid' end
 return allowed
end}}, {__call=function(_,name,fn) registered[name]=fn end})
NativeThrowableSharedClaim={
 ReadPromptPage=function(_,cursor) queries=queries+1;return Result.Ok({cursor=cursor}) end,
 ReadPromptBinding=function(_,id) queries=queries+1;return Result.Ok({id=id}) end,
 ReadSpentUnit=function(_,context,operationId,itemId) queries=queries+1;return Result.Ok({itemId=itemId}) end,
 RecordBinding=function(_,context,record,current) assert(current());queries=queries+1;return Result.Ok({binding=record}) end}
TransactionAPI={Transaction=function(_,fn) return fn({}) end}
dofile('server/services/native_throwable_prompt_storage.lua')
invoking='untrusted';assert(not registered.ReadNativeThrowablePromptPage().ok and queries==0)
invoking='feather-weapons';allowed=false;assert(not registered.ReadNativeThrowablePromptBinding('paid').ok and queries==0)
allowed=true;assert(registered.ReadNativeThrowablePromptPage('cursor').ok)
assert(registered.ReadNativeThrowableSpentUnit({characterId='jane'},'spend',42).value.itemId==42)
assert(registered.BindNativeThrowablePromptPickup({characterId='jane'},{version=3,pickupId='paid'}).ok)
assert(not registered.BindNativeThrowablePromptPickup({characterId='john'},{version=3,pickupId='paid'}).ok)
NativeThrowableSharedClaim.ReadPromptBinding=function() allowed=false;return Result.Ok({}) end
assert(not registered.ReadNativeThrowablePromptBinding('paid').ok,'read result is withheld when authority changes during storage')
print('PASS actual prompt storage exports: trusted invoking resource, bootstrap authority, confirmed-spend reader and scoped binding writer')
local gate=0
GetConvarInt=function() return gate end
allowed=true
local record={version=4,presentation='native',kind='paid_tomahawk_native_pickup',pickupId='paid'}
local before=queries
assert(not registered.BindNativeThrowableNativePickup({characterId='jane'},record).ok and queries==before)
gate=1
assert(registered.BindNativeThrowableNativePickup({characterId='jane'},record).ok)
assert(not registered.BindNativeThrowableNativePickup(42,record).ok,'malformed context cannot reach timing or storage')
before=queries
assert(not registered.BindNativeThrowablePromptPickup({characterId='jane'},record).ok and queries==before)
NativeThrowableSharedClaim.ReadNativeBinding=function(_,id) queries=queries+1;gate=0;return Result.Ok({pickupId=id}) end
assert(not registered.ReadNativeThrowableNativeBinding('paid').ok,'gate loss during native read withholds result')
gate=1;allowed=true
dofile('server/internal/native_collection_timing.lua')
local newTiming=NativeCollectionTiming.New
local reports={}
NativeCollectionTiming.New=function(stage,source,itemId)
 return newTiming(stage,source,itemId,{enabled=true,now=function() return 0 end,emit=function(r) reports[#reports+1]=r end})
end
assert(registered.BindNativeThrowableNativePickup({characterId='jane'},record).ok)
assert(#reports==1 and reports[1].stage=='binding' and reports[1].authority.calls>=3 and reports[1].body.calls==1 and reports[1].ok)
