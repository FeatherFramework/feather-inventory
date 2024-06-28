InventoryControllers = {}

function InventoryControllers.GetInventoryById(inventoryId)
  local result = MySQL.query.await(
    'SELECT `id`, `uuid`, `max_weight`, `ignore_item_limit`, `name` FROM `inventory` WHERE `uuid` = ? LIMIT 1;', { inventoryId })[1]
  if not result then
    return false, false, false, nil
  end
  return result.id, result.max_weight, result.ignore_item_limit, result.name
end

function InventoryControllers.GetInventoryLocationById(id)
  local result = MySQL.query.await(
    'SELECT `location` FROM `inventory` WHERE `id` = ? LIMIT 1;', { id })[1]
  if not result then
    return nil
  end
  return result.location
end

function InventoryControllers.GetCustomInventoryById(key, id)
  local field = key..'_id'
  local result = MySQL.query.await('SELECT `id`, `uuid`, `max_weight`, `ignore_item_limit` FROM `inventory` WHERE `'..field..'` = ? LIMIT 1;', { id })[1]

  if result == nil then
    return false, false, false
  end
  
  return result.id, result.uuid, result.max_weight, result.ignore_item_limit
end

function InventoryControllers.GetInventoryByCharacter(character)
  local result = MySQL.query.await(
        'SELECT `id`, `max_weight`, `ignore_item_limit`, `name` FROM `inventory` WHERE `character_id` = ? LIMIT 1;',
        { character })
      [1]
  if not result then
    return false, false, false, nil
  end
  return result.id, result.max_weight, result.ignore_item_limit, result.name
end

function InventoryControllers.InventoryItemCount(inventory, itemId)
  local result = MySQL.query.await('SELECT COUNT(id) FROM `inventory_items` WHERE `inventory_id`=? AND `item_id`=?',
    { inventory, itemId })

  return result[1]["COUNT(id)"]
end

function InventoryControllers.GetInventoryItemById(id)
  local result = MySQL.query.await('SELECT `inventory_items`.`id`, `inventory_items`.`updated_at`, `items`.`display_name`, `items`.`name`, `items`.`description`, `items`.`usable`, `items`.`weight`, `items`.`category_id`, `items`.`max_quantity`, `items`.`max_stack_size`, JSON_OBJECTAGG(`item_metadata`.`key`, `item_metadata`.`value`) AS `item_metadata` FROM `inventory_items` INNER JOIN `items` ON `inventory_items`.`item_id` = `items`.`id` LEFT JOIN `item_metadata` ON `item_metadata`.`inventory_items_id` = `inventory_items`.`id` WHERE `inventory_items`.`id`=? GROUP BY `inventory_items`.`id`, `items`.`display_name`, `items`.`name`, `items`.`description`, `items`.`usable`, `items`.`weight`, `items`.`category_id`, `items`.`max_quantity`, `items`.`max_stack_size` LIMIT 1;', { id })[1]

  if result == nil then
    return false
  end

  if result["item_metadata"] and result["item_metadata"] ~= nil then
    result["item_metadata"] = json.decode(result["item_metadata"])
  end

  return result
end

function InventoryControllers.GetInventoryTotalWeight(inventory)
  local result = MySQL.query.await(
    'SELECT SUM(`items`.`weight`) FROM `items` INNER JOIN `inventory_items` ON `items`.`id`=`inventory_items`.`item_id` WHERE `inventory_items`.`inventory_id`=?',
    { inventory })
  if not result[1]['`items`.`weight`'] then
    return 0
  end

  return result[1]['`items`.`weight`']
end

function InventoryControllers.GetInventoryItems(inventory)
  local items = MySQL.query.await( 'SELECT `inventory_items`.`id`, `inventory_items`.`updated_at`, `items`.`display_name`, `items`.`name`, `items`.`description`, `items`.`usable`, `items`.`weight`, `items`.`category_id`, `items`.`max_quantity`, `items`.`max_stack_size`, JSON_OBJECTAGG(`item_metadata`.`key`, `item_metadata`.`value`) AS `item_metadata` FROM `inventory_items` INNER JOIN `items` ON `inventory_items`.`item_id` = `items`.`id` LEFT JOIN `item_metadata` ON `item_metadata`.`inventory_items_id` = `inventory_items`.`id` WHERE `inventory_items`.`inventory_id` = ? GROUP BY `inventory_items`.`id`, `items`.`display_name`, `items`.`name`, `items`.`description`, `items`.`usable`, `items`.`weight`, `items`.`category_id`, `items`.`max_quantity`, `items`.`max_stack_size`;', { inventory })
  for key, value in pairs(items) do
    if value["item_metadata"] and value["item_metadata"] ~= nil then
      items[key]["item_metadata"] = json.decode(value["item_metadata"])
    end
  end

  return items
