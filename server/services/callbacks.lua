Feather.RPC.Register('Feather:Inventory:GetInventoryItems', function(params, res, src)
  local otherInventoryId = params['otherInventoryId']

  res(InventoryAPI.OpenInventory(src, otherInventoryId))
end)

Feather.RPC.Register('Feather:Inventory:OpenInventory', function(params, res, src)
  local otherInventoryId = params['otherInventoryId']
  TriggerClientEvent('Feather:Inventory:OpenInventory', src, otherInventoryId)
end)

Feather.RPC.Register('Feather:Inventory:CloseInventory', function(params, res, src)
  TriggerClientEvent('Feather:Inventory:CloseInventory', src)
  res(InventoryAPI.Close(src))
end)

-- Called when player uses item from their inventory. Close Inventory after use.
Feather.RPC.Register('Feather:Inventory:UseItem', function(params, res, src)
  local itemId = params['itemId']
  local itemName = params['itemName']

  res(ItemsAPI.UseItem(itemName, itemId, src))
end)

Feather.RPC.Register('Feather:Inventory:UpdateInventory', function(params, res, src)
  local sourceInventory = params['sourceInventory']
  local targetInventory = params['targetInventory']
  local items = params['items']

  res(MoveInventoryItems(sourceInventory, targetInventory, items))
end)

Feather.RPC.Register('Feather:Inventory:GiveItem', function(params, res, src)
  local target = params['target']
  local item = params['item']

  local player = Feather.Character.getCharacterBySrc(src)
  local sourceInventory = GetInventoryByCharacter(player.id)
  local targetPlayer = Feather.Character.getCharacterBySrc(tonumber(target))
  local destinationInventory = GetInventoryByCharacter(targetPlayer.id)

  if sourceInventory ~= nil and destinationInventory ~= nil then
    res(ItemsAPI.MoveInventoryItems(sourceInventory.id, destinationInventory.id, { item }))
  end

  res(false)
end)
