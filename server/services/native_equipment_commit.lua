-- Data-only server export. Inventory owns the transaction; Weapons must prove
-- its exact reserved intent and acknowledged release at every write boundary.
local function copy(value)
    if type(value)~='table' then return value end
    local out={}; for key,item in pairs(value) do out[key]=copy(item) end; return out
end
-- Native knife remains default-off; these trusted exports do not create a route,
-- enrollment, grant or Weapons reservation by themselves.
local function registerMeleeExports(name,convar,componentName,slots)
exports('ReadNative'..name..'Equipment',function(context,itemId)
    if GetInvokingResource()~='feather-weapons' or type(context)~='table'
        or (itemId~=nil and (type(itemId)~='number' or itemId<1 or itemId%1~=0 or itemId==math.huge)) then
        return Result.Err('knife_reader_denied','Trusted current knife reader required.')
    end
    local bound={actorSource=context.actorSource,characterId=context.characterId,sessionId=context.sessionId}
    local function current()
        return Config.DevMode==true and Config.CharacterAmmunitionEnabled==true
            and type(GetConvarInt)=='function' and GetConvarInt(convar,0)==1
            and exports['feather-core']:IsSessionCurrent(bound.actorSource,bound.sessionId,bound.characterId)==true
    end
    local component=_G[componentName]
    if not current() or not component then return Result.Err('knife_reader_denied','Melee components disabled/unavailable.') end
    return TransactionAPI.Transaction({resource='feather-inventory',reason='native_knife_equipment_read'},function(tx)
        return component.Read(tx,bound.characterId,itemId,current)
    end)
end)
exports('CommitNative'..name..'Equipment',function(context,spec)
    if GetInvokingResource()~='feather-weapons' or type(context)~='table' or type(spec)~='table'
        or context.characterId~=spec.characterId or not slots[spec.slot]
        or (spec.action~='equip' and spec.action~='unequip') then
        return Result.Err('knife_commit_denied','Reserved knife equipment intent required.')
    end
    spec=copy(spec)
    local bound={actorSource=context.actorSource,characterId=context.characterId,sessionId=context.sessionId,
        epoch=context.epoch,ticket=context.ticket}
    local function current()
        if Config.DevMode~=true or Config.CharacterAmmunitionEnabled~=true
            or type(GetConvarInt)~='function' or GetConvarInt(convar,0)~=1
            or GetResourceState('feather-weapons')~='started' then return false end
        local ok,value=pcall(function()
            return exports['feather-core']:IsSessionCurrent(bound.actorSource,bound.sessionId,bound.characterId)==true
                and exports['feather-weapons']:ValidateNativeEquipmentCommit(bound,spec)==true
        end)
        return ok and value==true
    end
    local component=_G[componentName]
    if not current() or not component or type(spec.lifecycleSnapshot)~='table'
        or type(spec.lifecycleWear)~='table' then return Result.Err('knife_commit_denied','Released knife/final-wear authority required.') end
    return TransactionAPI.Transaction({resource='feather-inventory',reason='native_knife_equipment_transition'},function(tx)
        if not current() then return Result.Err('knife_commit_denied','Knife authority changed.') end
        local observed=NativeLifecycleWear.Apply(tx,spec,current)
        if not observed.ok then return observed end
        local result=component.Apply(tx,observed.value,current)
        if not result.ok then return result end
        if not current() then return Result.Err('knife_commit_denied','Knife authority changed before commit.') end
        return result
    end)
end)
end
registerMeleeExports('Knife','feather_native_knife','NativeKnifeEquipment',{weapon_melee=true})
-- Staged multi-slot route: flag defaults off; no caller can mint a reservation
-- here. The existing Weapons validator must authorize the exact released intent.
registerMeleeExports('Melee','feather_native_melee','NativeMeleeEquipment',{
    weapon_melee=true,weapon_melee_secondary=true,weapon_melee_tertiary=true,
    weapon_melee_quaternary=true,weapon_melee_quinary=true})
