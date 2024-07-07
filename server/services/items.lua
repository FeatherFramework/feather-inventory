--TODO: Replace errors with the core notifies

ItemsAPI = {}
UsableItemCallbacks = {}

ItemsAPI.AddItem = function(itemName, quantity, metadata, inventoryId)
  if quantity < 1 then
    error('Invalid quantity. Must be creater than 0.')
    return {
      error = true,
      message = "Invalid quantity. Must be creater than 0."
    }
  end

  local itemId, max_quantity, _, max_stack_size = ItemControllers.GetItemByName(itemName)
  if not itemId then
    error('Invalid itemName. Please make sure it is in the items table in your database.')
    return {
      error = true,
      message = "Invalid itemName. Please make sure it is in the items table in your database."
    }
  end

  --TODO: Add a check for weight (this will be supported at another date. V1 will only support slots and stack sizes)

  local ItemCount = ItemsAPI.GetItemCount(itemName, inventoryId)

  -- Check to make sure this doesnt exceed the amount of slots available.
  if (ItemCount + quantity) / max_stack_size > max_stack_size then
    return {
      error = true,
      message = "Max slots reached"
    }
  end


  local inventory, _, ignore_item_limit = nil, nil, nil
  if tonumber(inventoryId) then
    local player = Feather.Character.GetCharacter({ src = inventoryId })
    local character = player.char

    inventory, _, ignore_item_limit, _ = InventoryControllers.GetInventoryByCharacter(character.id)
  else
    inventory, _, ignore_item_limit, _ = InventoryControllers.GetInventoryById(inventoryId)
  end

  -- Check to make sure this doesnt exceed the max quantity for this item.
  if ItemCount + quantity >= max_quantity and ignore_item_limit == 0 then
    return {
      error = true,
      message = "Too Many Items in Inventory"
    }
  end

  if not inventory then
    error('Invalid inventory ID.')
    return {
      error = true,
      message = "Invalid inventory ID."
    }
  end

  if metadata ~= nil and type(metadata) ~= 'table' then
    error(
      "Invalid format for meta data. Meta data must be a table of key value pairs. Example: { quality = 'poor', durability = 50, maxDurability = 100 }")
    return {
      error = true,
      message =
      "Invalid format for meta data. Meta data must be a table of key value pairs. Example: { quality = 'poor', durability = 50, maxDurability = 100 }"
    }
  end

  for count = 1, quantity do
    local item = InventoryControllers.CreateInventoryItem(inventory, itemId)

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
ItemsAPI.RemoveItemByName = function(itemName, quantity, inventoryId, src)
  if quantity < 1 then
    error('Invalid quantity. Must be creater than 0.')
    return {
      error = true,
      message = "Invalid quantity. Must be creater than 0."
    }
  end

  local itemId, _, _ = ItemControllers.GetItemByName(itemName)
  if not itemId then
    error('Invalid itemName. Please make sure it is in the items table in your database.')
    return {
      error = true,
      message = "Invalid itemName. Please make sure it is in the items table in your database."
    }
  end

  local inventory, _, _ = nil, nil, nil
  if tonumber(inventoryId) then
    local player = Feather.Character.GetCharacter({ src = inventoryId })
    local character = player.char

    inventory, _, _ = InventoryControllers.GetInventoryByCharacter(character.id)
  else
    inventory, _, _ = InventoryControllers.GetInventoryById(inventoryId)
  end
  if not inventory then
    error('Invalid inventory ID.')
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

  TriggerEvent('feather-inventory:ItemRemoved', itemId, quantity, inventoryId)

  InventoryControllers.DeleteInventoryItems(inventory.id, itemId, quantity)
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
    error('Item ID is required.')
    return {
      error = true,
      message = "Item ID is required."
    }
  end
  if metadata == nil or type(metadata) ~= 'table' then
    error(
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
    error('Invalid itemName. Please make sure it is in the items table in your database.')
    return -1
  end

  local inventory, _, _ = nil, nil, nil
  if tonumber(inventoryId) then
    local player = Feather.Character.GetCharacter({ src = inventoryId })
    local character = player.char

    inventory, _, _ = InventoryControllers.GetInventoryByCharacter(character.id)
  else
    inventory, _, _ = InventoryControllers.GetInventoryById(inventoryId)
  end
  if not inventory == nil then
    error('Invalid inventory ID.')
    return -1
  end

  local itemCount = InventoryControllers.InventoryItemCount(inventory, itemId)

  return itemCount
end

ItemsAPI.ItemExists = function(itemName)
  local itemId, _, _ = ItemControllers.GetItemByName(itemName)
  if itemId then
    return false
  end
  return true
end

ItemsAPI.InventoryHasItems = function(items, inventoryId)
  local numberOfItems = #items
  local count = 0

  local inventory, _, _ = nil, nil, nil
  if tonumber(inventoryId) then
    local player = Feather.Character.GetCharacter({ src = inventoryId })
    local character = player.char
    inventory, _, _ = InventoryControllers.GetInventoryByCharacter(character.id)
  else
    inventory, _, _ = InventoryControllers.GetInventoryById(inventoryId)
  end
  local playerItems = InventoryControllers.InventoryItemCounts(inventory)

  -- Error Checks
  if not IsTable(items) then
    error('items must be a table! e.g. {{name = "apple", quantity = 2}, {name = "lemon", quantity = 1}}')
    return false
  end

  for _, v in pairs(items) do
    if not IsTable(v) then
      error('items must be a table! e.g. {{name = "apple", quantity = 2}, {name = "lemon", quantity = 1}}')
      return false
    end

    if v.name == nil or tonumber(v.quantity) == nil then
      error('items must be a table! e.g. {{name = "apple", quantity = 2}, {name = "lemon", quantity = 1}}')
      return false
    end
  end

  for _, playerItem in pairs(playerItems) do
    for _, requestedItem in pairs(items) do
      if playerItem and requestedItem.name == playerItem.name and tonumber(playerItem['COUNT[`items`.`name`]']) >= tonumber(requestedItem.quantity) then
        count = count + 1
      end
    end
  end

  return count < numberOfItems
end

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
    error('Item not found in the database! ItemID: ' .. itemID)
  end
  if tonumber(src) == nil then
    error('Invalid Player Source')
  end

  -- local player = Feather.Character.GetCharacter({ src = src })
  -- local character = player.char
  -- local inventory, _, _ = InventoryControllers.GetInventoryByCharacter(character.id)
  -- if tonumber(inventory) == nil then
  --   error('Inventory ID is required.')
  --   return nil
  -- end

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
  -- TODO: Add check to make sure items are all the same "item". If not then do different logic.
  local item = InventoryControllers.GetInventoryItemById(items[1].id)
  if not item then
    warn('Item not found in the database! Item ID: ' .. items[1].id)
    return {
      error = true,
      message = 'Item not found in the database!'
    }
  end

  local ItemCount = ItemsAPI.GetItemCount(item.name, inventoryId)
  if (ItemCount - #items) < 0 then
    warn('Attempting to drop more items than available. Item Name: ' .. item.name)
    return {
      error = true,
      message = 'Attempting to drop more items than available.'
    }
  end

  local groundID = GroundControllers.GetClosestGroundByCoords(x, y, z, Config.groundGroupingRadius)
  
  -- No nearby ground, lets create a new one
  if groundID == nil or groundID == 'nil' then
    groundID = GroundControllers.CreateGround(x, y, z)[1].id
  end

  local _, groundInventoryID = InventoryAPI.RegisterInventory('ground', groundID, 'Ground')
  local updateinv = InventoryControllers.MoveInventoryItems(inventoryId, groundInventoryID, items)

  UpdateClientWithGroundLocations(-1)

  return {
    error = false,
    inv = updateinv
  }
end