end

function InventoryControllers.InventoryItemCounts(inventory)
  return MySQL.query.await(
    'SELECT `items`.`name`, COUNT(`items`.`name`) FROM `inventory_items` INNER JOIN `items` ON `inventory_items`.`item_id`=`items`.`id` WHERE `inventory_items`.`inventory_id`=?;',
    { inventory })
end

function InventoryControllers.GetInventoryTotalItemCounts(inventory)
  return MySQL.query.await(
    'SELECT COUNT(`id`) FROM `inventory_items` WHERE `inventory_id`=?;',
    { inventory })
end


function InventoryControllers.CreateInventoryItem(inventory, itemId)
  return MySQL.query.await('INSERT INTO `inventory_items` (`inventory_id`, `item_id`) VALUES (?, ?) RETURNING *;',
    { inventory, itemId })
end

function InventoryControllers.GetMetadata(itemId)
  return MySQL.query.await('SELECT `key`, `value` FROM `item_metadata` WHERE `inventory_items_id`=?', itemId)
end

function InventoryControllers.SetMetadata(item, key, value)
  MySQL.query.await(
    'INSERT INTO `item_metadata` (`inventory_items_id`, `key`, `value`) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE `value`=?;',
    { item, key, value, value })
end

function InventoryControllers.DeleteInventoryItem(id)
  MySQL.query.await('DELETE FROM `inventory_items` WHERE `id`=? LIMIT;', { id })
end

function InventoryControllers.DeleteInventoryItems(inventory, itemId, quantity)
  local query = 'DELETE FROM `inventory_items` WHERE `inventory_id`=? AND `item_id`=? LIMIT ' .. quantity .. ';'
  MySQL.query.await(query, { inventory, itemId })
end

function InventoryControllers.IsItemRestricted(inventory, itemId)
  local result = MySQL.query.await("SELECT id FROM `inventory_blacklist` WHERE `inventory_id`=? AND `item_id`=?",
    { inventory, itemId })
  if not result[1] then
    return false
  end
  return true
end

function InventoryControllers.UpdateRestrictedItems(inventory, items)
  local result = MySQL.query.await(
    "SELECT `inventory_blacklist`.`inventory_id`, `inventory_blacklist`.`item_id`, `items`.`name` FROM `inventory_blacklist` INNER JOIN `items` ON `items`.`id`=`inventory_blacklist`.`item_id` WHERE `inventory_blacklist`.`inventory_id`=?;",
    { inventory })

  -- Add Restricted Items
  for _, item in pairs(items) do
    local itemId = ItemControllers.GetItemByName(item)
    MySQL.query.await('INSERT IGNORE INTO `inventory_blacklist` (`inventory_id`, `item_id`) VALUES (?,?);',
      { inventory, itemId })
  end

  if result[1] then
    -- Remove no longer restricted items
    for _, item in pairs(result[1]) do
      if not TableContains(items, item.name) then
        MySQL.query.await('DELETE FROM `inventory_blacklist` WHERE `inventory_id`=? AND `item_id`=?',
          { item.inventory_id, item.item_id })
      end
    end
  end
end

function InventoryControllers.MoveInventoryItems(sourceInventory, targetInventory, items)
  for _, item in pairs(items) do
    local id = nil 
    if type(item) == 'table' then
      id = item.id
    elseif type(item) == 'number' then
      id = item
    else
      error('Invalid Item type in MoveItems')
      return
    end

    MySQL.query.await('UPDATE `inventory_items` SET `inventory_id`=? WHERE `id`=?;', { targetInventory, id })
  end

  return {
    sourceItems = InventoryControllers.GetInventoryItems(sourceInventory),
    targetItems = InventoryControllers.GetInventoryItems(targetInventory)
  }
end

function InventoryControllers.DeleteInventory(uuid)
  MySQL.query.await('DELETE FROM `inventory` WHERE `uuid` = ?;', { uuid })
end