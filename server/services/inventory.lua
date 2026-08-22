InventoryAPI = {}
local RegisteredForeignKeys = {}
local OpenInventories = {}

---
-- Register Script with Inventory
--
-- Creates a foreign key in the inventory table to link to your script's table.
--
-- @param tableName Name of your Database Table
-- @param foreignKeyType Type of the foreign key (e.g. BIGINT UNSIGNED, VARCHAR(255), etc.)
-- @param primaryKeyName Name of the primary key in your table (e.g. id)
-- @return None
--
-- (INV-18) tableName/primaryKeyName end up concatenated directly into DDL
-- below. Both come from other resources' RegisterForeignKey calls rather
-- than client input, but a whitelist check costs nothing and turns a typo'd
-- or malicious identifier into a clean rejection instead of arbitrary SQL
-- landing in an ALTER TABLE statement. foreignKeyType is passed through as
-- typed (e.g. "BIGINT UNSIGNED") since it's a SQL type, not an identifier.
local function IsSafeIdentifier(name)
  return type(name) == 'string' and name:match('^[A-Za-z_][A-Za-z0-9_]*$') ~= nil
end

InventoryAPI.RegisterForeignKey = function(tableName, foreignKeyType, primaryKeyName)
  if not tableName or not foreignKeyType or not primaryKeyName then
    warn(
      'All parameters are required!')
    return
  end

  if not IsSafeIdentifier(tableName) or not IsSafeIdentifier(primaryKeyName) then
    warn('Invalid tableName or primaryKeyName. Must be a valid SQL identifier.')
    return
  end

  if RegisteredForeignKeys[tableName] then
    warn('This foreign key has already been registered by a different resource.')
    return
  end

  local foreignKey = string.lower(tableName) .. '_id'
  local constraint = 'FK_Inventory' .. FirstToUpper(string.lower(tableName))
  local column = MySQL.query.await("SHOW COLUMNS FROM `inventory` LIKE ?;", { foreignKey })
  if #(column) < 1 then
    local query = 'ALTER TABLE `inventory` ADD COLUMN IF NOT EXISTS (`' ..
        foreignKey ..
        '` ' ..
        foreignKeyType ..
        ' NULL), ADD CONSTRAINT `' ..
        constraint ..
        '` FOREIGN KEY IF NOT EXISTS (`' ..
        foreignKey ..
        '`) REFERENCES `' .. tableName .. '` (`' .. primaryKeyName .. '`) ON DELETE CASCADE ON UPDATE CASCADE;'

    print(query)
    MySQL.query.await(query)
  end

  -- (Tier 1 audit sweep) Was `table.insert(RegisteredForeignKeys, 'tableName')`
  -- -- array-appending the literal string "tableName" instead of setting
  -- the dict key the guard above (`RegisteredForeignKeys[tableName]`)
  -- actually reads, so the "already registered by a different resource"
  -- check never triggered.
  RegisteredForeignKeys[tableName] = true
end

