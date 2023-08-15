function FirstToUpper(str)
  return (str:gsub("^%l", string.upper))
end

function GetItemByName(itemName)
  local result = MySQL.query.await('SELECT id FROM `items` WHERE `name` = ? LIMIT 1;', { itemName })
  if not result[1] then
    return false
  end
  return result[1].id
end

function GetInventory(inventoryId)
  local result = MySQL.query.await('SELECT id FROM `inventory` WHERE `uuid` = ? LIMIT 1;', { inventoryId })
  if not result[1] then
    return false
  end
  return result[1].id
end

function InventoryItemCount(inventory, itemId)
  local result = MySQL.query.await('SELECT COUNT(id) FROM `inventory_items` WHERE `inventory_id`=? AND `item_id`=?',
    { inventory, itemId })

  return result[1]["COUNT(id)"]
end

function GetInventoryItemById(id)
  local result = MySQL.query.await('SELECT * FROM `inventory_items` WHERE `id`=? LIMIT 1;', { id })
  if not result[1] or not result[1] then
    return false
  end

  return result[1]
end

function GetInventoryTotalWeight(inventory)
  local result = MySQL.query.await(
  'SELECT SUM(`items`.`weight`) FROM `items` INNER JOIN `inventory_items` ON `items`.`id`=`inventory_items`.`item_id` WHERE `inventory_items`.`inventory_id`=?',
    { inventory })
  if not result[1]['`items`.`weight`'] then
    return 0
  end

  return result[1]['`items`.`weight`']
end
