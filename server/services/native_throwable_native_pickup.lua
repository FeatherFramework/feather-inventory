-- Trusted Weapons reservation only. Never a client event or arbitrary grant.
local function copy(v) if type(v)~='table' then return v end; local r={}; for k,x in pairs(v) do r[k]=copy(x) end; return r end
exports('ReconcileNativeThrowablePickup',function(context,spec)
    if GetInvokingResource()~='feather-weapons' or type(context)~='table' or type(spec)~='table'
        or type(spec.nativePickupPlan)~='table' or spec.expectedRevision~=spec.nativePickupPlan.expectedRevision then
        return Result.Err('native_pickup_denied','Trusted reserved pickup required.')
    end
    context,spec=copy(context),copy(spec)
    local quantities=spec.nativePickupPlan.version==2
    local function current()
        if Config.CharacterAmmunitionEnabled~=true or GetResourceState('feather-weapons')~='started' then return false end
        if quantities then
            if type(GetConvar)~='function' or GetConvar('feather_throwable_quantities','0')~='1' or not ThrowableQuantityRecovery then return false end
        elseif Config.DevMode~=true or type(GetConvarInt)~='function' or GetConvarInt('feather_native_throwable_pickup',0)~=1
            or not NativeThrowableNativePickupClaim then return false end
        local ok,value=pcall(function()
            return exports['feather-core']:IsSessionCurrent(context.actorSource,context.sessionId,context.characterId)==true
                and exports['feather-weapons']:ValidateCharacterAmmoRuntimeOperation(context,'pickup',spec)==true
        end)
        return ok and value==true
    end
    if not current() then return Result.Err('native_pickup_denied','Current pickup reservation required.') end
    return TransactionAPI.Transaction({resource='feather-weapons',reason='native_throwable_pickup',
        actorSource=context.actorSource,characterId=context.characterId,actorCharacterId=context.characterId,
        sessionId=context.sessionId,runtimeEpoch=context.runtimeEpoch,runtimeTicket=context.runtimeTicket},function(tx)
        if not current() then return Result.Err('native_pickup_denied','Pickup authority changed.') end
        local result
        if quantities then result=ThrowableQuantityRecovery.Claim(tx,context,spec,current)
        else result=NativeThrowableNativePickupClaim.Apply(tx,
            {characterId=context.characterId,sessionId=context.sessionId,epoch=context.runtimeEpoch},
            spec.nativePickupPlan,spec.limits,current)
        end
        if not result or not result.ok then return result or Result.Err('native_pickup_denied','Pickup claim unavailable.') end
        if not current() then return Result.Err('native_pickup_denied','Pickup authority changed before commit.') end
        return result
    end)
end)