---
-- Register Inventory
--
-- Register a custom inventory for an  entity.
--
-- @param tableName Name of your Database Table
-- @param id Foreign Key ID of the entity
-- @param displayName the name of the inventory (default: storage)
-- @param ignoreItemLimits Ignore the max quantity of items that can be added to the inventory
-- @param maxWeight Override the maximum weight of the inventory (nill to use default)
-- @param restrictedItems Table of items that are restricted from being added to the inventory. e.g. { "apple", "matches" }
-- @param ownerCharacterId (INV-11) Character id that owns this inventory's access list -- the owner
--   may always open it and is the only non-admin who can grant/revoke access to others
--   (see InventoryAPI.GrantInventoryAccess). Leave nil for an inventory with no ACL owner.
-- @param isPublic (INV-11/INV-12) If true, any src holding a valid temporary access grant
--   (InventoryAPI.GrantTemporaryAccess) may open this inventory, in addition to the owner/ACL.
--   Ignored (treated as false) on update if not explicitly passed, same as the other flags below.
-- @return Inventory UUID for accessing the inventory later (can be saved in your database table)
--
InventoryAPI.RegisterInventory = function(tableName, id, displayName, ignoreItemLimits, maxWeight, restrictedItems, ownerCharacterId, isPublic)
  if not tableName or not id then
    warn(
      'All parameters are required!')
    return
  end

  -- (INV-18) Same rationale as RegisterForeignKey -- tableName is
  -- concatenated into DDL/DML below via `foreignKey`.
  if not IsSafeIdentifier(tableName) then
    warn('Invalid tableName. Must be a valid SQL identifier.')
    return
  end

  local foreignKey = string.lower(tableName) .. '_id'
  local column = MySQL.query.await("SHOW COLUMNS FROM `inventory` LIKE ?;", { foreignKey })
  if #(column) < 1 then
    warn(
      'A foreign key for this script has not been registered. Please refer to the documentation to register a foreign key.')
    return
  end

  -- Check if inventory already exists
  local query = 'SELECT `id`, `uuid`, `max_weight`, `ignore_item_limit` FROM `inventory` WHERE `' .. foreignKey .. '`=?'
  local inventory = MySQL.query.await(query, { id })

  -- Inventory exists. Check Max Weight and Ignore Item Limits. Return Inventory UUID
  if inventory ~= nil and inventory[1] then
    -- Max Weight and ignore items Update Check
    if (tonumber(inventory[1].max_weight) and tonumber(inventory[1].max_weight) ~= maxWeight) or Boolean[inventory[1].ignore_item_limit] ~= ignoreItemLimits then
      query = 'UPDATE `inventory` SET `max_weight`=?, `ignore_item_limit`=? WHERE `' .. foreignKey .. '`=?'
      MySQL.query.await(query, { tonumber(inventory[1].max_weight), ignoreItemLimits, id })
    end

    if restrictedItems then
      InventoryControllers.UpdateRestrictedItems(inventory[1].id, restrictedItems)
    end

    if ownerCharacterId ~= nil then
      MySQL.query.await('UPDATE `inventory` SET `owner_character_id`=? WHERE `id`=?;', { ownerCharacterId, inventory[1].id })
    end
    if isPublic ~= nil then
      MySQL.query.await('UPDATE `inventory` SET `is_public`=? WHERE `id`=?;', { isPublic and 1 or 0, inventory[1].id })
    end

    return inventory[1].uuid, inventory[1].id
  end

  -- Create new inventory
  query = 'INSERT INTO `inventory` (' .. foreignKey .. ', location, name, max_weight, ignore_item_limit, owner_character_id, is_public) VALUES (?, ?, ?, ?, ?, ?, ?) RETURNING *;'
  inventory = MySQL.query.await(query, { id, tableName, displayName or 'storage', maxWeight or nil, ignoreItemLimits or false, ownerCharacterId or nil, isPublic and 1 or 0 })

  if not inventory or not inventory[1] then
    return nil
  end

  return inventory[1].uuid, inventory[1].id
end

---
-- Can Inventory Hold items
--
--
-- @param items Table of items and their quantity. e.g. { {item="apple", quantity=5}, {item="matches", quantity=10} }
-- @param inventoryId Player Source or Inventory UUID
-- @return True if inventory can hold items, false if not
--
InventoryAPI.InventoryCanHold = function(items, inventoryId)
  if type(items) ~= 'table' then
    warn(
      'Invalid items format. Must be a table of items and their quantity. { {item="apple", quantity=5}, {item="matches", quantity=10} }')
    return nil
  end

  for _, v in pairs(items) do
    if not v.item or tonumber(v.quantity) == nil or tonumber(v.quantity) < 0 then
      warn(
        'Invalid items format. Must be a table of items and their quantity. { {item="apple", quantity=5}, {item="matches", quantity=10} }')
      return nil
    end
  end

  local inventory, maxWeight, ignore_item_limit = nil, nil, nil
  if tonumber(inventoryId) then
    local player = Feather.Character.GetCharacter({ src = inventoryId })
    local character = player and player.char
    if character then
      inventory, maxWeight, ignore_item_limit = InventoryControllers.GetInventoryByCharacter(character.id)
    end
  else
    inventory, maxWeight, ignore_item_limit = InventoryControllers.GetInventoryById(inventoryId)
  end
  if not inventory then
    warn('Invalid inventory ID.')
    return nil
  end

  local weight = 0
  for _, v in pairs(items) do
    -- (INV-14) Was `GetItemByName(v)` -- passing the whole {item=, quantity=}
    -- table where the function (and the underlying query param) expects the
    -- item's name string. Every call resolved to `false`, so this always
    -- fell through to the "Invalid itemName" error below and InventoryCanHold
    -- could never return a real result.
    local itemId, maxQuantity, itemWeight = ItemControllers.GetItemByName(v.item)
    -- Check if item is restricted
    if InventoryControllers.IsItemRestricted(inventory, itemId) then
      return { status = false, message = 'Item is restricted.' }
    end

    -- Check if inv can carry more
    -- (INV-10) `Boolean` is a lookup table (see helpers/main.lua), not a
    -- function -- calling it as `Boolean(x)` errored every time this ran.
    if not Boolean[ignore_item_limit] then
      if (InventoryControllers.InventoryItemCount(inventory, itemId) + v.quantity) > maxQuantity then
        return { status = false, message = 'Max Quantity Exceeded.' }
      end
    end

    weight = weight + itemWeight
  end

  -- Check if player has enough weight left
  if (weight + InventoryControllers.GetInventoryTotalWeight(inventory)) > (maxWeight or Config.maxWeight) then
    return { status = false, message = 'Max Weight Exceeded.' }
  end
  return { status = true, message = '' }
