InventoryAPI = {}

InventoryAPI.RegisterForeignKey = function(tableName, foreignKeyType, primaryKeyName)
  if not tableName or not foreignKeyType or not primaryKeyName then
    error(
      'All parameters are required!')
    return
  end

  local foreignKey = string.lower(tableName) .. '_id'
  local constraint = 'FK_Inventory' .. FirstToUpper(string.lower(tableName))
  local column = MySQL.query.await("SHOW COLUMNS FROM `inventory` LIKE ?;", { foreignKey })
  Feather.Print(column)
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
end

InventoryAPI.RegisterInventory = function(tableName, id)
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
  local query = 'SELECT uuid FROM `inventory` WHERE `' .. foreignKey .. '`=?'
  local inventory = MySQL.query.await(query, { id })
  if inventory ~= nil and inventory[1] then
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

ItemsAPI.SpaceAvailable = function(items, inventoryId)
  if type(items) ~= 'table' then
    error(
      'Invalid items format. Must be a table of items and their quantity. { {item="apple", quantity=5}, {item="matches", quantity=10} }')
    return false
  end

  for _, v in pairs(items) do
    if not v.item or not tonumber(v.quantity) or not tonumber(v.quantity) > 0 then
      error(
        'Invalid items format. Must be a table of items and their quantity. { {item="apple", quantity=5}, {item="matches", quantity=10} }')
      return false
    end
  end

  local inventory = GetInventory(inventoryId)
  if not inventory then
    error('Invalid inventory ID.')
    return false
  end

  local weight = 0
  for _, v in pairs(items) do

  end
end

-- TODO
-- Add MAX WEIGHT to custom inventory registration
-- Update MAX WEIGHT if it changes on registration
-- Continue testing indexes
-- Add call to get current weight of inventory
