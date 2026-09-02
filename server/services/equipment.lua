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

local function EnsureEquipmentSchema()
    MySQL.query.await([[
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
        local row = MySQL.query.await(
            'SELECT `inventory_items_id` FROM `character_equipment` WHERE `character_id`=? AND `slot`=? LIMIT 1;',
            { id, slot })[1]
        return Result.Ok(row and tonumber(row.inventory_items_id) or nil)
    end

    local rows = MySQL.query.await(
        'SELECT `slot`, `inventory_items_id` FROM `character_equipment` WHERE `character_id`=?;', { id })
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
    local id = InventoryIdentity.NormalizeCharacterId(characterId)
    if not id or type(slot) ~= 'string' or slot == '' then
        return Result.Err(Result.Codes.INVALID_INPUT, 'Character id and slot are required.')
    end

    if instanceId == nil then
        local executed, committed = pcall(MySQL.startTransaction, function(query)
            query('SELECT `inventory_items_id` FROM `character_equipment` WHERE `character_id`=? AND `slot`=? FOR UPDATE;',
                { id, slot })
            query('DELETE FROM `character_equipment` WHERE `character_id`=? AND `slot`=?;', { id, slot })
            return true
        end)
        if not executed or committed ~= true then
            return Result.Err(Result.Codes.INTERNAL, 'Equipment update rolled back.')
        end
        return Result.Ok({ slot = slot, instanceId = nil })
    end

    local numericInstance = tonumber(instanceId)
    if not numericInstance then
        return Result.Err(Result.Codes.INVALID_INPUT, 'Invalid instance id.')
    end

    local failure
    local executed, committed = pcall(MySQL.startTransaction, function(query)
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
        query([[
            SELECT `inventory_items_id` FROM `character_equipment`
            WHERE (`character_id`=? AND `slot`=?) OR `inventory_items_id`=?
            ORDER BY `character_id`, `slot` FOR UPDATE;
        ]], { id, slot, numericInstance })
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

---
-- Promote Equipped Slot
--
-- Atomically removes the destination assignment and moves the source
-- assignment into it. Item ownership does not change.
--
function EquipmentAPI.PromoteEquippedSlot(characterId, fromSlot, toSlot)
    local id = InventoryIdentity.NormalizeCharacterId(characterId)
    if not id or type(fromSlot) ~= 'string' or fromSlot == ''
        or type(toSlot) ~= 'string' or toSlot == '' or fromSlot == toSlot then
        return Result.Err(Result.Codes.INVALID_INPUT,
            'Character id and two distinct equipment slots are required.')
    end

    local promotedId
    local executed, committed = pcall(MySQL.startTransaction, function(query)
        local rows = query([[
            SELECT `slot`, `inventory_items_id` FROM `character_equipment`
            WHERE `character_id`=? AND `slot` IN (?, ?)
            ORDER BY `slot` FOR UPDATE;
        ]], { id, fromSlot, toSlot })
        for _, row in ipairs(rows or {}) do
            if row.slot == fromSlot then promotedId = tonumber(row.inventory_items_id) end
        end
        if not promotedId then return false end
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
        return Result.Err(Result.Codes.CONFLICT,
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
    local executed, committed = pcall(MySQL.startTransaction, function(query)
        query('SELECT `character_id`, `slot` FROM `character_equipment` WHERE `inventory_items_id`=? FOR UPDATE;',
            { numericInstance })
        query('DELETE FROM `character_equipment` WHERE `inventory_items_id`=?;', { numericInstance })
        return true
    end)
    if not executed or committed ~= true then
        return Result.Err(Result.Codes.INTERNAL, 'Equipment clear rolled back.')
    end
    return Result.Ok(true)
end

---
-- Is Instance Equipped
--
-- Cheap enough for a guard to call on every move.
--
function EquipmentAPI.IsInstanceEquipped(instanceId)
    local row = MySQL.query.await(
        'SELECT `character_id`, `slot` FROM `character_equipment` WHERE `inventory_items_id`=? LIMIT 1;',
        { tonumber(instanceId) })[1]
    return Result.Ok(row ~= nil)
end
