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
    Feather.Notify.RightNotify(src, Translate(src, 'err_no_access', 'You do not have access to that inventory.'), 3000)
    return res({ error = true, message = 'You do not have access to that inventory.' })
  end

  if not InventoryAPI.IsInventoryAccessibleBySrc(src, targetInventory) then
    warn('Rejected UpdateInventory: src ' .. src .. ' does not have access to target inventory ' .. tostring(targetInventory))
    Feather.Notify.RightNotify(src, Translate(src, 'err_no_access', 'You do not have access to that inventory.'), 3000)
    return res({ error = true, message = 'You do not have access to that inventory.' })
  end

  -- (§10.1 rejection-surfacing) MoveInventoryItems already returns a real
  -- {error, message} on capacity/weight/restricted-item rejection (INV-14)
  -- -- it just never reached the player. The NUI only ever logged it to the
  -- browser devtools console (see App.vue's onDrop), which nobody sees
  -- in-game. Reusing Feather.Notify.RightNotify the same way this file's
  -- other rejection paths already do.
  local result = InventoryControllers.MoveInventoryItems(sourceInventory, targetInventory, items)
  if result and result.error then
    Feather.Notify.RightNotify(src, TranslateResult(src, result, 'err_move_failed'), 3000)
  end
  res(result)
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
    return res({ error = true, message = 'No character loaded.' })
  end

  local targetPlayer = Feather.Character.GetCharacter({ src = tonumber(target) })
  local targetCharacter = targetPlayer and targetPlayer.char
  if not targetCharacter then
    Feather.Notify.RightNotify(src, Translate(src, 'err_target_unavailable', 'That player is not available.'), 3000)
    return res({ error = true, message = 'That player is not available.' })
  end

  -- (§10.1 give-distance parity) Ground pickup/drop and the robbery system
  -- both validate real distance server-side; GiveItem previously only relied
  -- on the client having aimed GetPedInFront() at someone, with nothing
  -- re-verified here. See IsWithinGiveDistance (inventory_access.lua).
  if not IsWithinGiveDistance(src, tonumber(target)) then
    warn('Rejected GiveItem: src ' .. src .. ' is not close enough to target ' .. tostring(target))
    Feather.Notify.RightNotify(src, Translate(src, 'err_too_far', 'You are too far away.'), 3000)
    return res({ error = true, message = 'You are too far away.' })
  end

  -- GetInventoryByCharacter returns (id, max_weight, ignore_item_limit,
  -- name) and signals "not found" with `false`, not `nil` -- the previous
  -- `sourceInventory.id` indexing here would have errored (indexing a
  -- number/boolean) on every call, working or not.
  local sourceInventoryId = InventoryControllers.GetInventoryByCharacter(character.id)
  local destinationInventoryId = InventoryControllers.GetInventoryByCharacter(targetCharacter.id)

  if not sourceInventoryId or not destinationInventoryId then
    Feather.Notify.RightNotify(src, Translate(src, 'err_invalid_inventory', 'Inventory not available.'), 3000)
    return res({ error = true, message = 'Inventory not available.' })
  end

  local giveResult = InventoryControllers.MoveInventoryItems(sourceInventoryId, destinationInventoryId, { item })
  if giveResult and giveResult.error then
    Feather.Notify.RightNotify(src, TranslateResult(src, giveResult, 'err_give_failed'), 3000)
  end
  return res(giveResult)
end)