end

---
-- Can Inventory Hold Items, by raw inventory.id
--
-- (Drop/give bugfix) InventoryCanHold's `inventoryId` only ever means
-- "player source" (numeric) or "inventory UUID" (string) per its own
-- convention -- it has no way to mean "this specific numeric inventory.id",
-- which is exactly what MoveInventoryItems' targetInventory/sourceInventory
-- always are (raw ids from GetInventoryByCharacter/RegisterInventory, not a
-- player src). Calling InventoryCanHold with one of those numeric ids got
-- silently misread as a player source, resolved to no character, and
-- InventoryCanHold returned nil -- which MoveInventoryItems then treated as
-- "target can't hold this," rejecting every single drop/give/transfer
-- without ever actually checking capacity. This variant skips the
-- src-vs-uuid guessing entirely and always resolves by raw id.
--
-- @param items Table of items and their quantity, same shape as InventoryCanHold
-- @param inventoryId Raw inventory.id
-- @return True if inventory can hold items, false if not
--
InventoryAPI.InventoryCanHoldById = function(items, inventoryId)
  if type(items) ~= 'table' then
    warn(
      'Invalid items format. Must be a table of items and their quantity. { {item="apple", quantity=5}, {item="matches", quantity=10} }')
    return nil
  end

  for _, v in pairs(items) do
    if not v.item or tonumber(v.quantity) == nil or tonumber(v.quantity) < 0 then
      warn(
        'Invalid items format. Must be a table of items and their quantity. { {item="apple", quantity=5}, {item="matches", quantity=10} }')
      return nil
    end
  end

  local inventory, maxWeight, ignore_item_limit = InventoryControllers.GetInventoryById(inventoryId, 'id')
  if not inventory then
    warn('Invalid inventory ID.')
    return nil
  end

  local weight = 0
  for _, v in pairs(items) do
    local itemId, maxQuantity, itemWeight = ItemControllers.GetItemByName(v.item)
    if InventoryControllers.IsItemRestricted(inventory, itemId) then
      return { status = false, message = 'Item is restricted.' }
    end

    if not Boolean[ignore_item_limit] then
      if (InventoryControllers.InventoryItemCount(inventory, itemId) + v.quantity) > maxQuantity then
        return { status = false, message = 'Max Quantity Exceeded.' }
      end
    end

    weight = weight + itemWeight
  end

  if (weight + InventoryControllers.GetInventoryTotalWeight(inventory)) > (maxWeight or Config.maxWeight) then
    return { status = false, message = 'Max Weight Exceeded.' }
  end
  return { status = true, message = '' }
end

