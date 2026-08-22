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
    Feather.Notify.RightNotify(src, 'You do not have access to that inventory.', 3000)
    return res({ error = true, message = 'You do not have access to that inventory.' })
  end

  if not InventoryAPI.IsInventoryAccessibleBySrc(src, targetInventory) then
    warn('Rejected UpdateInventory: src ' .. src .. ' does not have access to target inventory ' .. tostring(targetInventory))
    Feather.Notify.RightNotify(src, 'You do not have access to that inventory.', 3000)
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
    Feather.Notify.RightNotify(src, result.message or 'Unable to move items.', 3000)
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
    Feather.Notify.RightNotify(src, 'That player is not available.', 3000)
    return res({ error = true, message = 'That player is not available.' })
  end

  -- (§10.1 give-distance parity) Ground pickup/drop and the robbery system
  -- both validate real distance server-side; GiveItem previously only relied
  -- on the client having aimed GetPedInFront() at someone, with nothing
  -- re-verified here. See IsWithinGiveDistance (inventory_access.lua).
  if not IsWithinGiveDistance(src, tonumber(target)) then
    warn('Rejected GiveItem: src ' .. src .. ' is not close enough to target ' .. tostring(target))
    Feather.Notify.RightNotify(src, 'You are too far away.', 3000)
    return res({ error = true, message = 'You are too far away.' })
  end

  -- GetInventoryByCharacter returns (id, max_weight, ignore_item_limit,
  -- name) and signals "not found" with `false`, not `nil` -- the previous
  -- `sourceInventory.id` indexing here would have errored (indexing a
  -- number/boolean) on every call, working or not.
  local sourceInventoryId = InventoryControllers.GetInventoryByCharacter(character.id)
  local destinationInventoryId = InventoryControllers.GetInventoryByCharacter(targetCharacter.id)

  if not sourceInventoryId or not destinationInventoryId then
    Feather.Notify.RightNotify(src, 'Inventory not available.', 3000)
    return res({ error = true, message = 'Inventory not available.' })
  end

  local giveResult = InventoryControllers.MoveInventoryItems(sourceInventoryId, destinationInventoryId, { item })
  if giveResult and giveResult.error then
    Feather.Notify.RightNotify(src, giveResult.message or 'Unable to give item.', 3000)
  end
  return res(giveResult)
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
    Feather.Notify.RightNotify(src, 'You do not have access to that inventory.', 3000)
    return res({ error = true, message = 'You do not have access to that inventory.' })
  end

  if not InventoryAPI.IsInventoryAccessibleBySrc(src, toInventory) then
    warn('Rejected MoveItem: src ' .. src .. ' does not have access to target inventory ' .. tostring(toInventory))
    Feather.Notify.RightNotify(src, 'You do not have access to that inventory.', 3000)
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

  -- (§6/§10.1 MoveItem weight/capacity bypass) Every other movement path
  -- (UpdateInventory, GiveItem, DropItemsOnGround) enforces capacity/weight/
  -- restricted-item limits via MoveInventoryItems -> InventoryCanHoldById
  -- (INV-14); this drag-and-drop path never did. Only the empty-destination
  -- case is checked here -- a swap into an already-occupied slot in a
  -- *different* inventory is deliberately left unchecked for now.
  -- InventoryCanHoldById's "add this on top of the inventory's current
  -- total" math would double-count the item that's simultaneously leaving
  -- fromInventory to make room for the swap; doing that correctly needs a
  -- net-delta calculation (post-swap totals on both sides), not a bolt-on
  -- reuse of a helper built for pure additions. Scoped down deliberately --
  -- see MASTER_PLAN.md §6/§10.1 -- rather than shipping subtly-wrong swap
  -- math under time pressure. The empty-slot case is also the wide-open,
  -- high-frequency one: any drag onto free space in another inventory
  -- previously had zero enforcement at all.
  if tostring(fromInventory) ~= tostring(toInventory) then
    local occupantRows = InventoryControllers.GetItemsInSlot(toInventory, toSlot)
    if #occupantRows == 0 then
      local movingRows = InventoryControllers.GetItemsInSlot(fromInventory, fromSlot)
      local canHoldTarget = InventoryAPI.InventoryCanHoldById({ { item = movingItem.name, quantity = #movingRows } }, toInventory)
      if not canHoldTarget or canHoldTarget.status == false then
        local rejectMessage = (canHoldTarget and canHoldTarget.message) or 'Target inventory cannot hold this item.'
        warn('Rejected MoveItem: src ' .. src .. ' -- target inventory ' .. tostring(toInventory) .. ' cannot hold item ' .. tostring(movingItem.name))
        Feather.Notify.RightNotify(src, rejectMessage, 3000)
        return res({ error = true, message = rejectMessage })
      end
    end
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