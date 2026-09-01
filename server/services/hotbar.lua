HotbarAPI = {}

local function HotbarEnabled()
    return Config.Hotbar and Config.Hotbar.Enabled == true
end

local function SlotCount()
    local configured = math.floor(tonumber(Config.Hotbar and Config.Hotbar.Slots) or 6)
    return math.max(1, math.min(configured, 8))
end

local function CharacterContext(src)
    local player = InventoryIdentity.GetCharacter(src)
    local character = player and player.char
    if not character then return nil, nil end
    local characterId = InventoryIdentity.NormalizeCharacterId(character.id)
    if not characterId then return nil, nil end
    return characterId, InventoryControllers.GetInventoryByCharacter(characterId)
end

local schemaReady = false
local function EnsureHotbarSchema()
    if schemaReady then return end
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `character_hotbar_bindings` (
            `character_id` CHAR(36) NOT NULL,
            `slot` TINYINT UNSIGNED NOT NULL,
            `item_name` VARCHAR(100) NOT NULL,
            `instance_id` BIGINT UNSIGNED NULL,
            `created_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (`character_id`, `slot`),
            INDEX `idx_hotbar_instance` (`instance_id`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])
    schemaReady = true
end

CreateThread(function()
    EnsureHotbarSchema()
end)

local function ResolveBinding(inventoryId, binding)
    local definition = ItemControllers.GetItemDefinitionByName(binding.item_name)
    if not definition then return nil end

    local instanceId
    local quantity = 0
    if binding.instance_id then
        local row = MySQL.single.await([[
            SELECT `id` FROM `inventory_items`
            WHERE `id`=? AND `inventory_id`=? LIMIT 1;
        ]], { binding.instance_id, inventoryId })
        instanceId = row and tonumber(row.id) or nil
        quantity = instanceId and 1 or 0
    else
        local row = MySQL.single.await([[
            SELECT MIN(ii.`id`) AS `id`, COUNT(*) AS `quantity`
            FROM `inventory_items` ii
            INNER JOIN `items` i ON i.`id`=ii.`item_id`
            WHERE ii.`inventory_id`=? AND i.`name`=?;
        ]], { inventoryId, binding.item_name })
        instanceId = row and tonumber(row.id) or nil
        quantity = tonumber(row and row.quantity) or 0
    end

    return {
        slot = tonumber(binding.slot),
        itemName = definition.name,
        displayName = definition.display_name,
        instanceMode = definition.instance_mode,
        instanceId = instanceId,
        quantity = quantity,
        available = instanceId ~= nil and quantity > 0,
        usable = definition.usable == true or tonumber(definition.usable) == 1,
    }
end

function HotbarAPI.GetBindings(src)
    EnsureHotbarSchema()
    local characterId, inventoryId = CharacterContext(src)
    if not characterId or not inventoryId then
        return Result.Err('no_character', 'No character is loaded for that player.')
    end

    local rows = MySQL.query.await([[
        SELECT `slot`, `item_name`, `instance_id`
        FROM `character_hotbar_bindings`
        WHERE `character_id`=? ORDER BY `slot`;
    ]], { characterId }) or {}
    local bindings = {}
    for _, row in ipairs(rows) do
        local resolved = ResolveBinding(inventoryId, row)
        if resolved then bindings[#bindings + 1] = resolved end
    end
    return Result.Ok({ enabled=HotbarEnabled(), slots=SlotCount(), bindings=bindings })
end

function HotbarAPI.SetBinding(src, slot, itemId)
    EnsureHotbarSchema()
    if not HotbarEnabled() then return Result.Err(Result.Codes.DENIED, 'The hotbar is disabled.') end
    local wantedSlot = math.floor(tonumber(slot) or 0)
    if wantedSlot < 1 or wantedSlot > SlotCount() then
        return Result.Err(Result.Codes.INVALID_INPUT, 'That hotbar slot does not exist.')
    end

    local characterId, inventoryId = CharacterContext(src)
    if not characterId or not inventoryId then
        return Result.Err('no_character', 'No character is loaded for that player.')
    end
    if itemId == nil then
        MySQL.query.await('DELETE FROM `character_hotbar_bindings` WHERE `character_id`=? AND `slot`=?;',
            { characterId, wantedSlot })
        return HotbarAPI.GetBindings(src)
    end

    local item = InventoryControllers.GetInventoryItemById(tonumber(itemId))
    if not item or tostring(item.inventory_id) ~= tostring(inventoryId) then
        return Result.Err(Result.Codes.DENIED, 'That item is not in your inventory.')
    end
    local definition = ItemControllers.GetItemDefinitionByName(item.name)
    if not definition or not (definition.usable == true or tonumber(definition.usable) == 1) then
        return Result.Err(Result.Codes.UNSUPPORTED, 'Only usable items can be assigned to the hotbar.')
    end

    local instanceId = definition.instance_mode == 'unique' and tonumber(item.id) or nil
    MySQL.query.await([[
        INSERT INTO `character_hotbar_bindings` (`character_id`, `slot`, `item_name`, `instance_id`)
        VALUES (?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE `item_name`=VALUES(`item_name`),
            `instance_id`=VALUES(`instance_id`), `updated_at`=CURRENT_TIMESTAMP;
    ]], { characterId, wantedSlot, definition.name, instanceId })
    return HotbarAPI.GetBindings(src)
end

function HotbarAPI.UseBinding(src, slot)
    EnsureHotbarSchema()
    if not HotbarEnabled() then return Result.Err(Result.Codes.DENIED, 'The hotbar is disabled.') end
    local wantedSlot = math.floor(tonumber(slot) or 0)
    if wantedSlot < 1 or wantedSlot > SlotCount() then
        return Result.Err(Result.Codes.INVALID_INPUT, 'That hotbar slot does not exist.')
    end

    local characterId, inventoryId = CharacterContext(src)
    if not characterId or not inventoryId then
        return Result.Err('no_character', 'No character is loaded for that player.')
    end
    local binding = MySQL.single.await([[
        SELECT `slot`, `item_name`, `instance_id`
        FROM `character_hotbar_bindings`
        WHERE `character_id`=? AND `slot`=? LIMIT 1;
    ]], { characterId, wantedSlot })
    if not binding then return Result.Err(Result.Codes.NOT_FOUND, 'That hotbar slot is empty.') end

    local resolved = ResolveBinding(inventoryId, binding)
    if not resolved or not resolved.available then
        return Result.Err(Result.Codes.NOT_FOUND, 'The assigned item is not in your inventory.')
    end
    return ItemsAPI.UseItem(resolved.instanceId, src, { hotbar=true })
end

Feather.RPC.Register('Feather:Inventory:Hotbar:Get', function(_, res, src)
    local result = HotbarAPI.GetBindings(src)
    res(Result.IsOk(result) and { error=false, value=result.value }
        or { error=true, code=result.error.code, message=result.error.message })
end)

Feather.RPC.Register('Feather:Inventory:Hotbar:Set', function(params, res, src)
    params = type(params) == 'table' and params or {}
    local result = HotbarAPI.SetBinding(src, params.slot, params.itemId)
    res(Result.IsOk(result) and { error=false, value=result.value }
        or { error=true, code=result.error.code, message=result.error.message })
end)

Feather.RPC.Register('Feather:Inventory:Hotbar:Use', function(params, res, src)
    params = type(params) == 'table' and params or {}
    local result = HotbarAPI.UseBinding(src, params.slot)
    local bindings = HotbarAPI.GetBindings(src)
    res(Result.IsOk(result)
        and { error=false, value=Result.IsOk(bindings) and bindings.value or nil }
        or { error=true, code=result.error.code, message=result.error.message,
            details=result.error.details,
            value=Result.IsOk(bindings) and bindings.value or nil })
end)

-- Reconcile availability whenever committed inventory facts affect a
-- Character inventory. This also covers mutations initiated by other server
-- resources (grants, rewards, recovery), which a NUI-only refresh cannot see.
-- The client debounces bursts such as a five-unit stack into one bindings RPC.
local PendingHotbarInventoryIds = {}
local PendingHotbarActorSources = {}
local HotbarRefreshScheduled = false

local function FlushAffectedHotbars()
    HotbarRefreshScheduled = false
    local inventoryIds, actorSources = PendingHotbarInventoryIds, PendingHotbarActorSources
    PendingHotbarInventoryIds, PendingHotbarActorSources = {}, {}

    local characterIds = {}
    for inventoryId in pairs(inventoryIds) do
        local row = MySQL.single.await(
            'SELECT `character_id` FROM `inventory` WHERE `id`=? LIMIT 1;', { inventoryId })
        if row and row.character_id then
            characterIds[tostring(row.character_id):lower()] = true
        end
    end

    local notified = {}
    for actorSource in pairs(actorSources) do
        if GetPlayerName(actorSource) then
            notified[actorSource] = true
            TriggerClientEvent('Feather:Inventory:HotbarRefresh', actorSource)
        end
    end
    if next(characterIds) == nil then return end
    for _, rawSource in ipairs(GetPlayers()) do
        local src = tonumber(rawSource)
        if src and not notified[src] then
            local player = InventoryIdentity.GetCharacter(src)
            local character = player and player.char
            local characterId = character and InventoryIdentity.NormalizeCharacterId(character.id)
            if characterId and characterIds[characterId] then
                TriggerClientEvent('Feather:Inventory:HotbarRefresh', src)
            end
        end
    end
end

local function RefreshAffectedHotbars(fact)
    if type(fact) ~= 'table' or fact.outcome ~= 'committed' then return end
    for _, value in ipairs({ fact.inventoryId, fact.fromInventoryId, fact.toInventoryId }) do
        local numeric = tonumber(value)
        if numeric then PendingHotbarInventoryIds[numeric] = true end
    end
    local actorSource = tonumber(fact.actorSource)
    if actorSource then PendingHotbarActorSources[actorSource] = true end
    if not HotbarRefreshScheduled then
        HotbarRefreshScheduled = true
        SetTimeout(50, FlushAffectedHotbars)
    end
end

AddEventHandler('Feather:Inventory:ItemCreated', RefreshAffectedHotbars)
AddEventHandler('Feather:Inventory:ItemMoved', RefreshAffectedHotbars)
AddEventHandler('Feather:Inventory:ItemDestroyed', RefreshAffectedHotbars)