---
-- Open Inventory
--
-- Returns items in the specified inventories
--
-- @param src Player Source
-- @param otherInventoryId Player Source or Inventory UUID of a different inventory
-- @return Table of items in the inventory and other inventory if specified
--
InventoryAPI.InternalOpenInventory = function(src, otherInventoryId)
  local inventory, inventoryIgnoreLimits, otherInventory, otherInventoryIgnoreLimits, otherName = nil, nil, nil, nil, nil
  -- (Ground pickup bugfix) Was `local character` scoped only to this
  -- if-block -- every read of it below (the "Owned/shared inventory" branch
  -- further down, e.g. picking a dropped item back up) hit an unset global
  -- instead, crashing this whole RPC with "attempt to index a nil value
  -- (global 'character')" and taking GetInventoryItems down with it.
  local character

  -- Check to make sure inventoryId is a player source and not a string
  if tonumber(src) then
    local player = Feather.Character.GetCharacter({ src = src })
    character = player.char

    -- Check if the character is available
    if character == nil then
      return {
        error = 'Inventory not available'
      }
    end

    inventory, _, _, _ = InventoryControllers.GetInventoryByCharacter(character.id)
  else
    warn('Invalid Character Source!')
    return {
      error = 'No Character Available'
    }
  end

  local inventoryItems, otherInventoryItems = InventoryControllers.GetInventoryItems(inventory), nil

  -- (INV-11/INV-23) This used to resolve otherInventoryId and hand it back
  -- unconditionally -- the mere act of calling this RPC populated
  -- OpenInventories, which IsInventoryAccessibleBySrc then treated as proof
  -- of authorization. That's circular: the caller granted themselves
  -- access by asking. Authorization now comes from state the caller cannot
  -- set themselves -- see server/services/inventory_access.lua.
  if otherInventoryId ~= nil then
    local resolvedId, resolvedIgnoreLimits, resolvedName = nil, nil, nil

    if tonumber(otherInventoryId) then
      -- Player-to-player: robbery / forced search. Requires the target to
      -- actually be near the caller AND to be in a status that justifies
      -- it -- neither alone is enough (proximity alone was INV-12's
      -- mistake; status alone would let anyone loot anyone incapacitated
      -- from across the map).
      local targetPlayer = Feather.Character.GetCharacter({ src = otherInventoryId })
      local targetCharacter = targetPlayer and targetPlayer.char

      if not targetCharacter then
        -- no target connected/loaded; leave otherInventory nil
      elseif not IsWithinRobberyDistance(src, otherInventoryId) then
        Feather.Notify.RightNotify(src, 'You are too far away.', 3000)
      elseif not CanBeLootedDueToStatus(targetCharacter.id) then
        Feather.Notify.RightNotify(src, 'This player cannot be searched right now.', 3000)
      else
        resolvedId, _, resolvedIgnoreLimits, resolvedName = InventoryControllers.GetInventoryByCharacter(targetCharacter.id)
      end
    else
      -- Owned/shared inventory (storage, saddlebags, job lockers, ground
      -- pickups, ...) -- gated by ownership, a persistent grant, or (for
      -- public inventories) a short-lived grant issued by whichever
      -- resource disclosed this UUID after checking its own proximity/
      -- consent condition.
      local uuidId, _, uuidIgnoreLimits, uuidName = InventoryControllers.GetInventoryById(otherInventoryId)
      DebugPrint('DEBUG-GROUND', 'InternalOpenInventory: src=%s requested uuid=%s -- resolved inventory.id=%s',
        tostring(src), tostring(otherInventoryId), tostring(uuidId))
      if uuidId and not IsAuthorizedForOwnedInventory(src, character.id, uuidId) then
        DebugPrint('DEBUG-GROUND', 'InternalOpenInventory: src=%s DENIED for inventory.id=%s', tostring(src), tostring(uuidId))
        Feather.Notify.RightNotify(src, 'You do not have access to this inventory.', 3000)
      elseif uuidId then
        resolvedId, resolvedIgnoreLimits, resolvedName = uuidId, uuidIgnoreLimits, uuidName
      end
    end

    if resolvedId then
      if OpenInventories[tostring(resolvedId)] ~= nil then
        Feather.Notify.RightNotify(src, 'This inventory is already opened. Try again later.', 3000)
      else
        otherInventory, otherInventoryIgnoreLimits, otherName = resolvedId, resolvedIgnoreLimits, resolvedName
        otherInventoryItems = InventoryControllers.GetInventoryItems(otherInventory)
        OpenInventories[tostring(otherInventory)] = {
          src = tostring(src),
          id = otherInventory,
          uuid = otherInventoryId
        }
      end
    end
  end

  return {
    inventory = inventory,
    inventoryItems = inventoryItems,
    inventoryIgnoreLimits = inventoryIgnoreLimits,
    otherName = otherName,
    otherInventory = otherInventory,
    otherInventoryItems = otherInventoryItems,
    otherInventoryIgnoreLimits = otherInventoryIgnoreLimits
  }
