Feather.RPC.Register('Inventory:GetPlayerItems', function(params, res, player)
  local inventoryId = params.inventoryId
  local inventory = GetInventory(inventoryId)
  local items = MySQL.query.await(
    'SELECT `inventory_items`.`id`, `items`.`name` FROM `inventory_items` INNER JOIN `items` ON `inventory_items`.`item_id`=`items`.`id` WHERE `inventory_items`.`inventory_id`=?;',
    { inventory })

  for index, item in pairs(items) do
    local metadata = MySQL.query.await('SELECT `key`, `value` FROM `item_metadata` WHERE `inventory_items_id`=?', item
      .id)
    items[index].metadata = metadata
  end

  res(items)
end)

Feather.RPC.Register('Inventory:UseItem', function(params, res, player)
  local itemSlot = params['itemSlot']
  local itemName = params['itemName']
  local itemQuanity = params['itemQuanity']

  if itemQuanity == nil then itemQuanity = 1 end

  if itemSlot ~= nil then
    -- Get item in slot and use it
  else
    -- Get item by name and use it
  end

  res(true)
end)

Feather.RPC.Register('Inventory:UpdateInventory', function(params, res, player)
  local sourceInventory = params['sourceInventory']
  local destinationInventory = params['destinationInventory']
  local sourceSlot = params['sourceSlot']
  local destinationSlot = params['destinationSlot']
  local quantity = params['quantity']

  -- Update Database
  res(true)
end)

Feather.RPC.Register('Inventory:GiveItem', function(params, res, player)
  local playerServerId = params['playerServerId']
  local itemName = params['itemName']
  local quantity = params['quantity']
  local itemSlot = params['itemSlot']

  res(true)
end)
