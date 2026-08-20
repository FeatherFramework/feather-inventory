InventoryControllers = {}

function InventoryControllers.GetInventoryById(inventoryId, type)
  if type == nil then
    type = 'uuid'
  end

  local query = ''

  if type == 'id' then
    query = 'SELECT `id`, `uuid`, `max_weight`, `ignore_item_limit`, `name` FROM `inventory` WHERE `id` = ? LIMIT 1;'
  else
    query = 'SELECT `id`, `uuid`, `max_weight`, `ignore_item_limit`, `name` FROM `inventory` WHERE `uuid` = ? LIMIT 1;'
  end


  local result = MySQL.query.await(
    query, { inventoryId })[1]
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
  local result = MySQL.query.await('SELECT `inventory_items`.`id`, `inventory_items`.`updated_at`, `inventory_items`.`slot_index`, `items`.`display_name`, `items`.`name`, `items`.`description`, `items`.`usable`, `items`.`weight`, `items`.`category_id`, `items`.`max_quantity`, `items`.`max_stack_size`, JSON_OBJECTAGG(`item_metadata`.`key`, `item_metadata`.`value`) AS `item_metadata`, `inventory_items`.`inventory_id` FROM `inventory_items` INNER JOIN `items` ON `inventory_items`.`item_id` = `items`.`id` LEFT JOIN `item_metadata` ON `item_metadata`.`inventory_items_id` = `inventory_items`.`id` WHERE `inventory_items`.`id`=? GROUP BY `inventory_items`.`id`, `inventory_items`.`slot_index`, `items`.`display_name`, `items`.`name`, `items`.`description`, `items`.`usable`, `items`.`weight`, `items`.`category_id`, `items`.`max_quantity`, `items`.`max_stack_size` LIMIT 1;', { id })[1]

  if result == nil then
    return false
  end

  if result["item_metadata"] and result["item_metadata"] ~= nil then
    result["item_metadata"] = json.decode(result["item_metadata"])
  end

  return result
end

-- (INV-15-pattern) Same bug as InventoryItemCounts had: the unaliased
-- SUM(...) expression's actual returned column key is the full expression
-- text "SUM(`items`.`weight`)", not the bare "`items`.`weight`" this used
-- to index -- so this always fell through to `return 0`, silently making
-- InventoryCanHold's weight-limit check (INV-14) a no-op: it only ever saw
-- the new items' weight, never what the inventory already held. Explicit
-- `AS weight` fixes the mismatch.
function InventoryControllers.GetInventoryTotalWeight(inventory)
  local result = MySQL.query.await(
    'SELECT SUM(`items`.`weight`) AS `weight` FROM `items` INNER JOIN `inventory_items` ON `items`.`id`=`inventory_items`.`item_id` WHERE `inventory_items`.`inventory_id`=?',
    { inventory })
  if not result[1] or not result[1].weight then
    return 0
  end

  return result[1].weight
end

function InventoryControllers.GetInventoryItems(inventory)
  local items = MySQL.query.await( 'SELECT `inventory_items`.`id`, `inventory_items`.`updated_at`, `inventory_items`.`slot_index`, `items`.`display_name`, `items`.`name`, `items`.`description`, `items`.`usable`, `items`.`weight`, `items`.`category_id`, `items`.`max_quantity`, `items`.`max_stack_size`, JSON_OBJECTAGG(`item_metadata`.`key`, `item_metadata`.`value`) AS `item_metadata` FROM `inventory_items` INNER JOIN `items` ON `inventory_items`.`item_id` = `items`.`id` LEFT JOIN `item_metadata` ON `item_metadata`.`inventory_items_id` = `inventory_items`.`id` WHERE `inventory_items`.`inventory_id` = ? GROUP BY `inventory_items`.`id`, `inventory_items`.`slot_index`, `items`.`display_name`, `items`.`name`, `items`.`description`, `items`.`usable`, `items`.`weight`, `items`.`category_id`, `items`.`max_quantity`, `items`.`max_stack_size`;', { inventory })
  for key, value in pairs(items) do
    if value["item_metadata"] and value["item_metadata"] ~= nil then
      items[key]["item_metadata"] = json.decode(value["item_metadata"])
    end
  end

  return items
end

function InventoryControllers.InventoryItemCounts(inventory)
  -- (INV-15) Explicit `AS count` -- the unaliased COUNT(...) expression's
  -- returned column key doesn't match the bracket-string ItemsAPI.
  -- InventoryHasItems used to index it by, so every lookup read nil.
  return MySQL.query.await(
    'SELECT `items`.`name`, COUNT(`items`.`name`) AS `count` FROM `inventory_items` INNER JOIN `items` ON `inventory_items`.`item_id`=`items`.`id` WHERE `inventory_items`.`inventory_id`=? GROUP BY `items`.`name`;',
    { inventory })
end

