-- Trusted server storage boundary. No player net events or native creation.
local function copy(v) if type(v)~='table' then return v end;local r={};for k,x in pairs(v) do r[k]=copy(x) end;return r end
local function denied() return Result.Err('pickup_storage_denied','Current server pickup authority required.') end
local function nativeEnabled()
    return type(GetConvarInt)=='function' and GetConvarInt('feather_native_paid_collection',0)==1
end
local function allowed(kind,context,record)
    if (kind=='native-bind' or kind=='native-binding') and not nativeEnabled() then return false end
    if Config.CharacterAmmunitionEnabled~=true
        or GetResourceState('feather-weapons')~='started' or not NativeThrowableSharedClaim then return false end
    local ok,value=pcall(function()
        return exports['feather-weapons']:ValidateNativeThrowablePickupStorage(kind,context,record)==true
    end)
    return ok and value==true
end
local function read(kind,context,record,fn)
    if GetInvokingResource()~='feather-weapons' then return denied() end
    context,record=copy(context),copy(record)
    if not allowed(kind,context,record) then return denied() end
    return TransactionAPI.Transaction({resource='feather-inventory',reason='native_throwable_prompt_read'},function(tx)
        local result=fn(tx,context,record)
        if not allowed(kind,context,record) then return denied() end
        return result
    end)
end
exports('ReadNativeThrowablePromptPage',function(cursor)
    return read('page',nil,{cursor=cursor},function(tx,_,record) return NativeThrowableSharedClaim.ReadPromptPage(tx,record.cursor) end)
end)
exports('ReadNativeThrowablePromptBinding',function(id)
    return read('binding',nil,{id=id},function(tx,_,record) return NativeThrowableSharedClaim.ReadPromptBinding(tx,record.id) end)
end)
exports('ReadNativeThrowableNativeBinding',function(id)
    if not nativeEnabled() then return denied() end
    return read('native-binding',nil,{id=id},function(tx,_,record)
        if not nativeEnabled() then return denied() end
        return NativeThrowableSharedClaim.ReadNativeBinding(tx,record.id)
    end)
end)
exports('ReadNativeThrowableSpentUnit',function(context,operationId,itemId)
    return read('spend',context,{operationId=operationId,itemId=itemId},function(tx,bound,record)
        return NativeThrowableSharedClaim.ReadSpentUnit(tx,bound,record.operationId,record.itemId)
    end)
end)
local function registerBinding(name,native)
exports(name,function(context,record)
    if GetInvokingResource()~='feather-weapons' or type(context)~='table' then return denied() end
    if type(record)~='table' or (native and (not nativeEnabled() or record.version~=4
        or record.presentation~='native' or record.kind~='paid_tomahawk_native_pickup'))
        or (not native and (record.version~=3 or (record.presentation~=nil and record.presentation~='prompt'))) then return denied() end
    context,record=copy(context),copy(record)
    local timing=native and NativeCollectionTiming and NativeCollectionTiming.New('binding',context and context.actorSource,record.itemId)
    local function current() return (not native or nativeEnabled()) and allowed(native and 'native-bind' or 'bind',context,record) end
    if timing then current=timing.Wrap('authority',current) end
    local function body(tx)
        local result=NativeThrowableSharedClaim.RecordBinding(tx,context,record,current)
        if not current() then return denied() end
        return result
    end
    local function operation()
        if not current() then return denied() end
        return TransactionAPI.Transaction({resource='feather-weapons',reason=native and 'native_throwable_native_binding' or 'native_throwable_prompt_binding',
            actorSource=context.actorSource,actorCharacterId=context.characterId,characterId=context.characterId,
            sessionId=context.sessionId},timing and timing.Wrap('body',body) or body)
    end
    if timing then return timing.Run(operation) end
    return operation()
end)
end
registerBinding('BindNativeThrowablePromptPickup',false)
registerBinding('BindNativeThrowableNativePickup',true)
