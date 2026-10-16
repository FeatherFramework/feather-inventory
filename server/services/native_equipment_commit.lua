-- Data-only server export. Inventory owns the transaction; Weapons must prove
-- its exact reserved intent and acknowledged release at every write boundary.
local function copy(value)
    if type(value)~='table' then return value end
    local out={}; for key,item in pairs(value) do out[key]=copy(item) end; return out
end
exports('ReadNativeEquipmentTransition',function(context,itemId)
    if GetInvokingResource()~='feather-weapons' or Config.DevMode~=true
        or Config.CharacterAmmunitionEnabled~=true or type(context)~='table'
        or (itemId~=nil and (type(itemId)~='number' or itemId<1 or itemId%1~=0 or itemId==math.huge)) then
        return Result.Err('equipment_preflight_denied','Current native equipment reader required.')
    end
    context=copy(context)
    local function current()
        return Config.DevMode==true and Config.CharacterAmmunitionEnabled==true
            and exports['feather-core']:IsSessionCurrent(context.actorSource,context.sessionId,context.characterId)==true
    end
    if not current() then return Result.Err('equipment_preflight_denied','Current session required.') end
    return TransactionAPI.Transaction({resource='feather-inventory',reason='native_equipment_preflight'},function(tx)
        if not current() then return Result.Err('equipment_preflight_denied','Session changed.') end
        local header=tx.query('SELECT id FROM inventory WHERE character_id=? LIMIT 1 FOR UPDATE',{context.characterId})
        if not header or not header[1] then return Result.Err('equipment_preflight_denied','Inventory missing.') end
        local rows=tx.query([[SELECT ce.slot, ce.inventory_items_id, ii.row_revision, inv.character_id AS owner_character
            FROM character_equipment ce LEFT JOIN inventory_items ii ON ii.id=ce.inventory_items_id
            LEFT JOIN inventory inv ON inv.id=ii.inventory_id WHERE ce.character_id=? ORDER BY ce.slot FOR UPDATE]],{context.characterId})
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
        local equipment=CharacterAmmunitionAPI.ReadRuntimeEquipment(tx,context.characterId)
        if not equipment.ok then return equipment end
        local candidate
        if itemId then
            local owned=tx.query([[SELECT ii.id, ii.row_revision, ii.metadata, i.name AS itemName
                FROM inventory_items ii INNER JOIN inventory inv ON inv.id=ii.inventory_id
                INNER JOIN items i ON i.id=ii.item_id WHERE ii.id=? AND inv.character_id=? FOR UPDATE]],{itemId,context.characterId})
            local row=owned and owned[1]
            if not row then return Result.Err('equipment_preflight_denied','Owned item required.') end
            local decoded,metadata=pcall(function() return type(row.metadata)=='table' and row.metadata or json.decode(row.metadata) end)
            if not decoded or type(metadata)~='table' then return Result.Err('equipment_preflight_denied','Item metadata unavailable.') end
            candidate={id=tonumber(row.id),revision=tonumber(row.row_revision),itemName=row.itemName,metadata=metadata}
        end
        if not current() then return Result.Err('equipment_preflight_denied','Session changed during read.') end
        return {ok=true,value={characterId=context.characterId,expected=expected,equipment=equipment.value,candidate=candidate}}
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
        local result=ConditionalEquipment.Apply(tx,working,current)
        if not result.ok then return result end
        if not current() then return Result.Err('equipment_commit_denied','Native release authority changed before commit.') end
        return result
    end)
end)
