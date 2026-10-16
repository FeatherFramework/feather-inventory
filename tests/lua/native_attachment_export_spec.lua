local registered={}
Config={DevMode=true,CharacterAmmunitionEnabled=true}
Result={Ok=function(v) return {ok=true,value=v} end,Err=function(c,m) return {ok=false,error={code=c,message=m}} end}
local caller,valid,feature='feather-weapons',true,1
GetInvokingResource=function() return caller end
GetResourceState=function() return 'started' end
GetConvarInt=function() return feature end
local state={wear=0,paid=0}
local function copy(v) if type(v)~='table' then return v end; local out={}; for k,x in pairs(v) do out[k]=copy(x) end; return out end
exports=setmetatable({['feather-core']={IsSessionCurrent=function() return true end},
 ['feather-weapons']={ValidateNativeEquipmentCommit=function(_,context,spec)
    assert(context.ticket=='ticket' and spec.itemRevision==2,'authority always validates original reservation, never rebased work')
    return valid
 end}},{__call=function(_,name,fn) registered[name]=fn end})
local failAfterWear,throwCommit=false,false
local paymentFailure,failAfterPayment=false,false
TransactionAPI={Transaction=function(_,body)
    if throwCommit then error('ambiguous transaction acknowledgement') end
    local before=copy(state); local result=body({})
    if not result.ok then state=before end
    return result
end}
NativeLifecycleWear={Apply=function(_,spec,current)
    assert(current()); state.wear=state.wear+1
    local working=copy(spec); working.expected.weapon_shoulder.revision=3
    if failAfterWear then valid=false end
    return Result.Ok(working)
end}
NativeAttachmentCommit={Apply=function(_,spec,current)
    assert(spec.itemRevision==3 and spec.before.maintenance.dirt==0.2 and spec.after.maintenance.dirt==0.2)
    assert(spec.expected.weapon_shoulder.revision==3 and spec.after.attachments[1].definitionId=='carbine_wide_sight')
    if not current() then return Result.Err('stale','stale after wear') end
    if paymentFailure then return Result.Err('capacity','attachment return cannot fit') end
    state.paid=state.paid+1
    if failAfterPayment then valid=false end
    return Result.Ok({revision=4})
end}
dofile('server/services/native_equipment_commit.lua')
local context={actorSource=1,characterId='Jane',sessionId='s',epoch='e',ticket='ticket'}
local before={weaponDefinitionId='repeater_carbine',maintenance={dirt=0},attachments={}}
local wear=copy(before); wear.maintenance.dirt=0.2
local after=copy(wear); after.attachments={{definitionId='carbine_wide_sight',slot='sight'}}
local spec={characterId='Jane',action='attachment-install',itemId=135,itemRevision=2,before=before,after=after,
 expected={weapon_shoulder={itemId=135,revision=2}},lifecycleSnapshot={},
 lifecycleWear={{itemId=135,itemRevision=2,before=before,after=wear}}}
local commit=registered.CommitNativeAttachmentTransition
caller='foreign'; assert(not commit(context,spec).ok and state.paid==0)
caller='feather-weapons'; feature=0; assert(not commit(context,spec).ok); feature=1
valid=false; assert(not commit(context,spec).ok); valid=true
assert(commit(context,spec).ok and state.wear==1 and state.paid==1)
assert(spec.itemRevision==2 and spec.before.maintenance.dirt==0,'caller reservation is private/unchanged')
failAfterWear=true
assert(not commit(context,spec).ok and state.wear==1 and state.paid==1,'authority loss rolls final wear back with payment')
valid=true; failAfterWear=false; paymentFailure=true
assert(not commit(context,spec).ok and state.wear==1 and state.paid==1,'attachment refusal rolls wear back in same transaction')
paymentFailure=false; failAfterPayment=true
assert(not commit(context,spec).ok and state.wear==1 and state.paid==1,'post-payment authority loss rolls both changes back')
valid=true; failAfterPayment=false; throwCommit=true
assert(not pcall(commit,context,spec),'ambiguous transaction errors propagate, never converted into retryable refusal')
print('attachment export PASS (caller/feature/exact released authority, same-TX final wear rebase/payment, rollback, unknown outcome propagation)')