-- (Steampunk ledger) Drag-and-drop placement: moves the whole compartment
-- (every row sharing the source item's slot_index) to a specific destination
-- slot, swapping with whatever's already there rather than displacing it.
-- Dragging is deliberately all-or-nothing; peeling part of a stack off is
-- the separate SplitStack RPC below.
-- Same ownership pattern as UpdateInventory above: both the source and
-- destination inventory must actually be accessible to the caller right
-- now, re-derived from src rather than trusted from the client.
Feather.RPC.Register('Feather:Inventory:MoveItem', function(params, res, src)
  local itemId = tonumber(params.itemId)
  local toInventory = params.toInventory
  local toSlot = tonumber(params.toSlot)

  if not itemId or not toInventory or toSlot == nil or toSlot < 0 then
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
    Feather.Notify.RightNotify(src, Translate(src, 'err_no_access', 'You do not have access to that inventory.'), 3000)
    return res({ error = true, message = 'You do not have access to that inventory.' })
  end

  if not InventoryAPI.IsInventoryAccessibleBySrc(src, toInventory) then
    warn('Rejected MoveItem: src ' .. src .. ' does not have access to target inventory ' .. tostring(toInventory))
    Feather.Notify.RightNotify(src, Translate(src, 'err_no_access', 'You do not have access to that inventory.'), 3000)
    return res({ error = true, message = 'You do not have access to that inventory.' })
  end

  -- (§10.4) The upper bound is the destination inventory's own capacity, not
  -- one global constant -- a 60-slot wagon must accept slot 40 while a
  -- 25-slot book must still reject it. Checked after the access checks
  -- rather than alongside the cheap shape validation above, so an
  -- unauthorized caller can't probe an arbitrary inventory's size.
  local capacity = InventoryControllers.GetInventoryCapacity(toInventory)
  if toSlot >= capacity then
    return res({ error = true, message = 'Invalid move.' })
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

  -- (§6/§10.1 MoveItem weight/capacity bypass -- now closed for both cases)
  -- Every other movement path (UpdateInventory, GiveItem, DropItemsOnGround)
  -- enforces weight/quantity/restricted-item limits via MoveInventoryItems ->
  -- InventoryCanHoldById (INV-14); this drag-and-drop path never did.
  --
  -- The first pass could only close the empty-destination half, because it
  -- reused InventoryCanHoldById -- an addition-only check, which double-counts
  -- the stack simultaneously leaving fromInventory to make room for a swap.
  -- EvaluateSlotMove replaces it with real net-delta math evaluated on both
  -- inventories ((current - leaving) + arriving), which closes the swap case
  -- and subsumes the empty-slot one as the degenerate "nothing is leaving"
  -- form of the same calculation.
  local canMove = InventoryAPI.EvaluateSlotMove(fromInventory, fromSlot, toInventory, toSlot)
  if not canMove or canMove.status == false then
    local rejectMessage = (canMove and canMove.message) or 'Target inventory cannot hold this item.'
    warn('Rejected MoveItem: src ' .. src .. ' -- ' .. tostring(rejectMessage) ..
      ' (from inventory ' .. tostring(fromInventory) .. ' slot ' .. tostring(fromSlot) ..
      ' to inventory ' .. tostring(toInventory) .. ' slot ' .. tostring(toSlot) .. ')')
    Feather.Notify.RightNotify(src, TranslateResult(src, canMove, 'err_move_failed'), 3000)
    return res({ error = true, message = rejectMessage })
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

-- (§10.1 split stack) The ledger otherwise only ever moves a whole
-- compartment (MoveSlotItems, via MoveItem above); this peels part of one
-- into a free compartment in the same inventory, which is what the design's
-- existing quantity modal was already shaped for.
--
-- Same-inventory only, and that keeps it simple: nothing enters or leaves
-- the inventory, so there is no weight/quantity/blacklist question to ask
-- and no ItemAdded/ItemRemoved to fire (same reasoning as MoveItem's
-- in-place rearrangement branch). The only real constraint is a free
-- compartment to split into. Ownership is re-derived from the item's own
-- row, never from the client -- same pattern as MoveItem.
Feather.RPC.Register('Feather:Inventory:SplitStack', function(params, res, src)
  local itemId = tonumber(params.itemId)
  local quantity = tonumber(params.quantity)

  if not itemId or not quantity or quantity < 1 or quantity % 1 ~= 0 then
    return res({ error = true, message = 'Invalid split.' })
  end

  local item = InventoryControllers.GetInventoryItemById(itemId)
  if not item then
    return res({ error = true, message = 'Item not found.' })
  end

  local inventory = item.inventory_id
  local fromSlot = item.slot_index
  if fromSlot == nil then
    return res({ error = true, message = 'Item is not placed anywhere yet.' })
  end

  if not InventoryAPI.IsInventoryAccessibleBySrc(src, inventory) then
    warn('Rejected SplitStack: src ' .. src .. ' does not have access to inventory ' .. tostring(inventory))
    Feather.Notify.RightNotify(src, Translate(src, 'err_no_access', 'You do not have access to that inventory.'), 3000)
    return res({ error = true, message = 'You do not have access to that inventory.' })
  end

  -- Splitting off the whole stack would just relocate it and leave an empty
  -- compartment behind -- that's a move, which MoveItem already does.
  local stack = InventoryControllers.GetItemsInSlot(inventory, fromSlot)
  if quantity >= #stack then
    Feather.Notify.RightNotify(src, Translate(src, 'err_split_whole_stack', 'Choose fewer than the whole stack.'), 3000)
    return res({ error = true, message = 'Choose fewer than the whole stack.' })
  end

  local freeSlot = InventoryControllers.GetFreeSlot(inventory, InventoryControllers.GetInventoryCapacity(inventory))
  if freeSlot == nil then
    Feather.Notify.RightNotify(src, Translate(src, 'err_no_free_compartment', 'No free compartment to split into.'), 3000)
    return res({ error = true, message = 'No free compartment to split into.' })
  end

  InventoryControllers.SplitSlotItems(inventory, fromSlot, freeSlot, quantity)

  res({
    sourceItems = InventoryControllers.GetInventoryItems(inventory),
    targetItems = InventoryControllers.GetInventoryItems(inventory)
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

-- (Debug gate) "Uncategorized" is where an item ends up when nobody's
-- assigned it a real category yet -- useful for a server owner to notice
-- and go fix in the DB, not something a player needs a tab for. Hidden
-- from the returned list unless Config.DevMode is on; items in it still
-- show up under ALL either way (filtering there is by category_id, not by
-- whether a tab exists for it), so nothing is actually hidden from play,
-- just from the tab row.
Feather.RPC.Register('Feather:Inventory:GetCategories', function(params, res, src)
  local categories = CategoryControllers.GetCategories()
  if Config.DevMode then
    return res(categories)
  end

  local filtered = {}
  for _, category in pairs(categories) do
    if string.lower(category.name or '') ~= 'uncategorized' then
      table.insert(filtered, category)
    end
  end
  res(filtered)
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