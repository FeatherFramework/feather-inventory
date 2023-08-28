InventoryAPI = {}
local RegisteredForeignKeys = {}
local OpenInventories = {}

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
        '`) REFERENCES `' .. tableName .. '` (`' .. primaryKeyName .. '`) ON DELETE CASCADE ON UPDATE CASCADE'
    MySQL.query.await(query)
  end

  table.insert(RegisteredForeignKeys, 'tableName')
end

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

  local inventory, maxWeight, ignore_item_limit = GetInventory(inventoryId)
  if not inventory then
    error('Invalid inventory ID.')
    return nil
  end

  local weight = 0
  for _, v in pairs(items) do
    local itemId, maxQuantity, itemWeight = GetItemByName(v)
    -- Check if item is restricted
    if IsItemRestrcited(inventory, itemId) then
      return { status = false, reason = 'Item is restricted.' }
    end

    -- Check if inv can carry more
    if not Boolean(ignore_item_limit) then
      if (InventoryItemCount(inventory, itemId) + v.quantity) > maxQuantity then
        return { status = false, reason = 'Max Quantity Exceeded.' }
      end
    end

    weight = weight + itemWeight
  end

  -- Check if player has enough weight left
  if (weight + GetInventoryTotalWeight(inventory)) > (maxWeight or Config.maxWeight) then
    return { status = false, reason = 'Max Weight Exceeded.' }
  end
  return { status = true, reason = '' }
end

InventoryAPI.OpenInventory = function(inventoryId, userId)
  -- Take source of user
  -- Get Character Data
  -- Get Inventory by Character ID
  -- Open Player Inventory with Custom Inventory
  OpenInventories[inventoryId] = userId
end

InventoryAPI.CloseInventory = function(inventoryId)
  OpenInventories[inventoryId] = nil
end

-- TODO
-- Continue testing indexes