function InventoryControllers.GetInventoryTotalItemCounts(inventory)
  return MySQL.query.await(
    'SELECT COUNT(`id`) AS `count` FROM `inventory_items` WHERE `inventory_id`=?;',
    { inventory })
end


function InventoryControllers.CreateInventoryItem(inventory, itemId, slotIndex)
  return MySQL.query.await('INSERT INTO `inventory_items` (`inventory_id`, `item_id`, `slot_index`) VALUES (?, ?, ?) RETURNING *;',
    { inventory, itemId, slotIndex })
end

-- Steampunk ledger: a compartment already holding this item with room left
-- under its stack limit -- new units join it instead of claiming a fresh
-- slot, same "stack up to max_stack_size" behavior the client used to fake
-- with lodash chunk/groupBy, now actually persisted.
function InventoryControllers.GetJoinableSlot(inventory, itemId, maxStackSize)
  local result = MySQL.query.await(
    'SELECT `slot_index`, COUNT(*) AS `count` FROM `inventory_items` WHERE `inventory_id`=? AND `item_id`=? AND `slot_index` IS NOT NULL GROUP BY `slot_index` HAVING COUNT(*) < ? LIMIT 1;',
    { inventory, itemId, maxStackSize })
  if not result[1] then
    return nil
  end
  return result[1].slot_index
end

-- First compartment index in [0, capacity) not occupied by any item at all.
function InventoryControllers.GetFreeSlot(inventory, capacity)
  local used = MySQL.query.await(
    'SELECT DISTINCT `slot_index` FROM `inventory_items` WHERE `inventory_id`=? AND `slot_index` IS NOT NULL;',
    { inventory })
  local occupied = {}
  for _, row in pairs(used) do
    occupied[tonumber(row.slot_index)] = true
  end
  for i = 0, capacity - 1 do
    if not occupied[i] then
      return i
    end
  end
  return nil
end

-- Every row sharing an (inventory, slot) pair -- a whole compartment's stack,
-- since a slot can hold more than one unit of the same item.
function InventoryControllers.GetItemsInSlot(inventory, slot)
  return MySQL.query.await('SELECT `id` FROM `inventory_items` WHERE `inventory_id`=? AND `slot_index`=?;',
    { inventory, slot })
end

-- Steampunk ledger drag-and-drop: moves every row in (fromInventory, fromSlot)
-- to (toInventory, toSlot). If toSlot is already occupied, swaps -- the
-- occupant's rows move to (fromInventory, fromSlot) instead of being
-- displaced silently. Matches the design's "drop on empty moves, drop on
-- occupied swaps," and moves the whole compartment's stack at once since
-- stack splitting isn't part of this design.
function InventoryControllers.MoveSlotItems(fromInventory, fromSlot, toInventory, toSlot)
  local moving = InventoryControllers.GetItemsInSlot(fromInventory, fromSlot)
  local occupant = InventoryControllers.GetItemsInSlot(toInventory, toSlot)

  if #occupant > 0 then
    for _, row in pairs(occupant) do
      MySQL.query.await('UPDATE `inventory_items` SET `inventory_id`=?, `slot_index`=? WHERE `id`=?;',
        { fromInventory, fromSlot, row.id })
    end
  end

  for _, row in pairs(moving) do
    MySQL.query.await('UPDATE `inventory_items` SET `inventory_id`=?, `slot_index`=? WHERE `id`=?;',
      { toInventory, toSlot, row.id })
  end

  return #moving > 0
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
  -- (INV-08) `LIMIT;` with no number is a SQL syntax error -- this deletes
  -- by unique `id` already, so no LIMIT clause is needed at all.
  MySQL.query.await('DELETE FROM `inventory_items` WHERE `id`=?;', { id })
end

-- (INV-08) `quantity` was concatenated straight into the query string --
-- oxmysql can't bind LIMIT's argument as a `?` parameter, but it must still
-- never be trusted as raw client input. `quantity` today only ever comes
-- from server-side callers, but tonumber+math.floor here makes that a
-- guarantee of this function rather than an assumption about its callers.
function InventoryControllers.DeleteInventoryItems(inventory, itemId, quantity)
  local safeQuantity = math.floor(tonumber(quantity) or 0)
  if safeQuantity < 1 then
    return
  end
  local query = 'DELETE FROM `inventory_items` WHERE `inventory_id`=? AND `item_id`=? LIMIT ' .. safeQuantity .. ';'
  MySQL.query.await(query, { inventory, itemId })
end

