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

  -- (Capacity model unification) Was three separate checks here, two of them
  -- wrong in the same way AddItem's were -- see EvaluateInventoryAcceptance
  -- (server/services/inventory.lua). The slot check counted item *units*
  -- against Config.maxItemSlots, so 25 apples stacked into 2 compartments
  -- reported a full 25-slot book; the quantity check used
  -- math.min(max_quantity, max_stack_size), capping an item at its
  -- per-compartment stack size no matter how much the inventory was actually
  -- allowed to hold.
  local acceptance = InventoryAPI.EvaluateInventoryAcceptance(inventory, maxWeight, ignoreItemLimit,
    { { item = definition.name, quantity = quantity } })
  if not acceptance or acceptance.status == false then
    return {
      error = true,
      code = (acceptance and acceptance.code) or 'inventory_full',
      message = (acceptance and acceptance.message) or 'Inventory cannot hold these items.'
    }
  end

  -- Steampunk ledger: same slot-assignment as AddItem below -- join an
  -- under-full stack of this item first, then roll into fresh free slots.
  local maxStackSize = tonumber(definition.max_stack_size) or 1
  local currentSlot = InventoryControllers.GetJoinableSlot(inventory, definition.id, maxStackSize)
  local currentSlotCount = currentSlot ~= nil and #InventoryControllers.GetItemsInSlot(inventory, currentSlot) or 0
  -- (§10.4) Hoisted out of the loop -- per-inventory capacity is a DB read
  -- now, and it can't change while this grant is being assembled.
  local capacity = InventoryControllers.GetInventoryCapacity(inventory)

  -- (Over-stacking bugfix) This loop builds ONE batched INSERT, executed only
  -- after it finishes -- so nothing it places is visible to a database read
  -- taken during it. Calling GetFreeSlot per unit therefore returned the same
  -- free compartment every single time, and every unit past the first full
  -- stack landed in that one slot: a grant of 100 apples with max_stack_size
  -- 20 produced a compartment holding 78, wildly past the stack limit.
  --
  -- Claim slots against a local set instead, seeded once from the database
  -- and marked as this loop consumes them. (AddItem below is unaffected --
  -- it writes each row as it goes, so its GetFreeSlot calls do see prior
  -- placements.)
  local occupied = InventoryControllers.GetOccupiedSlotSet(inventory)
  if currentSlot ~= nil then
    occupied[tonumber(currentSlot)] = true
  end

  local function claimFreeSlot()
    for index = 0, capacity - 1 do
      if not occupied[index] then
        occupied[index] = true
        return index
      end
    end
    return nil
  end

  local placeholders = {}
  local values = {}
  for index = 1, quantity do
    if currentSlot == nil or currentSlotCount >= maxStackSize then
      currentSlot = claimFreeSlot()
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

-- Grants `quantity` of `itemName` to an inventory, enforcing the per-item
-- quantity cap, slot capacity, and weight limit (see
-- EvaluateInventoryAcceptance). Fires feather-inventory:ItemAdded once per
-- unit granted. `max_stack_size` governs only how many compartments those
-- units are spread across, never how many the inventory may hold.
ItemsAPI.AddItem = function(itemName, quantity, metadata, inventoryId)
  quantity = tonumber(quantity)
  if not quantity or quantity < 1 or quantity % 1 ~= 0 then
    warn('Invalid quantity. Must be creater than 0.')
    return {
      error = true,
      message = "Invalid quantity. Must be creater than 0."
    }
  end

  -- max_quantity/weight are read by EvaluateInventoryAcceptance itself now;
  -- only the id and stack size are needed here, for slot placement below.
  local itemId, _, _, max_stack_size = ItemControllers.GetItemByName(itemName)
  if not itemId then
    warn('Invalid itemName. Please make sure it is in the items table in your database.')
    return {
      error = true,
      message = "Invalid itemName. Please make sure it is in the items table in your database."
    }
  end
  -- Same normalization GrantItem and EvaluateInventoryAcceptance apply -- the
  -- placement loop below compares against this, so a nil would crash it.
  max_stack_size = math.max(tonumber(max_stack_size) or 1, 1)

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

  if not inventory then
    warn('Invalid inventory ID.')
    return {
      error = true,
      message = "Invalid inventory ID."
    }
  end

  -- (Capacity model unification) Quantity, slot, and weight limits are now
  -- one decision made in one place -- see EvaluateInventoryAcceptance
  -- (server/services/inventory.lua) for what each of the three checks this
  -- replaces was actually getting wrong. The headline one: the slot check
  -- here compared this inventory's total count of the item against
  -- `max_stack_size` (the per-compartment cap), so an apple with
  -- max_quantity=100 and max_stack_size=20 refused the 21st apple in the
  -- whole book rather than starting a second stack.
  local acceptance = InventoryAPI.EvaluateInventoryAcceptance(inventory, maxWeight, ignore_item_limit,
    { { item = itemName, quantity = quantity } })
  if not acceptance or acceptance.status == false then
    return {
      error = true,
      code = (acceptance and acceptance.code) or 'inventory_full',
      message = (acceptance and acceptance.message) or 'Inventory cannot hold these items.'
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
  -- (§10.4) Hoisted out of the loop, same as GrantItem above.
  local capacity = InventoryControllers.GetInventoryCapacity(inventory)
  local granted = 0

  for _ = 1, quantity do
    if currentSlot == nil or currentSlotCount >= max_stack_size then
      currentSlot = InventoryControllers.GetFreeSlot(inventory, capacity)
      currentSlotCount = 0
      if currentSlot == nil then
        warn('AddItem: ran out of free slots granting ' .. itemName .. ' to inventory ' .. tostring(inventory))
        break
      end
    end

    local item = InventoryControllers.CreateInventoryItem(inventory, itemId, currentSlot)
    currentSlotCount = currentSlotCount + 1
    granted = granted + 1

    if metadata ~= nil then
      for k, v in pairs(metadata) do
        InventoryControllers.SetMetadata(item[1].id, k, v)
      end
    end

    TriggerEvent('feather-inventory:ItemAdded', itemId, 1, inventory)
  end

  -- (Capacity model unification) The loop above can still come up short if
  -- another grant raced us between the acceptance check and here. That used
  -- to `break` and then unconditionally report `{ error = false }` -- a
  -- partial grant indistinguishable from a complete one, which any caller
  -- doing "charge the player, then AddItem" would silently under-deliver on.
  -- Report what actually landed instead.
  if granted < quantity then
    return {
      error = true,
      message = 'Inventory has no available slots.',
      granted = granted,
      requested = quantity
    }
  end

  return {
    error = false,
    granted = granted,
    requested = quantity
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
      code = updateinv.code,
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
