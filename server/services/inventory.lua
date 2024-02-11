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
InventoryAPI.RegisterForeignKey = function(tableName, foreignKeyType, primaryKeyName)
  if not tableName or not foreignKeyType or not primaryKeyName then
    error(
      'All parameters are required!')
    return
  end

  if RegisteredForeignKeys[tableName] then
    error('This foreign key has already been registered by a different resource.')
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

  table.insert(RegisteredForeignKeys, 'tableName')
end

---
-- Register Inventory
--
-- Register a custom inventory for an  entity.
--
-- @param tableName Name of your Database Table
-- @param id Foreign Key ID of the entity
-- @param maxWeight Override the maximum weight of the inventory (nill to use default)
-- @param restrictedItems Table of items that are restricted from being added to the inventory. e.g. { "apple", "matches" }
-- @param ignoreItemLimits Ignore the max quantity of items that can be added to the inventory
-- @return Inventory UUID for accessing the inventory later (can be saved in your database table)
--
InventoryAPI.RegisterInventory = function(tableName, id, maxWeight, restrictedItems, ignoreItemLimits)
  if not tableName or not id then
    error(
      'All parameters are required!')
    return
  end

  local foreignKey = string.lower(tableName) .. '_id'
  local column = MySQL.query.await("SHOW COLUMNS FROM `inventory` LIKE ?;", { foreignKey })
  if #(column) < 1 then
    error(
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
      UpdateRestrictedItems(inventory[1].id, restrictedItems)
    end

    return inventory[1].uuid
  end

  -- Create new inventory
  query = 'INSERT INTO `inventory` (' .. foreignKey .. ') VALUES (?) RETURNING *;'
  inventory = MySQL.query.await(query, { id })

  if not inventory or not inventory[1] then
    return nil
  end

  return inventory[1].uuid
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
    error(
      'Invalid items format. Must be a table of items and their quantity. { {item="apple", quantity=5}, {item="matches", quantity=10} }')
    return nil
  end

  for _, v in pairs(items) do
    if not v.item or tonumber(v.quantity) == nil or tonumber(v.quantity) < 0 then
      error(
        'Invalid items format. Must be a table of items and their quantity. { {item="apple", quantity=5}, {item="matches", quantity=10} }')
      return nil
    end
  end

  local inventory, maxWeight, ignore_item_limit = nil, nil, nil
  if tonumber(inventoryId) then
    local character = Feather.Character.GetCharacterBySrc(inventoryId)
    inventory, maxWeight, ignore_item_limit = GetInventoryByCharacter(character.id)
  else
    inventory, maxWeight, ignore_item_limit = GetInventoryById(inventoryId)
  end
  if not inventory then
    error('Invalid inventory ID.')
    return nil
  end

  local weight = 0
  for _, v in pairs(items) do
    local itemId, maxQuantity, itemWeight = GetItemByName(v)
    -- Check if item is restricted
    if IsItemRestrcited(inventory, itemId) then
      return { status = false, message = 'Item is restricted.' }
    end

    -- Check if inv can carry more
    if not Boolean(ignore_item_limit) then
      if (InventoryItemCount(inventory, itemId) + v.quantity) > maxQuantity then
        return { status = false, message = 'Max Quantity Exceeded.' }
      end
    end

    weight = weight + itemWeight
  end

  -- Check if player has enough weight left
  if (weight + GetInventoryTotalWeight(inventory)) > (maxWeight or Config.maxWeight) then
    return { status = false, message = 'Max Weight Exceeded.' }
  end
  return { status = true, message = '' }
end

InventoryAPI.OpenInventory = function(src, otherInventoryId)


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
  local inventory, inventoryIgnoreLimits, otherInventory, otherInventoryIgnoreLimits = nil, nil, nil, nil

  -- Check to make sure inventoryId is a player source and not a string
  if tonumber(src) then
    local character = Feather.Character.GetCharacterBySrc(src)
    inventory, _, _ = GetInventoryByCharacter(character.id)
  else
    error('Invalid Character Source!')
  end

  local inventoryItems, otherInventoryItems = GetInventoryItems(inventory), nil
  if otherInventoryId ~= nil then
    if tonumber(otherInventoryId) then
      local character = Feather.Character.GetCharacterBySrc(otherInventoryId)
      otherInventory, _, inventoryIgnoreLimits = GetInventoryByCharacter(character.id)
    else
      otherInventory, _, otherInventoryIgnoreLimits = GetInventoryById(otherInventoryId)
    end
    otherInventoryItems = GetInventoryItems(otherInventory)
    OpenInventories[tostring(otherInventory)] = tostring(src)
  end

  OpenInventories[tostring(inventory)] = tostring(src)
  return {
    inventory = inventory,
    inventoryItems = inventoryItems,
    inventoryIgnoreLimits = inventoryIgnoreLimits,
    otherInventory = otherInventory,
    otherInventoryItems = otherInventoryItems,
    otherInventoryIgnoreLimits = otherInventoryIgnoreLimits
  }
end

InventoryAPI.CloseInventory = function(src)
  TriggerClientEvent('Feather:Inventory:CloseInventory', src)
end

---
-- Close Inventory
--
-- Unlocks any inventory locked by the user provided so it can be accessed by another player
--
-- @param src Player Source
-- @return None
--
InventoryAPI.InternalCloseInventory = function(src, inventory)
  print("closing inventories")
  for k, v in pairs(OpenInventories) do
    if v == src then
      OpenInventories[k] = nil
    end
  end
end
