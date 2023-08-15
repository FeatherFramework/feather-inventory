ItemsAPI = {}

ItemsAPI.AddItem = function(itemName, quantity, metadata, inventoryId)
  if quantity < 1 then
    error('Invalid quantity. Must be creater than 0.')
    return false
  end

  local itemId = GetItemByName(itemName)
  if not itemId then
    error('Invalid itemName. Please make sure it is in the items table in your database.')
    return false
  end

  local inventory = GetInventory(inventoryId)
  if not inventory then
    error('Invalid inventory ID.')
    return false
  end

  if metadata ~= nil and type(metadata) ~= 'table' then
    error(
      "Invalid format for meta data. Meta data must be a table of key value pairs. Example: { quality = 'poor', durability = 50, maxDurability = 100 }")
    return false
  end

  for count = 1, quantity do
    local item = MySQL.query.await(
      'INSERT INTO `inventory_items` (`inventory_id`, `item_id`) VALUES (?, ?) RETURNING *;', { inventory, itemId })

    if metadata ~= nil then
      for k, v in ipairs(metadata) do
        MySQL.query.await('INSERT INTO `item_metadata` (`inventory_items_id`, `key`, `value`) VALUES (?, ?, ?);',
          { item[1].id, k, v })
      end
    end

    count = count + 1
  end
  return true
end

-- Removes n number of items by name. (No specific order)
ItemsAPI.RemoveItemByName = function(itemName, quantity, inventoryId)
  if quantity < 1 then
    error('Invalid quantity. Must be creater than 0.')
    return false
  end

  local itemId = GetItemByName(itemName)
  if not itemId then
    error('Invalid itemName. Please make sure it is in the items table in your database.')
    return false
  end

  local inventory = GetInventory(inventoryId)
  if not inventory then
    error('Invalid inventory ID.')
    return false
  end

  local itemCount = InventoryItemCount(inventory, itemId)
  if itemCount < quantity then
    return false
  end

  local query = 'DELETE FROM `inventory_items` WHERE `inventory_id`=? AND `item_id`=? LIMIT ' .. quantity .. ';'
  MySQL.query.await(query, { inventory, itemId })
  return true
end

-- Removes a specific item from the players inventory. (true if removed, false if not)
ItemsAPI.RemoveItemById = function(id)
  local item = GetInventoryItemById(id)
  if not item then
    return false
  end

  MySQL.query.await('DELETE FROM `inventory_items` WHERE `id`=? LIMIT;', { item.id })
  return true
end

ItemsAPI.GetItem = function(id)
  local item = GetInventoryItemById(id)
  if not item then
    return nil
  end

  return item
end

ItemsAPI.GetItemCount = function(itemName, inventoryId)
  local itemId = GetItemByName(itemName)
  if not itemId then
    error('Invalid itemName. Please make sure it is in the items table in your database.')
    return -1
  end

  local inventory = GetInventory(inventoryId)
  if not inventory then
    error('Invalid inventory ID.')
    return -1
  end

  local itemCount = InventoryItemCount(inventory, itemId)

  return itemCount
end

ItemsAPI.ItemExists = function(itemName)
  if GetItemByName(itemName) then
    return false
  end
  return true
end
