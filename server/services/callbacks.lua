Feather.RPC.Register('Inventory:GetPlayerItems', function(params, res, src)
  local inventoryId = params.inventoryId
  local inventory, maxWeight, ignore_item_limit = GetInventory(inventoryId)

  if not inventory then
    error('Invalid Inventory ID')
  end

  local items = GetInventoryItems(inventory)

  for index, item in pairs(items) do
    local metadata = GetMetadata(item.id)
    items[index].metadata = metadata
  end

  res(items)
end)

-- Called when player uses item from their inventory. Close Inventory after use.
Feather.RPC.Register('Inventory:UseItem', function(params, res, src)
  local itemId = params['itemId']
  local itemName = params['itemName']
  local itemQuanity = params['itemQuanity']

  if itemQuanity == nil then itemQuanity = 1 end

  local item = GetInventoryItemById(itemId)

  -- Execute code for item use

  res(true)
end)

Feather.RPC.Register('Inventory:UpdateInventory', function(params, res, src)
  local sourceInventory = params['sourceInventory']
  local destinationInventory = params['destinationInventory']
  local sourceSlot = params['sourceSlot']
  local destinationSlot = params['destinationSlot']
  local quantity = params['quantity']

  -- Update Database
  res(true)
end)
