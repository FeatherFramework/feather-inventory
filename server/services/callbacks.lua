Feather.RPC.Register('Feather:Inventory:GetInventoryItems', function(params, res, src)
  local otherInventoryId = params['otherInventoryId']

  res(InventoryAPI.InternalOpenInventory(src, otherInventoryId))
end)

Feather.RPC.Register('Feather:Inventory:Server:CloseInventory', function(params, res, src)
  InventoryAPI.InternalCloseInventory(src)
end)

-- Called when player uses item from their inventory. Close Inventory after use.
Feather.RPC.Register('Feather:Inventory:UseItem', function(params, res, src)
  local itemId = params['itemId']
  res(ItemsAPI.UseItem(itemId, src))
end)

Feather.RPC.Register('Feather:Inventory:UpdateInventory', function(params, res, src)
  local sourceInventory = params['sourceInventory']
  local targetInventory = params['targetInventory']
  local items = params['items']

  res(InventoryControllers.MoveInventoryItems(sourceInventory, targetInventory, items))
end)

Feather.RPC.Register('Feather:Inventory:GiveItem', function(params, res, src)
  local target = params['target']
  local item = params['item']

  local player = Feather.Character.GetCharacter({ src = src })
  local character = player.char 

  local sourceInventory = InventoryControllers.GetInventoryByCharacter(character.id)

  local targetPlayer = Feather.Character.GetCharacter({ src = tonumber(target) })
  local targerCharacter = targetPlayer.char
  local destinationInventory = InventoryControllers.GetInventoryByCharacter(targerCharacter.id)

  if sourceInventory ~= nil and destinationInventory ~= nil then
    res(InventoryControllers.MoveInventoryItems(sourceInventory.id, destinationInventory.id, { item }))
  end

  res(false)
end)

Feather.RPC.Register('Feather:Inventory:GetCategories', function(params, res, src)
  res(CategoryControllers.GetCategories())
end)

Feather.RPC.Register('Feather:Inventory:GetCharacterInfoForDisplay', function(params, res, src)
  local player = Feather.Character.GetCharacter({ src = src })
  local character = player.char

  res({
    dollars = character.dollars,
    gold = character.gold,
    tokens = character.tokens,
    id = character.id
  })
end)