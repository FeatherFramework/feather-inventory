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

-- (INV-01) sourceInventory/targetInventory/items were all trusted outright
-- -- any client could pull any item out of any inventory in the database
-- by naming its raw id. The caller must now actually have access to both
-- inventories (own, or currently opened via InternalOpenInventory);
-- per-item membership in sourceInventory is enforced one layer down in
-- MoveInventoryItems itself.
Feather.RPC.Register('Feather:Inventory:UpdateInventory', function(params, res, src)
  local sourceInventory = params['sourceInventory']
  local targetInventory = params['targetInventory']
  local items = params['items']

  if type(items) ~= 'table' or #items == 0 then
    return res({ error = true, message = 'No items specified.' })
  end

  if not InventoryAPI.IsInventoryAccessibleBySrc(src, sourceInventory) then
    warn('Rejected UpdateInventory: src ' .. src .. ' does not have access to source inventory ' .. tostring(sourceInventory))
    return res({ error = true, message = 'You do not have access to that inventory.' })
  end

  if not InventoryAPI.IsInventoryAccessibleBySrc(src, targetInventory) then
    warn('Rejected UpdateInventory: src ' .. src .. ' does not have access to target inventory ' .. tostring(targetInventory))
    return res({ error = true, message = 'You do not have access to that inventory.' })
  end

  res(InventoryControllers.MoveInventoryItems(sourceInventory, targetInventory, items))
end)

-- (INV-06) Previously called res() twice -- once inside the success branch
-- and unconditionally again right after -- which double-responds the RPC
-- promise on the client. Also crashed outright (nil index on `.char`) if
-- `target` wasn't a currently-connected player with a loaded character.
-- `item` is still whatever inventory_items.id the NUI sent, but
-- MoveInventoryItems (server/controllers/inventory.lua) independently
-- verifies that id actually belongs to sourceInventory before moving it.
Feather.RPC.Register('Feather:Inventory:GiveItem', function(params, res, src)
  local target = params['target']
  local item = params['item']

  local player = Feather.Character.GetCharacter({ src = src })
  local character = player and player.char
  if not character then
    return res(false)
  end

  local targetPlayer = Feather.Character.GetCharacter({ src = tonumber(target) })
  local targetCharacter = targetPlayer and targetPlayer.char
  if not targetCharacter then
    return res(false)
  end

  -- GetInventoryByCharacter returns (id, max_weight, ignore_item_limit,
  -- name) and signals "not found" with `false`, not `nil` -- the previous
  -- `sourceInventory.id` indexing here would have errored (indexing a
  -- number/boolean) on every call, working or not.
  local sourceInventoryId = InventoryControllers.GetInventoryByCharacter(character.id)
  local destinationInventoryId = InventoryControllers.GetInventoryByCharacter(targetCharacter.id)

  if not sourceInventoryId or not destinationInventoryId then
    return res(false)
  end

  return res(InventoryControllers.MoveInventoryItems(sourceInventoryId, destinationInventoryId, { item }))
end)

