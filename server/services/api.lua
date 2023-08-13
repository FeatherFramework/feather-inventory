function StartAPI()
  local InventoryServerApi = {}

  InventoryServerApi.RegisterForeignKey = function(tableName, foreignKeyType, primaryKeyName)
    if not tableName or not foreignKeyType or not primaryKeyName then
      error(
        'All parameters are required!')
      return
    end

    local foreignKey = string.lower(tableName) .. '_id'
    local constraint = 'FK_Inventory' .. firstToUpper(string.lower(tableName))
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

  InventoryServerApi.RegisterInventory = function(tableName, id)
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

  exports('initiate', function()
    return InventoryServerApi
  end)
end