end

---
-- Is Inventory Accessible By Src
--
-- (INV-01) Authorization check for the RPCs that let a client name which
-- inventories to move items between. A src may access its own character's
-- inventory, or any inventory it currently has open via
-- InternalOpenInventory (ground pickups, storage, etc.) -- nothing else.
--
-- @param src Player Source making the request
-- @param inventoryId Raw inventory.id being requested
-- @return True if src may read/write this inventory right now
--
InventoryAPI.IsInventoryAccessibleBySrc = function(src, inventoryId)
  if not src or not inventoryId then
    return false
  end

  local player = Feather.Character.GetCharacter({ src = src })
  local character = player and player.char
  if character then
    local ownInventoryId = InventoryControllers.GetInventoryByCharacter(character.id)
    if ownInventoryId and tostring(ownInventoryId) == tostring(inventoryId) then
      return true
    end
  end

  local opened = OpenInventories[tostring(inventoryId)]
  if not opened or opened.src ~= tostring(src) then
    return false
  end

  -- (INV-11/INV-23) The lock only proves src was authorized to open this
  -- inventory at open time. For another player's own character inventory
  -- specifically, re-verify proximity and status live rather than trusting
  -- a lock that could be minutes old -- a robbery target who wakes up and
  -- runs, or who the caller simply walked away from, should stop being
  -- lootable immediately. Public/UUID inventories (storage, ground, ...)
  -- skip this: the object isn't a person and doesn't run away.
  if tonumber(opened.uuid) then
    local targetPlayer = Feather.Character.GetCharacter({ src = opened.uuid })
    local targetCharacter = targetPlayer and targetPlayer.char
    if not targetCharacter
      or not IsWithinRobberyDistance(src, opened.uuid)
      or not CanBeLootedDueToStatus(targetCharacter.id)
    then
      return false
    end
  end

  return true
end

InventoryAPI.OpenInventory = function (src, InventoryId, target)
  TriggerClientEvent('Feather:Inventory:OpenInventory', src, InventoryId, target)
end

InventoryAPI.CloseInventory = function(src)
  TriggerClientEvent('Feather:Inventory:CloseInventory', src)
end

InventoryAPI.GetInventory = function(inventoryID)
  return InventoryControllers.GetInventoryById(inventoryID)
end

InventoryAPI.GetCustomInventory = function (key, inventoryID)
  return InventoryControllers.GetCustomInventoryById(key, inventoryID)
end

InventoryAPI.GetInventoryItems = function(inventoryID)
  return InventoryControllers.GetInventoryItems(inventoryID)
end

---
-- Close Inventory
--
-- Unlocks any inventory locked by the user provided so it can be accessed by another player
--
-- @param src Player Source
-- @return None
--
InventoryAPI.InternalCloseInventory = function(src)
  for k, v in pairs(OpenInventories) do
    if v.src == tostring(src) then
      -- (INV-20) GetInventoryTotalItemCounts(...)[1] crashed InternalCloseInventory
      -- (and by extension, the playerDropped handler for every other still-
      -- connected player) whenever the query returned no rows -- e.g. the
      -- inventory row itself was deleted between opening and disconnect.
      local counts = InventoryControllers.GetInventoryTotalItemCounts(v.id)
      if counts and counts[1] and tonumber(counts[1].count) and tonumber(counts[1].count) <= 0 then
        TriggerEvent('Feather:Inventory:Empty', {
          id = v.id,
          uuid = v.uuid
        })
      end

      OpenInventories[k] = nil
      -- break
    end
  end
end

AddEventHandler('playerDropped', function()
  local src = source
  InventoryAPI.InternalCloseInventory(src)
end)

