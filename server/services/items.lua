--TODO: Replace errors with the core notifies

-- Item-instance operations (add/remove/use/drop) on top of the raw
-- inventory_items rows managed by InventoryControllers. `inventoryId`
-- throughout this file follows the framework's dual convention: a numeric
-- value is treated as a player src (resolved to that player's own
-- character inventory), a string is treated as a raw inventory UUID.
ItemsAPI = {}
UsableItemCallbacks = {}

function ItemsAPI.GetDefinitions()
  return ItemControllers.GetItemDefinitions()
end

-- Atomically grants catalog items without metadata. Intended for trusted
-- server resources such as administration, rewards, and scripted payouts.
function ItemsAPI.GrantItem(itemName, quantity, inventoryId)
  if type(itemName) ~= 'string' or itemName == '' then
    return { error = true, code = 'invalid_item', message = 'Invalid item name.' }
  end
  quantity = tonumber(quantity)
  if not quantity or quantity < 1 or quantity % 1 ~= 0 or quantity > 10000 then
    return { error = true, code = 'invalid_quantity', message = 'Invalid quantity.' }
  end

  local definition = ItemControllers.GetItemDefinitionByName(itemName)
  if not definition then
    return { error = true, code = 'invalid_item', message = 'Item does not exist.' }
  end

  local inventory, maxWeight, ignoreItemLimit
  if tonumber(inventoryId) then
    local player = Feather.Character.GetCharacter({ src = tonumber(inventoryId) })
    local character = player and player.char
    if character then
      inventory, maxWeight, ignoreItemLimit = InventoryControllers.GetInventoryByCharacter(character.id)
    end
  else
    inventory, maxWeight, ignoreItemLimit = InventoryControllers.GetInventoryById(inventoryId)
  end
  if not inventory then
    return { error = true, code = 'invalid_inventory', message = 'Inventory does not exist.' }
  end

  local currentItemCount = InventoryControllers.InventoryItemCount(inventory, definition.id)
  local totalItemCount = InventoryControllers.GetInventoryTotalItemCounts(inventory)
  totalItemCount = totalItemCount[1] and tonumber(totalItemCount[1].count) or 0
  if totalItemCount + quantity > (tonumber(Config.maxItemSlots) or math.huge) then
    return { error = true, code = 'inventory_full', message = 'Inventory has no available slots.' }
  end

  if tonumber(ignoreItemLimit) ~= 1 then
    local maximum = math.min(tonumber(definition.max_quantity) or 0,
      tonumber(definition.max_stack_size) or 0)
    if maximum < 1 or currentItemCount + quantity > maximum then
      return { error = true, code = 'item_limit', message = 'Item quantity limit would be exceeded.' }
    end
  end

  local addedWeight = (tonumber(definition.weight) or 0) * quantity
  local weightLimit = tonumber(maxWeight) or tonumber(Config.maxWeight)
  if weightLimit and InventoryControllers.GetInventoryTotalWeight(inventory) + addedWeight > weightLimit then
    return { error = true, code = 'weight_limit', message = 'Inventory weight limit would be exceeded.' }
  end

  -- Steampunk ledger: same slot-assignment as AddItem below -- join an
  -- under-full stack of this item first, then roll into fresh free slots.
  local maxStackSize = tonumber(definition.max_stack_size) or 1
  local currentSlot = InventoryControllers.GetJoinableSlot(inventory, definition.id, maxStackSize)
  local currentSlotCount = currentSlot ~= nil and #InventoryControllers.GetItemsInSlot(inventory, currentSlot) or 0

  local placeholders = {}
  local values = {}
  for index = 1, quantity do
    if currentSlot == nil or currentSlotCount >= maxStackSize then
      currentSlot = InventoryControllers.GetFreeSlot(inventory, tonumber(Config.maxItemSlots) or 0)
      currentSlotCount = 0
      if currentSlot == nil then
        return { error = true, code = 'inventory_full', message = 'Inventory has no available slots.' }
      end
    end

    placeholders[index] = '(?, ?, ?)'
    values[#values + 1] = inventory
    values[#values + 1] = definition.id
    values[#values + 1] = currentSlot
    currentSlotCount = currentSlotCount + 1
  end
  local succeeded, insertId = pcall(MySQL.insert.await,
    ('INSERT INTO inventory_items (inventory_id, item_id, slot_index) VALUES %s'):format(table.concat(placeholders, ', ')), values)
  if not succeeded or insertId == nil then
    return { error = true, code = 'database_error', message = 'Items could not be granted.' }
  end

  TriggerEvent('feather-inventory:ItemAdded', definition.id, quantity, inventory)
  return {
    error = false,
    itemName = definition.name,
    displayName = definition.display_name,
    quantity = quantity
  }
end

-- Grants `quantity` of `itemName` to an inventory, enforcing per-item max
-- quantity/stack-size and weight limits. Fires feather-inventory:ItemAdded
-- once per unit granted.
ItemsAPI.AddItem = function(itemName, quantity, metadata, inventoryId)
  quantity = tonumber(quantity)
  if not quantity or quantity < 1 or quantity % 1 ~= 0 then
    warn('Invalid quantity. Must be creater than 0.')
    return {
      error = true,
      message = "Invalid quantity. Must be creater than 0."
    }
  end

  local itemId, max_quantity, item_weight, max_stack_size = ItemControllers.GetItemByName(itemName)
  if not itemId then
    warn('Invalid itemName. Please make sure it is in the items table in your database.')
    return {
      error = true,
      message = "Invalid itemName. Please make sure it is in the items table in your database."
    }
  end

  local ItemCount = ItemsAPI.GetItemCount(itemName, inventoryId)

  -- Check to make sure this doesnt exceed the amount of slots available.
  -- (Tier 1 audit sweep) Was `(ItemCount + quantity) / max_stack_size >
  -- max_stack_size`, which requires ItemCount+quantity > max_stack_size^2
  -- to ever reject -- far more permissive than the stated "max stack size"
  -- limit.
  if (ItemCount + quantity) > max_stack_size then
    return {
      error = true,
      message = "Max slots reached"
    }
  end


  local inventory, maxWeight, ignore_item_limit = nil, nil, nil
  if tonumber(inventoryId) then
    local player = Feather.Character.GetCharacter({ src = inventoryId })
    local character = player and player.char
    -- (Phase 6 consistency pass) No character loaded for this src used to
    -- crash here (nil index on `.id`) instead of falling through to the
    -- "Invalid inventory ID" rejection below, same as every other resolved-
    -- character branch in this file.
    if character then
      inventory, maxWeight, ignore_item_limit, _ = InventoryControllers.GetInventoryByCharacter(character.id)
    end
  else
    inventory, maxWeight, ignore_item_limit, _ = InventoryControllers.GetInventoryById(inventoryId)
  end

  -- Check to make sure this doesnt exceed the max quantity for this item.
  -- (was >=, which rejected exactly reaching the max -- every seeded weapon
  -- has max_quantity=1, so granting even a single one always failed)
  if ItemCount + quantity > max_quantity and ignore_item_limit == 0 then
    return {
      error = true,
      message = "Too Many Items in Inventory"
    }
  end

  if not inventory then
    warn('Invalid inventory ID.')
    return {
      error = true,
      message = "Invalid inventory ID."
    }
  end

  -- (§10.1 weight parity) GrantItem and every transfer path
  -- (MoveInventoryItems, via InventoryCanHoldById) already enforce this --
  -- AddItem was the one remaining grant path that could push an inventory
  -- over its weight limit. Unconditional like the other two, not gated by
  -- ignore_item_limit (that flag only exempts quantity/stack-size limits,
  -- see InventoryCanHold/InventoryCanHoldById above it).
  local addedWeight = (tonumber(item_weight) or 0) * quantity
  local weightLimit = tonumber(maxWeight) or tonumber(Config.maxWeight)
  if weightLimit and InventoryControllers.GetInventoryTotalWeight(inventory) + addedWeight > weightLimit then
    return {
      error = true,
      message = "Max Weight Exceeded."
    }
  end

  if metadata ~= nil and type(metadata) ~= 'table' then
    warn(
      "Invalid format for meta data. Meta data must be a table of key value pairs. Example: { quality = 'poor', durability = 50, maxDurability = 100 }")
    return {
      error = true,
      message =
      "Invalid format for meta data. Meta data must be a table of key value pairs. Example: { quality = 'poor', durability = 50, maxDurability = 100 }"
    }
  end

  -- Steampunk ledger: each granted unit needs a real compartment (slot_index),
  -- not just a bare row. Join an existing under-full stack of this item
  -- first; once that's full (or there wasn't one), roll into fresh free
  -- slots for the rest. The max-quantity/slot checks above already confirm
  -- there's room overall, so GetFreeSlot running out here would only mean a
  -- race with another grant -- guarded rather than trusted.
  local currentSlot = InventoryControllers.GetJoinableSlot(inventory, itemId, max_stack_size)
  local currentSlotCount = currentSlot ~= nil and #InventoryControllers.GetItemsInSlot(inventory, currentSlot) or 0

  for count = 1, quantity do
    if currentSlot == nil or currentSlotCount >= max_stack_size then
      currentSlot = InventoryControllers.GetFreeSlot(inventory, tonumber(Config.maxItemSlots) or 0)
      currentSlotCount = 0
      if currentSlot == nil then
        warn('AddItem: ran out of free slots granting ' .. itemName .. ' to inventory ' .. tostring(inventory))
        break
      end
    end

    local item = InventoryControllers.CreateInventoryItem(inventory, itemId, currentSlot)
    currentSlotCount = currentSlotCount + 1

    if metadata ~= nil then
      for k, v in pairs(metadata) do
        InventoryControllers.SetMetadata(item[1].id, k, v)
      end
    end

    TriggerEvent('feather-inventory:ItemAdded', itemId, 1, inventory)

    count = count + 1
  end

  return {
    error = false
  }
end

-- Removes n number of items by name. (No specific order)
ItemsAPI.RemoveItemByName = function(itemName, quantity, inventoryId)
  if quantity < 1 then
    warn('Invalid quantity. Must be creater than 0.')
    return {
      error = true,
      message = "Invalid quantity. Must be creater than 0."
    }
  end

  local itemId, _, _ = ItemControllers.GetItemByName(itemName)
  if not itemId then
    warn('Invalid itemName. Please make sure it is in the items table in your database.')
    return {
      error = true,
      message = "Invalid itemName. Please make sure it is in the items table in your database."
    }
  end

  local inventory, _, _ = nil, nil, nil
  if tonumber(inventoryId) then
    local player = Feather.Character.GetCharacter({ src = inventoryId })
    local character = player and player.char
    if character then
      inventory, _, _ = InventoryControllers.GetInventoryByCharacter(character.id)
    end
  else
    inventory, _, _ = InventoryControllers.GetInventoryById(inventoryId)
  end
  if not inventory then
    warn('Invalid inventory ID.')
    return {
      error = true,
      message = "Invalid inventory ID."
    }
  end

  local itemCount = InventoryControllers.InventoryItemCount(inventory, itemId)
  if itemCount < quantity then
    return {
      error = true,
      message = "Withdrawing more items than available."
    }
  end

  -- (Tier 1 audit sweep) Was `inventory.id` -- `inventory` here is already
  -- the raw numeric inventory id (DeleteInventoryItems' own signature takes
  -- the id directly), not a table, so this indexed a number and crashed on
  -- every call. Every caller of this exported function -- crafting
  -- ingredient consumption, ammo use, anything built on RemoveItemByName --
  -- was broken.
  InventoryControllers.DeleteInventoryItems(inventory, itemId, quantity)
  
  TriggerEvent('feather-inventory:ItemRemoved', itemId, quantity, inventoryId)
  return {
    error = false
  }
end

-- Removes a specific item from the players inventory.
ItemsAPI.RemoveItemById = function(id)
  local item = InventoryControllers.GetInventoryItemById(id)
  if not item then
    return {
      error = true,
      message = "Item not available."
    }
  end
  InventoryControllers.DeleteInventoryItem(item.id)

  TriggerEvent('feather-inventory:ItemRemoved', item.id, 1, item.inventory_id)
  return {
    error = false,
  }
end

ItemsAPI.SetMetadata = function(item, metadata)
  if item == nil or type(item) ~= 'number' then
    warn('Item ID is required.')
    return {
      error = true,
      message = "Item ID is required."
    }
  end
  if metadata == nil or type(metadata) ~= 'table' then
    warn(
      "Invalid format for meta data. Meta data must be a table of key value pairs. Example: { quality = 'poor', durability = 50, maxDurability = 100 }")
    return {
      error = true,
      message =
      "Invalid format for meta data. Meta data must be a table of key value pairs. Example: { quality = 'poor', durability = 50, maxDurability = 100 }"
    }
  end

  for k, v in pairs(metadata) do
    InventoryControllers.SetMetadata(item, k, v)
  end
  return {
    error = false
  }
end

ItemsAPI.GetItem = function(id)
  local item = InventoryControllers.GetInventoryItemById(id)
  if not item then
    return nil
  end

  return item
end

ItemsAPI.GetItemCount = function(itemName, inventoryId)
  local itemId, _, _ = ItemControllers.GetItemByName(itemName)
  if not itemId then
    warn('Invalid itemName. Please make sure it is in the items table in your database.')
    return -1
  end

  local inventory, _, _ = nil, nil, nil
  if tonumber(inventoryId) then
    local player = Feather.Character.GetCharacter({ src = inventoryId })
    local character = player and player.char
    if character then
      inventory, _, _ = InventoryControllers.GetInventoryByCharacter(character.id)
    end
  else
    inventory, _, _ = InventoryControllers.GetInventoryById(inventoryId)
  end
  -- (Phase 6 consistency pass) `not inventory == nil` -- `not` binds tighter
  -- than `==`, so this was `(not inventory) == nil`, a boolean compared to
  -- nil, which is always false. An invalid inventoryId silently fell
  -- through to InventoryItemCount(nil, itemId) instead of ever hitting this
  -- rejection (harmless there -- a nil inventory_id just matches nothing in
  -- SQL -- but not the intended "return -1" contract).
  if not inventory then
    warn('Invalid inventory ID.')
    return -1
  end

  local itemCount = InventoryControllers.InventoryItemCount(inventory, itemId)

  return itemCount
end

-- (INV-15) Was inverted -- returned false when the item *was* found and true
-- when it wasn't, so every caller's "does this item exist" check read
-- backwards.
ItemsAPI.ItemExists = function(itemName)
  local itemId, _, _ = ItemControllers.GetItemByName(itemName)
  return itemId ~= nil and itemId ~= false
end

ItemsAPI.InventoryHasItems = function(items, inventoryId)
  local numberOfItems = #items
  local count = 0

  local inventory, _, _ = nil, nil, nil
  if tonumber(inventoryId) then
    local player = Feather.Character.GetCharacter({ src = inventoryId })
    local character = player and player.char
    if character then
      inventory, _, _ = InventoryControllers.GetInventoryByCharacter(character.id)
    end
  else
    inventory, _, _ = InventoryControllers.GetInventoryById(inventoryId)
  end
  if not inventory then
    return false
  end
  local playerItems = InventoryControllers.InventoryItemCounts(inventory)

  -- Error Checks
  if not IsTable(items) then
    warn('items must be a table! e.g. {{name = "apple", quantity = 2}, {name = "lemon", quantity = 1}}')
    return false
  end

  for _, v in pairs(items) do
    if not IsTable(v) then
      warn('items must be a table! e.g. {{name = "apple", quantity = 2}, {name = "lemon", quantity = 1}}')
      return false
    end

    if v.name == nil or tonumber(v.quantity) == nil then
      warn('items must be a table! e.g. {{name = "apple", quantity = 2}, {name = "lemon", quantity = 1}}')
      return false
    end
  end

  -- (INV-15) Two bugs: `playerItem['COUNT[...]']` never matched the query's
  -- actual column key (now `.count`, see InventoryControllers.
  -- InventoryItemCounts), so the quantity comparison always errored/failed;
  -- and the final `count < numberOfItems` was backwards -- it should report
  -- "has items" when every requested item was satisfied, not when fewer than
  -- all of them were.
  for _, requestedItem in pairs(items) do
    for _, playerItem in pairs(playerItems) do
      if playerItem and requestedItem.name == playerItem.name and tonumber(playerItem.count) >= tonumber(requestedItem.quantity) then
        count = count + 1
      end
    end
  end

  return count >= numberOfItems
end

-- Lets other resources (e.g. feather-weapons, for every weapon item) attach
-- a "use" behavior to an item by name. Looked up by ItemsAPI.UseItem below
-- when a player actually uses the item from their inventory.
ItemsAPI.RegisterUsableItem = function(itemName, callback)
  if UsableItemCallbacks[itemName] then
    warn('An Item by that name has laready been registered. Item: ' .. itemName)
    return
  end

  UsableItemCallbacks[itemName] = callback
end

ItemsAPI.UseItem = function(itemID, src)
  local item = InventoryControllers.GetInventoryItemById(itemID)
  if not item then
    warn('Item not found in the database! ItemID: ' .. itemID)
    return false
  end
  if tonumber(src) == nil then
    warn('Invalid Player Source')
    return false
  end

  -- (INV-02) This ownership check was commented out, so any client could
  -- "use" any item id -- including ones it didn't own -- which chains into
  -- free weapon equips via feather-weapons' usable-item registration.
  -- Re-enabled, and compares against the item's actual current
  -- inventory_id (not something client-suppliable) rather than the
  -- original draft's approach.
  local player = Feather.Character.GetCharacter({ src = src })
  local character = player and player.char
  if not character then
    warn('No character loaded for src: ' .. src)
    return false
  end

  local inventory = InventoryControllers.GetInventoryByCharacter(character.id)
  if not inventory or tostring(item.inventory_id) ~= tostring(inventory) then
    warn('Rejected UseItem: src ' .. src .. ' does not own item ' .. tostring(itemID))
    return false
  end

  -- if item.type == 'item_weapon' then
  --   TriggerEvent('Feather:Inventory:UsedItem', src, item)
  -- elseif item.type == 'item_ammo' then
  --   TriggerEvent('Feather:Inventory:UsedItem', src, item)
  -- else
  if UsableItemCallbacks[item.name] then
    UsableItemCallbacks[item.name](item, src, function()
      -- Refresh the inventory ui on callback
      TriggerClientEvent('Feather:Inventory:OpenInventory', src, nil, "player")
    end)
  else
    warn('No usable callback defined for item: ' .. item.name)
  end
  -- end

  return true
end


ItemsAPI.DropItemsOnGround = function(inventoryId, items, x, y, z)
  if type(items) ~= 'table' or #items == 0 then
    return {
      error = true,
      message = 'No items specified.'
    }
  end

  -- (INV-03) The old check only validated items[1]'s name/count via
  -- GetItemCount, then let MoveInventoryItems move every items[].id
  -- regardless of whether it actually matched that name or belonged to
  -- inventoryId -- a client could mix in foreign item ids to duplicate/
  -- steal items onto the ground. Every item is now checked against
  -- inventoryId up front (inventoryId itself is already server-derived
  -- from src by the caller, not client-supplied).
  for _, entry in ipairs(items) do
    local id = type(entry) == 'table' and entry.id or entry
    local item = InventoryControllers.GetInventoryItemById(id)
    if not item or tostring(item.inventory_id) ~= tostring(inventoryId) then
      warn('Rejected DropItemsOnGround: item ' .. tostring(id) .. ' does not belong to inventory ' .. tostring(inventoryId))
      return {
        error = true,
        message = 'One or more items are not in your inventory.'
      }
    end
  end

  -- (INV-16) Was `Config.groundGroupingRadius`, which doesn't exist -- the
  -- real key is `Config.Dropped.GroupingRadius` (see config.lua and
  -- services/errors.lua's startup validation of it). Reading the wrong key
  -- passed nil as the radius, silently disabling grouping: every drop made
  -- its own ground pile instead of joining a nearby one.
  local groundID = GroundControllers.GetClosestGroundByCoords(x, y, z, Config.Dropped.GroupingRadius)
  
  -- No nearby ground, lets create a new one
  if groundID == nil or groundID == 'nil' then
    groundID = GroundControllers.CreateGround(x, y, z)[1].id
  end

  -- (INV-11/INV-12) isPublic=true: anyone may open a ground pile, but only
  -- after GetGroundUID (server/services/ground.lua) has verified they're
  -- actually standing near it and issued a short-lived grant -- see
  -- InventoryAPI.GrantTemporaryAccess / IsAuthorizedForOwnedInventory.
  local _, groundInventoryID = InventoryAPI.RegisterInventory('ground', groundID, 'Ground', nil, nil, nil, nil, true)
  local updateinv = InventoryControllers.MoveInventoryItems(inventoryId, groundInventoryID, items)

  -- This always reported `error = false` even when MoveInventoryItems
  -- itself rejected the move (e.g. capacity) -- the ground pile row would
  -- exist but the item never actually left the source inventory, with no
  -- error surfaced to the client to explain why.
  if updateinv and updateinv.error then
    return {
      error = true,
      message = updateinv.message,
      inv = updateinv
    }
  end

  UpdateClientWithGroundLocations(-1)

  return {
    error = false,
    inv = updateinv
  }
end
