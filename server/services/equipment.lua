-- (Weapons review #5) Persisted equipment slots.
--
-- The weapons provider needs GetEquippedForCharacter/SetEquippedForCharacter,
-- and the review's point is the load-bearing one: this state cannot live only
-- in weapons' memory, because it has to survive a reconnect and a resource or
-- server restart. Memory does not.
--
-- Kept GENERIC, per MASTER_PLAN §3 -- nothing here knows what a weapon is.
-- This is "which item instance is in which named slot for this character",
-- and `slot` is an arbitrary string the consumer chooses ('primary',
-- 'sidearm', 'holster', 'hat'). Inventory stores and constrains it; the
-- consumer decides what the names mean. A clothing resource can use the same
-- table without inventory learning about clothing.
--
-- Ownership is enforced here rather than trusted: an instance can only be
-- equipped by the character whose inventory currently holds it, re-derived
-- from the row itself. That check is why equipping is not simply a write.

EquipmentAPI = {}
local function NativeSlot(slot)
    return Config and Config.CharacterAmmunitionEnabled==true
        and (({weapon=true,weapon_offhand=true,weapon_shoulder=true,weapon_back=true})[slot]==true
            or (slot=='weapon_throwable' and type(GetConvarInt)=='function' and GetConvarInt('feather_native_throwable',0)==1)
            or (({weapon_melee=true,weapon_melee_secondary=true,weapon_melee_tertiary=true,
                weapon_melee_quaternary=true,weapon_melee_quinary=true})[slot]==true
                and type(GetConvarInt)=='function' and GetConvarInt('feather_native_melee',0)==1)
            or (slot=='weapon_melee' and type(GetConvarInt)=='function' and GetConvarInt('feather_native_knife',0)==1))
end
local function NativeSlotDenied()
    return Result.Err(Result.Codes.DENIED,'Native firearm assignments require the conditional native coordinator.')
end

local function CanChangeEquipment(rows, extraId)
    local ids={}
    if extraId then ids[extraId]=true end
    for _,row in ipairs(rows or {}) do
        local itemId=tonumber(row.inventory_items_id)
        if not itemId then return false,'Invalid equipment assignment.' end
        ids[itemId]=true
    end
    for itemId in pairs(ids) do
        local allowed,reason=GuardsAPI.CanChangeInstance(itemId,{operation='equipment_write'})
        if not allowed then return false,reason end
    end
    return true
end

local function EnsureEquipmentSchema()
    DB.exec([[
        CREATE TABLE IF NOT EXISTS `character_equipment` (
            `character_id` CHAR(36) NOT NULL,
            `slot` VARCHAR(50) NOT NULL,
            `inventory_items_id` BIGINT UNSIGNED NOT NULL,
            `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (`character_id`, `slot`),
            -- One instance cannot occupy two slots at once.
            UNIQUE KEY `UQ_EquipmentInstance` (`inventory_items_id`),
            -- Destroying the item unequips it, rather than leaving a row
            -- pointing at nothing. This is what makes "consumed while
            -- equipped" self-healing instead of a dangling reference.
            CONSTRAINT `FK_EquipmentInstance` FOREIGN KEY (`inventory_items_id`)
                REFERENCES `inventory_items` (`id`) ON DELETE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]])
end

CreateThread(function()
    InventoryAwaitDatabase()
    EnsureEquipmentSchema()
end)

---
-- Get Equipped For Character
--
-- @param characterId
-- @param slot Optional; omit for every slot
-- @return Result wrapping { [slot] = instanceId } or a single instanceId
--
function EquipmentAPI.GetEquippedForCharacter(characterId, slot)
    local id = InventoryIdentity.NormalizeCharacterId(characterId)
    if not id then
        return Result.Err(Result.Codes.INVALID_INPUT, 'Invalid character id.')
    end

    if slot then
        local row = DB.query(
            'SELECT `inventory_items_id` FROM `character_equipment` WHERE `character_id`=? AND `slot`=? LIMIT 1;',
            id, slot)[1]
        return Result.Ok(row and tonumber(row.inventory_items_id) or nil)
    end

    local rows = DB.query(
        'SELECT `slot`, `inventory_items_id` FROM `character_equipment` WHERE `character_id`=?;', id)
    local equipped = {}
    for _, row in pairs(rows or {}) do
        equipped[row.slot] = tonumber(row.inventory_items_id)
    end
    return Result.Ok(equipped)
end

---
-- Set Equipped For Character
--
-- Passing `nil` for instanceId clears the slot.
--
-- Rejects an instance the character does not actually hold. Equipping is a
-- claim about something you own, so it is verified against the instance's own
-- inventory row rather than taken on the caller's word -- the same
-- re-derive-don't-trust rule every other mutation here follows.
--
function EquipmentAPI.SetEquippedForCharacter(characterId, slot, instanceId)
    if NativeSlot(slot) then return NativeSlotDenied() end
    local id = InventoryIdentity.NormalizeCharacterId(characterId)
    if not id or type(slot) ~= 'string' or slot == '' then
        return Result.Err(Result.Codes.INVALID_INPUT, 'Character id and slot are required.')
    end

    if instanceId == nil then
        local denied
        local executed, committed = RunLegacyStyleTransaction(function(query)
            local rows=query('SELECT `inventory_items_id` FROM `character_equipment` WHERE `character_id`=? AND `slot`=? FOR UPDATE;',
                { id, slot })
            local allowed,reason=CanChangeEquipment(rows)
            if not allowed then denied=Result.Err(Result.Codes.DENIED,reason); return false end
            query('DELETE FROM `character_equipment` WHERE `character_id`=? AND `slot`=?;', { id, slot })
            return true
        end)
        if not executed or committed ~= true then
            return denied or Result.Err(Result.Codes.INTERNAL, 'Equipment update rolled back.')
        end
        return Result.Ok({ slot = slot, instanceId = nil })
    end

    local numericInstance = tonumber(instanceId)
    if not numericInstance then
        return Result.Err(Result.Codes.INVALID_INPUT, 'Invalid instance id.')
    end

    local failure
    local executed, committed = RunLegacyStyleTransaction(function(query)
        local owned = query([[
            SELECT ii.`id` FROM `inventory_items` ii
            INNER JOIN `inventory` inv ON inv.`id` = ii.`inventory_id`
            WHERE ii.`id` = ? AND inv.`character_id` = ? FOR UPDATE;
        ]], { numericInstance, id })[1]
        if not owned then
            failure = Result.Err(Result.Codes.DENIED, 'That item is not in this character\'s inventory.',
                { instanceId = numericInstance, characterId = id })
            return false
        end

        -- Lock both possible conflicts before changing either: the requested
        -- character slot and any slot currently holding this instance.
        local conflicts=query([[
            SELECT `inventory_items_id` FROM `character_equipment`
            WHERE (`character_id`=? AND `slot`=?) OR `inventory_items_id`=?
            ORDER BY `character_id`, `slot` FOR UPDATE;
        ]], { id, slot, numericInstance })
        local allowed,reason=CanChangeEquipment(conflicts,numericInstance)
        if not allowed then failure=Result.Err(Result.Codes.DENIED,reason); return false end
        query('DELETE FROM `character_equipment` WHERE (`character_id`=? AND `slot`=?) OR `inventory_items_id`=?;',
            { id, slot, numericInstance })
        query('INSERT INTO `character_equipment` (`character_id`, `slot`, `inventory_items_id`) VALUES (?, ?, ?);',
            { id, slot, numericInstance })
        return true
    end)
    if not executed or committed ~= true then
        return failure or Result.Err(Result.Codes.INTERNAL, 'Equipment update rolled back.')
    end

    return Result.Ok({ slot = slot, instanceId = numericInstance })
end

-- Compare-and-set several generic slots in one provider transaction. Zero means
-- empty. Every source/destination must be declared; an item cannot be stolen from
-- an undeclared slot. Existing single-slot APIs retain their contract.
local function ApplyEquipmentBatch(characterId, changes, collectionId, collectionPolicy)
    local character=InventoryIdentity.NormalizeCharacterId(characterId)
    if not character or type(changes)~='table' or #changes<1 or #changes>16 then
        return Result.Err(Result.Codes.INVALID_INPUT,'Invalid equipment batch.')
    end
    local slots,ids,ordered,snapshot={},{},{},{}
    for _,c in ipairs(changes) do
        if type(c)~='table' or type(c.slot)~='string' or #c.slot<1 or #c.slot>50
            or NativeSlot(c.slot) or slots[c.slot] or type(c.expected)~='number'
            or c.expected<0 or c.expected%1~=0 or type(c.instanceId)~='number'
            or c.instanceId<0 or c.instanceId%1~=0 then
            return Result.Err(Result.Codes.INVALID_INPUT,'Invalid equipment change.')
        end
        c={slot=c.slot,expected=c.expected,instanceId=c.instanceId}
        snapshot[#snapshot+1]=c
        slots[c.slot]=c;ordered[#ordered+1]=c.slot
        if c.instanceId>0 then
            if ids[c.instanceId] then return Result.Err(Result.Codes.INVALID_INPUT,'Duplicate destination item.') end
            ids[c.instanceId]=true
        end
    end
    changes=snapshot
    table.sort(ordered)
    local failure
    local executed,committed=RunLegacyStyleTransaction(function(query)
        local itemIds={}
        for _,c in ipairs(changes) do
            if c.expected>0 then itemIds[c.expected]=true end
            if c.instanceId>0 then itemIds[c.instanceId]=true end
        end
        local sorted={};for id in pairs(itemIds) do sorted[#sorted+1]=id end;table.sort(sorted)
        for _,id in ipairs(sorted) do
            local row
            if collectionId then
                row=query([[SELECT ii.id,ii.metadata,i.name,i.type,i.instance_mode FROM inventory_items ii
                    INNER JOIN items i ON i.id=ii.item_id
                    INNER JOIN inventory_character_collections c ON c.inventory_id=ii.inventory_id
                    INNER JOIN inventory inv ON inv.id=c.inventory_id AND inv.location='character_collection'
                        AND inv.character_id IS NULL AND inv.owner_character_id IS NULL AND inv.is_public=0
                    WHERE ii.id=? AND c.inventory_id=? AND c.character_id=? AND c.source_resource=? AND c.collection_key=? FOR UPDATE]],
                    {id,collectionId,character,collectionPolicy.resource,collectionPolicy.key})[1]
                if row and not CharacterCollectionAPI.Allowed(collectionPolicy,row) then row=nil end
            else
                row=query([[SELECT ii.id FROM inventory_items ii
                    INNER JOIN inventory inv ON inv.id=ii.inventory_id
                    WHERE ii.id=? AND inv.character_id=? FOR UPDATE]],{id,character})[1]
            end
            if not row then failure=Result.Err(Result.Codes.DENIED,'Equipment item is not owned.');return false end
        end
        local rows=query([[SELECT slot,inventory_items_id FROM character_equipment
            WHERE character_id=? ORDER BY slot FOR UPDATE]],{character})
        local current={}
        for _,r in ipairs(rows) do
            current[r.slot]=tonumber(r.inventory_items_id)
            if ids[tonumber(r.inventory_items_id)] and not slots[r.slot] then
                failure=Result.Err(Result.Codes.DENIED,'Equipment source changed.');return false
            end
        end
        for _,c in ipairs(changes) do
            if (current[c.slot] or 0)~=c.expected then
                failure=Result.Err(Result.Codes.CONFLICT or Result.Codes.DENIED,'Equipment changed.');return false
            end
        end
        for _,id in ipairs(sorted) do
            local allowed,reason=GuardsAPI.CanChangeInstance(id,{operation='equipment_write'})
            if allowed~=true then failure=Result.Err(Result.Codes.DENIED,reason);return false end
        end
        for _,slot in ipairs(ordered) do
            query('DELETE FROM character_equipment WHERE character_id=? AND slot=?',{character,slot})
        end
        for _,slot in ipairs(ordered) do
            local id=slots[slot].instanceId
            if id>0 then query('INSERT INTO character_equipment (character_id,slot,inventory_items_id) VALUES (?,?,?)',{character,slot,id}) end
        end
        return true
    end)
    if not executed or committed~=true then return failure or Result.Err(Result.Codes.INTERNAL,'Equipment batch rolled back.') end
    return Result.Ok({changed=true})
end

function EquipmentAPI.SetEquipmentBatchForCharacter(characterId,changes)
    return ApplyEquipmentBatch(characterId,changes)
end
function EquipmentAPI.SetCollectionEquipmentBatch(characterId,changes,collectionId,policy)
    return ApplyEquipmentBatch(characterId,changes,collectionId,policy)
end

---
-- Promote Equipped Slot
--
-- Atomically removes the destination assignment and moves the source
-- assignment into it. Item ownership does not change.
--
function EquipmentAPI.PromoteEquippedSlot(characterId, fromSlot, toSlot)
    if NativeSlot(fromSlot) or NativeSlot(toSlot) then return NativeSlotDenied() end
    local id = InventoryIdentity.NormalizeCharacterId(characterId)
    if not id or type(fromSlot) ~= 'string' or fromSlot == ''
        or type(toSlot) ~= 'string' or toSlot == '' or fromSlot == toSlot then
        return Result.Err(Result.Codes.INVALID_INPUT,
            'Character id and two distinct equipment slots are required.')
    end

    local promotedId,denied
    local executed, committed = RunLegacyStyleTransaction(function(query)
        local rows = query([[
            SELECT `slot`, `inventory_items_id` FROM `character_equipment`
            WHERE `character_id`=? AND `slot` IN (?, ?)
            ORDER BY `slot` FOR UPDATE;
        ]], { id, fromSlot, toSlot })
        for _, row in ipairs(rows or {}) do
            if row.slot == fromSlot then promotedId = tonumber(row.inventory_items_id) end
        end
        if not promotedId then return false end
        local allowed,reason=CanChangeEquipment(rows)
        if not allowed then denied=Result.Err(Result.Codes.DENIED,reason); return false end
        query('DELETE FROM `character_equipment` WHERE `character_id`=? AND `slot`=?;',
            { id, toSlot })
        local updated = query([[UPDATE `character_equipment` SET `slot`=?
            WHERE `character_id`=? AND `slot`=? AND `inventory_items_id`=?;]],
            { toSlot, id, fromSlot, promotedId })
        local affected = tonumber(updated and (updated.affectedRows or updated.affected_rows)) or 0
        if affected ~= 1 then return false end
        return true
    end)
    if not executed or committed ~= true then
        return denied or Result.Err(Result.Codes.CONFLICT,
            'Equipment slot promotion rolled back.')
    end
    return Result.Ok({ fromSlot = fromSlot, toSlot = toSlot,
        instanceId = promotedId })
end

---
-- Clear Equipped Instance
--
-- Unequips an instance wherever it happens to be slotted, without the caller
-- needing to know which character or slot holds it. This is what a move guard
-- calls when it decides to force an unequip rather than veto.
--
function EquipmentAPI.ClearEquippedInstance(instanceId)
    local numericInstance = tonumber(instanceId)
    if not numericInstance then
        return Result.Err(Result.Codes.INVALID_INPUT, 'Invalid instance id.')
    end
    local denied
    local executed, committed = RunLegacyStyleTransaction(function(query)
        local assignments=query('SELECT `character_id`, `slot` FROM `character_equipment` WHERE `inventory_items_id`=? FOR UPDATE;',
            { numericInstance })
        if type(assignments)~='table' then denied=Result.Err(Result.Codes.DENIED,'Equipment unavailable.'); return false end
        for _,assignment in ipairs(assignments) do
            if NativeSlot(assignment.slot) then denied=NativeSlotDenied(); return false end
        end
        local allowed,reason=CanChangeEquipment({},numericInstance)
        if not allowed then denied=Result.Err(Result.Codes.DENIED,reason); return false end
        query('DELETE FROM `character_equipment` WHERE `inventory_items_id`=?;', { numericInstance })
        return true
    end)
    if not executed or committed ~= true then
        return denied or Result.Err(Result.Codes.INTERNAL, 'Equipment clear rolled back.')
    end
    return Result.Ok(true)
end

---
-- Is Instance Equipped
--
-- Cheap enough for a guard to call on every move.
--
function EquipmentAPI.IsInstanceEquipped(instanceId)
    local equipped, verified = GuardsAPI.GetLockedEquipmentState(instanceId)
    if verified then return Result.Ok(equipped) end
    local row = DB.query(
        'SELECT `character_id`, `slot` FROM `character_equipment` WHERE `inventory_items_id`=? LIMIT 1;',
        tonumber(instanceId))[1]
    return Result.Ok(row ~= nil)
end