-- (Steampunk ledger) Drag-and-drop placement: moves the whole compartment
-- (every row sharing the source item's slot_index -- stack splitting isn't
-- part of this design, see the design handoff) to a specific destination
-- slot, swapping with whatever's already there rather than displacing it.
-- Same ownership pattern as UpdateInventory above: both the source and
-- destination inventory must actually be accessible to the caller right
-- now, re-derived from src rather than trusted from the client.
Feather.RPC.Register('Feather:Inventory:MoveItem', function(params, res, src)
  local itemId = tonumber(params.itemId)
  local toInventory = params.toInventory
  local toSlot = tonumber(params.toSlot)
  local capacity = tonumber(Config.maxItemSlots) or 0

  if not itemId or not toInventory or toSlot == nil or toSlot < 0 or toSlot >= capacity then
    return res({ error = true, message = 'Invalid move.' })
  end

  local movingItem = InventoryControllers.GetInventoryItemById(itemId)
  if not movingItem then
    return res({ error = true, message = 'Item not found.' })
  end

  local fromInventory = movingItem.inventory_id
  local fromSlot = movingItem.slot_index

  if not InventoryAPI.IsInventoryAccessibleBySrc(src, fromInventory) then
    warn('Rejected MoveItem: src ' .. src .. ' does not have access to source inventory ' .. tostring(fromInventory))
    return res({ error = true, message = 'You do not have access to that inventory.' })
  end

  if not InventoryAPI.IsInventoryAccessibleBySrc(src, toInventory) then
    warn('Rejected MoveItem: src ' .. src .. ' does not have access to target inventory ' .. tostring(toInventory))
    return res({ error = true, message = 'You do not have access to that inventory.' })
  end

  if fromSlot == nil then
    return res({ error = true, message = 'Item is not placed anywhere yet.' })
  end

  if tostring(fromInventory) == tostring(toInventory) and tonumber(fromSlot) == toSlot then
    -- No-op drag back onto itself.
    return res({
      sourceItems = InventoryControllers.GetInventoryItems(fromInventory),
      targetItems = InventoryControllers.GetInventoryItems(toInventory)
    })
  end

  InventoryControllers.MoveSlotItems(fromInventory, fromSlot, toInventory, toSlot)

  -- Only fire the cross-resource item-left/item-arrived events (e.g.
  -- feather-weapons unequipping on ItemRemoved) when the item actually left
  -- an inventory -- rearranging compartments within the same book isn't a
  -- removal.
  if tostring(fromInventory) ~= tostring(toInventory) then
    TriggerEvent('feather-inventory:ItemRemoved', itemId, 1, fromInventory)
    TriggerEvent('feather-inventory:ItemAdded', itemId, 1, toInventory)
  end

  res({
    sourceItems = InventoryControllers.GetInventoryItems(fromInventory),
    targetItems = InventoryControllers.GetInventoryItems(toInventory)
  })
end)

-- (INV-11) Access-list management for owned/shared inventories (storage,
-- saddlebags, job lockers, ...). Authorization (owner or admin) is checked
-- inside each InventoryAPI function itself, re-derived from `src` -- these
-- RPCs are thin wrappers, not a separate trust boundary.
Feather.RPC.Register('Feather:Inventory:GrantAccess', function(params, res, src)
  res(InventoryAPI.GrantInventoryAccess(src, params.inventoryId, params.targetCharacterId))
end)

Feather.RPC.Register('Feather:Inventory:RevokeAccess', function(params, res, src)
  res(InventoryAPI.RevokeInventoryAccess(src, params.inventoryId, params.targetCharacterId))
end)

Feather.RPC.Register('Feather:Inventory:SetPublic', function(params, res, src)
  res(InventoryAPI.SetInventoryPublic(src, params.inventoryId, params.isPublic and true or false))
end)

Feather.RPC.Register('Feather:Inventory:ListAccess', function(params, res, src)
  res(InventoryAPI.ListInventoryAccess(src, params.inventoryId))
end)

Feather.RPC.Register('Feather:Inventory:GetCategories', function(params, res, src)
  res(CategoryControllers.GetCategories())
end)

Feather.RPC.Register('Feather:Inventory:GetCharacterInfoForDisplay', function(params, res, src)
  -- (Phase 6 consistency pass) No nil-guard here meant any client without a
  -- loaded character (e.g. still in character select) hitting this RPC
  -- crashed the handler on `character.dollars` instead of getting a clean
  -- empty response.
  local player = Feather.Character.GetCharacter({ src = src })
  local character = player and player.char
  if not character then
    return res({})
  end

  res({
    dollars = character.dollars,
    gold = character.gold,
    tokens = character.tokens,
    id = character.id,
    -- Steampunk ledger: the player book's subtitle is the character's name.
    firstName = character.first_name,
    lastName = character.last_name
  })
end)