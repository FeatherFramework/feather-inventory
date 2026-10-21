-- Staged registration factory. Not manifest-loaded; no exports on file load.
local function copy(v) if type(v)~='table' then return v end; local r={}; for k,x in pairs(v) do r[k]=copy(x) end; return r end
local function denied() return Result.Err('native_utility_denied','Trusted current utility reservation required.') end
local function install(component)
    exports('ReadNativeUtilityEquipment',function(context)
        if GetInvokingResource()~='feather-weapons' or type(context)~='table' then return denied() end
        context=copy(context)
        local function current()
            if Config.DevMode~=true or Config.CharacterAmmunitionEnabled~=true
                or GetConvarInt('feather_native_utility',0)~=1
                or GetResourceState('feather-weapons')~='started' then return false end
            local ok,v=pcall(function()
                return exports['feather-core']:IsSessionCurrent(context.actorSource,context.sessionId,context.characterId)
            end)
            return ok and v==true
        end
        if not current() then return denied() end
        return TransactionAPI.Transaction({resource='feather-inventory',reason='native_utility_read'},function(tx)
            if not current() then return denied() end
            local result=component.Read(tx,context.characterId,current)
            if not current() then return denied() end
            return result
        end)
    end)
    exports('CommitNativeUtilityEquipment',function(context,spec)
        if GetInvokingResource()~='feather-weapons' or type(context)~='table' or type(spec)~='table'
            or context.characterId~=spec.characterId or spec.utility~=true
            or (spec.slot~='weapon_utility' and not (spec.slot=='weapon_utility_secondary'
                and (GetConvarInt('feather_native_lasso_reinforced',0)==1 or GetConvarInt('feather_native_davy_lantern',0)==1))
                and not (spec.slot=='weapon_utility_tertiary' and GetConvarInt('feather_native_davy_lantern',0)==1
                    and GetConvarInt('feather_native_binoculars',0)==1)
                and not (spec.slot=='weapon_utility_quaternary' and GetConvarInt('feather_native_davy_lantern',0)==1
                    and GetConvarInt('feather_native_binoculars',0)==1 and GetConvarInt('feather_native_camera',0)==1))
            or (spec.action~='equip' and spec.action~='unequip')
            or type(context.epoch)~='string' or type(context.ticket)~='string'
            or type(spec.lifecycleSnapshot)~='table' or type(spec.lifecycleWear)~='table' then return denied() end
        context,spec=copy(context),copy(spec)
        local function current()
            if Config.DevMode~=true or Config.CharacterAmmunitionEnabled~=true
                or GetConvarInt('feather_native_utility',0)~=1
                or (spec.lassoFamily and GetConvarInt('feather_native_lasso_reinforced',0)~=1)
                or (spec.davyFamily and GetConvarInt('feather_native_davy_lantern',0)~=1)
                or (spec.binocularsFamily and GetConvarInt('feather_native_binoculars',0)~=1)
                or (spec.cameraFamily and GetConvarInt('feather_native_camera',0)~=1)
                or GetResourceState('feather-weapons')~='started' then return false end
            local ok,v=pcall(function()
                return exports['feather-core']:IsSessionCurrent(context.actorSource,context.sessionId,context.characterId)==true
                    and exports['feather-weapons']:ValidateNativeEquipmentCommit(context,spec)==true
            end)
            return ok and v==true
        end
        if not current() then return denied() end
        return TransactionAPI.Transaction({resource='feather-inventory',reason='native_utility_transition',
            actorSource=context.actorSource,characterId=context.characterId,sessionId=context.sessionId},function(tx)
            if not current() then return denied() end
            local wear=NativeLifecycleWear.Apply(tx,spec,current)
            if not wear or not wear.ok then return wear or denied() end
            local result=component.Apply(tx,wear.value,current)
            if not result or not result.ok then return result or denied() end
            if not current() then return denied() end
            return result
        end)
    end)
end
NativeUtilityExportInstaller=install
return install