registerMeleeExports('Throwable','feather_native_throwable','NativeThrowableEquipment',{weapon_throwable=true})
exports('CommitNativeThrowableFunding',function(context,spec)
    if GetInvokingResource()~='feather-weapons' or type(context)~='table' or type(spec)~='table'
        or context.characterId~=spec.characterId or spec.action~='throwable-funding'
        or spec.throwable~=true or spec.slot~='weapon_throwable' then
        return Result.Err('throwable_funding_denied','Reserved throwable funding required.')
    end
    context,spec=copy(context),copy(spec)
    local function current()
        if Config.DevMode~=true or Config.CharacterAmmunitionEnabled~=true
            or GetConvarInt('feather_native_throwable',0)~=1 or GetResourceState('feather-weapons')~='started' then return false end
        local ok,allowed=pcall(function()
            return exports['feather-core']:IsSessionCurrent(context.actorSource,context.sessionId,context.characterId)==true
                and exports['feather-weapons']:ValidateNativeEquipmentCommit(context,spec)==true
        end)
        return ok and allowed==true
    end
    if not current() or type(spec.lifecycleSnapshot)~='table' or type(spec.lifecycleWear)~='table' then
        return Result.Err('throwable_funding_denied','Released final-wear authority required.')
    end
    return TransactionAPI.Transaction({resource='feather-weapons',reason='native_throwable_funding',
        actorSource=context.actorSource,actorCharacterId=context.characterId,characterId=context.characterId,
        sessionId=context.sessionId,correlationId=spec.operationId},function(tx)
        if not current() then return Result.Err('throwable_funding_denied','Funding authority changed.') end
        local observed=NativeLifecycleWear.Apply(tx,spec,current)
        if not observed.ok then return observed end
        return CharacterAmmunitionAPI.ApplyThrowableFunding(tx,context,observed.value,current)
    end)
end)
exports('ReadNativeEquipmentTransition',function(context,itemId,limits)
    if GetInvokingResource()~='feather-weapons' or Config.DevMode~=true
        or Config.CharacterAmmunitionEnabled~=true or type(context)~='table'
        or (itemId~=nil and (type(itemId)~='number' or itemId<1 or itemId%1~=0 or itemId==math.huge)) then
        return Result.Err('equipment_preflight_denied','Current native equipment reader required.')
    end
    context=copy(context); limits=copy(limits)
    local function current()
        return Config.DevMode==true and Config.CharacterAmmunitionEnabled==true
            and exports['feather-core']:IsSessionCurrent(context.actorSource,context.sessionId,context.characterId)==true
    end
    if not current() then return Result.Err('equipment_preflight_denied','Current session required.') end
    return TransactionAPI.Transaction({resource='feather-inventory',reason='native_equipment_preflight'},function(tx)
        if not current() then return Result.Err('equipment_preflight_denied','Session changed.') end
        local function finish(locked)
        if not locked then
        local header=tx.query('SELECT id FROM inventory WHERE character_id=? LIMIT 1 FOR UPDATE',{context.characterId})
        if not header or not header[1] then return Result.Err('equipment_preflight_denied','Inventory missing.') end
        end
        local rows
        if locked then rows=locked.ReadEquipment(tx,context.characterId)
        else rows=tx.query([[SELECT ce.slot, ce.inventory_items_id, ii.row_revision, inv.character_id AS owner_character
            FROM character_equipment ce LEFT JOIN inventory_items ii ON ii.id=ce.inventory_items_id
            LEFT JOIN inventory inv ON inv.id=ii.inventory_id WHERE ce.character_id=? ORDER BY ce.slot FOR UPDATE]],{context.characterId}) end
        if type(rows)~='table' then return Result.Err('equipment_preflight_denied','Equipment unavailable.') end
        local expected={}
        for _,row in ipairs(rows) do
            local id,revision=tonumber(row.inventory_items_id),tonumber(row.row_revision)
            if type(row.slot)~='string' or expected[row.slot] or not id or id<1 or id%1~=0
                or not revision or revision<0 or revision%1~=0 or row.owner_character~=context.characterId then
                return Result.Err('equipment_preflight_denied','Invalid equipment ownership.')
            end
            expected[row.slot]={itemId=id,revision=revision}
        end
        local equipment=CharacterAmmunitionAPI.ReadRuntimeEquipment(tx,context.characterId,locked)
        if not equipment.ok then return equipment end
        local candidate
        if itemId then
            local owned=locked and locked.ReadItem(tx,context.characterId,itemId)
            if locked and owned==nil then return Result.Err('equipment_preflight_denied','Snapshot expired.') end
            if not owned then owned=tx.query([[SELECT ii.id, ii.row_revision, ii.metadata, i.name AS itemName
                FROM inventory_items ii INNER JOIN inventory inv ON inv.id=ii.inventory_id
                INNER JOIN items i ON i.id=ii.item_id WHERE ii.id=? AND inv.character_id=? FOR UPDATE]],{itemId,context.characterId}) end
            local row=owned and owned[1]
            if not row then return Result.Err('equipment_preflight_denied','Owned item required.') end
            local decoded,metadata=pcall(function() return type(row.metadata)=='table' and row.metadata or json.decode(row.metadata) end)
            if not decoded or type(metadata)~='table' then return Result.Err('equipment_preflight_denied','Item metadata unavailable.') end
            candidate={id=tonumber(row.id),revision=tonumber(row.row_revision),itemName=row.itemName,metadata=metadata}
        end
        if not current() then return Result.Err('equipment_preflight_denied','Session changed during read.') end
        local value={characterId=context.characterId,expected=expected,equipment=equipment.value,candidate=candidate,
            brokenEquipmentContract=1,brokenDeathEquipmentContract=1,brokenPromotionContract=1}
        if type(GetConvarInt)=='function' and GetConvarInt('feather_native_utility',0)==1 then
            if not NativeUtilityEquipment then return Result.Err('equipment_preflight_denied','Utility reader unavailable.') end
            local function utilityCurrent() return current() and GetConvarInt('feather_native_utility',0)==1 end
            local read=NativeUtilityEquipment.Read(tx,context.characterId,utilityCurrent,locked)
            if not read.ok then return read end
            value.utilityEquipment=read.value
            if not utilityCurrent() then return Result.Err('equipment_preflight_denied','Utility authority changed.') end
        end
        if type(GetConvarInt)=='function' and GetConvarInt('feather_native_throwable',0)==1 then
            if not NativeThrowableEquipment then return Result.Err('equipment_preflight_denied','Throwable reader unavailable.') end
            local function throwableCurrent() return current() and GetConvarInt('feather_native_throwable',0)==1 end
            local read=NativeThrowableEquipment.Read(tx,context.characterId,nil,throwableCurrent,locked)
            if not read.ok then return read end
            value.throwableEquipment=read.value
            if limits~=nil then
                if type(limits)~='table' or limits.ammo_tomahawk_regular~=1 then
                    return Result.Err('equipment_preflight_denied','Explicit throwable funding limits required.')
                end
                local ledger=CharacterAmmunitionAPI.ReadSnapshot(tx,context.characterId,limits,false)
                if not ledger.ok then return ledger end
                value.throwableEquipment.revision=ledger.value.revision
                value.throwableEquipment.pools=copy(ledger.value.pools)
            end
            if not throwableCurrent() then return Result.Err('equipment_preflight_denied','Throwable authority changed.') end
        end
        if type(GetConvarInt)=='function' and GetConvarInt('feather_native_melee',0)==1 then
            if not NativeMeleeEquipment then return Result.Err('equipment_preflight_denied','Melee reader unavailable.') end
            local function meleeCurrent() return current() and GetConvarInt('feather_native_melee',0)==1 end
            local read=NativeMeleeEquipment.Read(tx,context.characterId,nil,meleeCurrent,locked)
            if not read.ok then return read end
            value.meleeEquipment=read.value
        elseif Config.DevMode==true and type(GetConvarInt)=='function' and GetConvarInt('feather_native_knife',0)==1 then
            if not NativeKnifeEquipment then return Result.Err('equipment_preflight_denied','Knife reader unavailable.') end
            local read=NativeKnifeEquipment.Read(tx,context.characterId,nil,current,locked)
            if not read.ok then return read end
            value.knifeEquipment=read.value
        end
        return {ok=true,value=value}
        end
        if NativeEquipmentSnapshot then return NativeEquipmentSnapshot.With(tx,context.characterId,current,false,finish) end
        return finish()
    end)
end)
exports('ReadNativeRepairMaterial',function(context,itemName)
    if GetInvokingResource()~='feather-weapons' or Config.DevMode~=true
        or Config.CharacterAmmunitionEnabled~=true or type(context)~='table'
        or type(itemName)~='string' or #itemName<1 or #itemName>100 then
        return Result.Err('repair_preflight_denied','Scoped repair reader required.')
    end
    context=copy(context)
    local function current()
        return Config.DevMode==true and Config.CharacterAmmunitionEnabled==true
            and exports['feather-core']:IsSessionCurrent(context.actorSource,context.sessionId,context.characterId)==true
    end
    if not current() then return Result.Err('repair_preflight_denied','Current session required.') end
    return TransactionAPI.Transaction({resource='feather-inventory',reason='native_repair_material_preflight'},function(tx)
        if not current() then return Result.Err('repair_preflight_denied','Session changed.') end
        local header=tx.query('SELECT id FROM inventory WHERE character_id=? LIMIT 1',{context.characterId})
        local inventoryId=header and header[1] and tonumber(header[1].id)
        local rows=tx.query('SELECT id, name FROM items WHERE name=? LIMIT 1',{itemName})
        local row=rows and rows[1]
        local id=row and tonumber(row.id)
        if not current() or not inventoryId or inventoryId<1 or inventoryId%1~=0 or inventoryId==math.huge
            or not id or id<1 or id%1~=0 or id==math.huge or row.name~=itemName then
            return Result.Err('repair_preflight_denied','Material definition unavailable.')
        end
        local quantity=tx:GetQuantity(inventoryId,id)
        if not current() or type(quantity)~='number' or quantity<0 or quantity%1~=0 or quantity==math.huge then
            return Result.Err('repair_preflight_denied','Owned repair quantity unavailable.')
        end
        return Result.Ok({definitionId=id,itemName=itemName,quantity=quantity,noWrites=true})
    end)
end)
exports('CommitNativeRepairTransition',function(context,spec)
    if GetInvokingResource()~='feather-weapons' or Config.DevMode~=true
        or Config.CharacterAmmunitionEnabled~=true or type(context)~='table' or type(spec)~='table'
        or (spec.action~='repair' and spec.action~='maintenance') or context.characterId~=spec.characterId then
        return Result.Err('repair_commit_denied','Reserved native repair required.')
    end
    context,spec=copy(context),copy(spec)
    local function current()
        if Config.DevMode~=true or Config.CharacterAmmunitionEnabled~=true
            or GetResourceState('feather-weapons')~='started' then return false end
        local called,allowed=pcall(function()
            return exports['feather-core']:IsSessionCurrent(context.actorSource,context.sessionId,context.characterId)==true
                and exports['feather-weapons']:ValidateNativeEquipmentCommit(context,spec)==true
        end)
        return called and allowed==true
    end
    if not current() then return Result.Err('repair_commit_denied','Released repair authority required.') end
    return TransactionAPI.Transaction({resource='feather-inventory',reason='native_repair_transition',
        actorSource=context.actorSource,characterId=context.characterId,sessionId=context.sessionId},function(tx)
        local result=NativeRepairCommit.Apply(tx,spec,current)
        if not result.ok then return result end
        if spec.brokenEquipment~=nil then
            local working=copy(spec)
            for _,row in pairs(working.expected) do if row.itemId==spec.itemId then row.revision=row.revision+1 end end
            local detached=NativeLifecycleWear.DetachBroken(tx,working,current)
            if not detached.ok then return detached end
        end
        if not current() then return Result.Err('repair_commit_denied','Repair authority changed before commit.') end
        return result
    end)
end)
exports('ReadNativeAttachmentMaterial',function(context,itemName)
    itemName=itemName or 'carbine_wide_sight' -- backwards-compatible console gate
    if GetInvokingResource()~='feather-weapons' or Config.DevMode~=true or Config.CharacterAmmunitionEnabled~=true
        or type(context)~='table' or type(itemName)~='string' or #itemName<1 or #itemName>100 then return Result.Err('attachment_preflight_denied','Current attachment reader required.') end
    context=copy(context)
    local function current()
        return Config.DevMode==true and Config.CharacterAmmunitionEnabled==true
            and GetConvarInt('feather_native_attachment_transactions',0)==1
            and exports['feather-core']:IsSessionCurrent(context.actorSource,context.sessionId,context.characterId)==true
    end
    if not current() then return Result.Err('attachment_preflight_denied','Current attachment scope required.') end
    return TransactionAPI.Transaction({resource='feather-inventory',reason='native_attachment_material_read'},function(tx)
        local header=tx.query('SELECT id FROM inventory WHERE character_id=? LIMIT 1',{context.characterId})
        local inventoryId=header and header[1] and tonumber(header[1].id)
        local rows=tx.query('SELECT id, name FROM items WHERE name=? AND archived_at IS NULL LIMIT 1',{itemName})
        local row=rows and rows[1]; local id=row and tonumber(row.id)
        if not current() or not inventoryId or not id or row.name~=itemName then
            return Result.Err('attachment_preflight_denied','Owned inventory/material definition unavailable.')
        end
        local quantity=tx:GetQuantity(inventoryId,id)
        if not current() or type(quantity)~='number' or quantity<0 or quantity%1~=0 or quantity==math.huge then
            return Result.Err('attachment_preflight_denied','Attachment quantity unavailable.')
        end
        return Result.Ok({definitionId=id,itemName=row.name,quantity=quantity,noWrites=true})
    end)
end)
exports('CommitNativeAttachmentTransition',function(context,spec)
    if GetInvokingResource()~='feather-weapons' or Config.DevMode~=true or Config.CharacterAmmunitionEnabled~=true
        or type(context)~='table' or type(spec)~='table' or context.characterId~=spec.characterId
        or (spec.action~='attachment-install' and spec.action~='attachment-remove') then
        return Result.Err('attachment_commit_denied','Reserved native attachment intent required.')
    end
    context,spec=copy(context),copy(spec)
    local function current()
        if Config.DevMode~=true or Config.CharacterAmmunitionEnabled~=true or GetResourceState('feather-weapons')~='started'
            or GetConvarInt('feather_native_attachment_transactions',0)~=1 then return false end
        local called,allowed=pcall(function()
            return exports['feather-core']:IsSessionCurrent(context.actorSource,context.sessionId,context.characterId)==true
                and exports['feather-weapons']:ValidateNativeEquipmentCommit(context,spec)==true
        end)
        return called and allowed==true
    end
    if not current() or type(spec.lifecycleSnapshot)~='table' or type(spec.lifecycleWear)~='table' then
        return Result.Err('attachment_commit_denied','Released attachment/final-wear authority required.')
    end
    return TransactionAPI.Transaction({resource='feather-inventory',reason='native_attachment_transition',
        actorSource=context.actorSource,characterId=context.characterId,sessionId=context.sessionId},function(tx)
        if not current() then return Result.Err('attachment_commit_denied','Attachment authority changed.') end
        local observed=NativeLifecycleWear.Apply(tx,spec,current)
        if not observed.ok then return observed end
        local working=observed.value
        -- Wear uses its own canonical CAS in this same transaction. Rebase the
        -- attachment CAS, preserving the exact finalized attachment delta.
        for _,change in ipairs(spec.lifecycleWear) do
            if change.itemId==spec.itemId then
                working.itemRevision=spec.itemRevision+1
                working.before=copy(change.after)
            end
        end
        local result=NativeAttachmentCommit.Apply(tx,working,current)
        if not result.ok then return result end
        if not current() then return Result.Err('attachment_commit_denied','Attachment authority changed before commit.') end
        return result
    end)
end)
exports('CommitNativeEquipmentTransition',function(context,spec)
    if GetInvokingResource()~='feather-weapons' or Config.DevMode~=true
        or Config.CharacterAmmunitionEnabled~=true or type(context)~='table' or type(spec)~='table'
        or (spec.action~='equip' and spec.action~='unequip'
            and not (spec.action=='shutdown' and type(spec.lifecycleWear)=='table'))
        or context.characterId~=spec.characterId then
        return Result.Err('equipment_commit_denied','Reserved native equipment intent required.')
    end
    context,spec=copy(context),copy(spec)
    local function current()
        if Config.DevMode~=true or Config.CharacterAmmunitionEnabled~=true
            or GetResourceState('feather-weapons')~='started' then return false end
        local called,allowed=pcall(function()
            return exports['feather-core']:IsSessionCurrent(context.actorSource,context.sessionId,context.characterId)==true
                and exports['feather-weapons']:ValidateNativeEquipmentCommit(context,spec)==true
        end)
        return called and allowed==true
    end
    if not current() then return Result.Err('equipment_commit_denied','Native release authority unavailable.') end
    -- Do not catch transaction exceptions as retryable refusals: the coordinator
    -- treats an exception/ambiguous acknowledgement as uncertain, never retries.
    return TransactionAPI.Transaction({resource='feather-inventory',reason='native_equipment_transition'},function(tx)
        if not current() then return Result.Err('equipment_commit_denied','Native release authority changed.') end
        local working=spec
        if spec.lifecycleSnapshot then
            local observed=NativeLifecycleWear.Apply(tx,spec,current)
            if not observed.ok then return observed end
            working=observed.value
        end
        if spec.action=='shutdown' then
            if not current() then return Result.Err('equipment_commit_denied','Final wear authority changed.') end
            return Result.Ok({unchanged=true,wearChanges=#spec.lifecycleWear})
        end
        -- Final wear may already have removed the requested old assignment.
        if spec.action=='unequip' and spec.expected[spec.slot]
            and (not working.expected[spec.slot] or working.expected[spec.slot].itemId~=spec.expected[spec.slot].itemId)
            and spec.brokenEquipment and spec.brokenEquipment[spec.slot] then
            if not current() then return Result.Err('equipment_commit_denied','Broken equipment authority changed.') end
            return Result.Ok({slot=spec.slot,brokenUnequipped=true})
        end
        local result=ConditionalEquipment.Apply(tx,working,current)
        if not result.ok then return result end
        if not current() then return Result.Err('equipment_commit_denied','Native release authority changed before commit.') end
        return result
    end)
end)