-- (Drop bugfix) inventory_blacklist has no `id` column at all -- its
-- primary key is the composite (inventory_id, item_id) -- so this query
-- always errored outright ("Unknown column 'id' in 'SELECT'"). Masked until
-- now because every caller reached this through InventoryCanHold, which
-- always rejected one step earlier for an unrelated reason (see
-- InventoryCanHoldById's comment) and never actually got this far.
function InventoryControllers.IsItemRestricted(inventory, itemId)
  local result = MySQL.query.await("SELECT `inventory_id` FROM `inventory_blacklist` WHERE `inventory_id`=? AND `item_id`=?",
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

-- (INV-01 root cause / INV-09) Previously moved every item by raw id with
-- no check that it actually belonged to sourceInventory -- a caller could
-- name any inventory_items.id and pull it out of wherever it actually
-- lived, regardless of sourceInventory. Membership is now verified here so
-- every caller (RPC handlers, GiveItem, any future resource) gets this for
-- free, not just the one call site that happened to get patched. This also
-- fixes the nested-loop bug that fired ItemRemoved/ItemAdded #items^2
-- times instead of once per moved item.
function InventoryControllers.MoveInventoryItems(sourceInventory, targetInventory, items)
  -- (INV-14) Every transfer path (UpdateInventory, GiveItem,
  -- DropItemsOnGround) funnels through here, so this is the one place that
  -- can guarantee slot/weight/restricted-item limits are actually enforced
  -- instead of decorative. Resolve the requested item ids to names/counts
  -- first and reject the whole move if the target can't hold them -- items
  -- are per-unit rows here (no quantity field), so counts are built by name.
  local requestCounts = {}
  for _, item in pairs(items) do
    local id = type(item) == 'table' and item.id or item
    local existingItem = InventoryControllers.GetInventoryItemById(id)
    if existingItem and tostring(existingItem.inventory_id) == tostring(sourceInventory) then
      requestCounts[existingItem.name] = (requestCounts[existingItem.name] or 0) + 1
    end
  end

  local checkItems = {}
  for name, quantity in pairs(requestCounts) do
    table.insert(checkItems, { item = name, quantity = quantity })
  end

  if #checkItems > 0 then
    -- InventoryCanHold (not ById) would misread this raw inventory.id as a
    -- player source and always reject -- see InventoryCanHoldById's comment.
    local canHold = InventoryAPI.InventoryCanHoldById(checkItems, targetInventory)
    if not canHold or canHold.status == false then
      return {
        error = true,
        message = canHold and canHold.message or 'Target inventory cannot hold these items.',
        sourceItems = InventoryControllers.GetInventoryItems(sourceInventory),
        targetItems = InventoryControllers.GetInventoryItems(targetInventory)
      }
    end
  end

  for _, item in pairs(items) do
    local id = nil
    if type(item) == 'table' then
      id = item.id
    elseif type(item) == 'number' then
      id = item
    else
      warn('Invalid Item type in MoveItems')
      return
    end

    local existingItem = InventoryControllers.GetInventoryItemById(id)
    if not existingItem or tostring(existingItem.inventory_id) ~= tostring(sourceInventory) then
      warn('MoveInventoryItems: skipping item ' .. tostring(id) .. ' -- does not belong to source inventory ' .. tostring(sourceInventory))
    else
      -- (Steampunk ledger) Carrying the item's old slot_index straight over
      -- would silently collide with whatever the target inventory already
      -- has sitting in that same slot -- give it a real compartment in the
      -- destination the same way ItemsAPI.AddItem does (join a matching
      -- under-full stack, else the first free slot).
      local itemDefId = ItemControllers.GetItemByName(existingItem.name)
      local targetSlot = InventoryControllers.GetJoinableSlot(targetInventory, itemDefId, existingItem.max_stack_size)
      if targetSlot == nil then
        targetSlot = InventoryControllers.GetFreeSlot(targetInventory, tonumber(Config.maxItemSlots) or 0)
      end

      MySQL.query.await('UPDATE `inventory_items` SET `inventory_id`=?, `slot_index`=? WHERE `id`=?;', { targetInventory, targetSlot, id })

      TriggerEvent('feather-inventory:ItemRemoved', id, 1, sourceInventory)
      TriggerEvent('feather-inventory:ItemAdded', id, 1, targetInventory)
    end
  end

  return {
    sourceItems = InventoryControllers.GetInventoryItems(sourceInventory),
    targetItems = InventoryControllers.GetInventoryItems(targetInventory)
  }
end

function InventoryControllers.DeleteInventory(uuid)
  MySQL.query.await('DELETE FROM `inventory` WHERE `uuid` = ?;', { uuid })
end

function InventoryControllers.DeleteInventoryById(id)
  MySQL.query.await('DELETE FROM `inventory` WHERE `id` = ?;', { id })
end

-- (Ground cleanup bugfix) Sweeping the `ground` table (world positions)
-- without also clearing the `inventory` rows that point at it left every
-- emptied/swept ground pile's inventory row orphaned forever -- nothing
-- ever deleted them. inventory_items/inventory_access both cascade-delete
-- on inventory_id, so this alone is enough to fully clean a location up.
function InventoryControllers.DeleteInventoriesByLocation(location)
  MySQL.query.await('DELETE FROM `inventory` WHERE `location` = ?;', { location })
end
