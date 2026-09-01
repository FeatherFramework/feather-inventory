Feather.RPC.Register('Feather:Inventory:GetInventoryItems', function(params, res, src)
  local otherInventoryId = params['otherInventoryId']

  -- The NUI payload keeps its own shape; the envelope is unwrapped at this
  -- boundary rather than pushed into the Vue app.
  local opened = InventoryAPI.InternalOpenInventory(src, otherInventoryId)
  if not Result.IsOk(opened) then
    return res({ error = opened.error.message, errorCode = opened.error.code })
  end
  res(opened.value)
end)

Feather.RPC.Register('Feather:Inventory:Server:CloseInventory', function(params, res, src)
  InventoryAPI.InternalCloseInventory(src)
end)

-- Called when player uses item from their inventory. Close Inventory after use.
Feather.RPC.Register('Feather:Inventory:UseItem', function(params, res, src)
  local itemId = params['itemId']
  local used = ItemsAPI.UseItem(itemId, src)
  if not Result.IsOk(used) and Config.DevMode then
    print(('[feather-inventory] DevMode UseItem failure: %s'):format(json.encode(used.error)))
  end
  res(Result.IsOk(used) and { error = false } or {
    error = true,
    code = used.error.code,
    message = used.error.message,
    details = used.error.details,
  })
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

  if not InventoryAPI.Accessible(src, sourceInventory) then
    warn('Rejected UpdateInventory: src ' .. src .. ' does not have access to source inventory ' .. tostring(sourceInventory))
    Feather.Notify.RightNotify(src, Translate(src, 'err_no_access', 'You do not have access to that inventory.'), 3000)
    return res({ error = true, message = 'You do not have access to that inventory.' })
  end

  if not InventoryAPI.Accessible(src, targetInventory) then
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
  local player = InventoryIdentity.GetCharacter(src)
  local character = player and player.char
  local result = InventoryControllers.MoveInventoryItems(sourceInventory, targetInventory, items, {
    actorSource = src,
    actorCharacterId = character and character.id,
    reason = 'inventory_transfer',
    resource = 'feather-inventory'
  })
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

  local player = InventoryIdentity.GetCharacter(src)
  local character = player and player.char
  if not character then
    return res({ error = true, message = 'No character loaded.' })
  end

  local targetPlayer = InventoryIdentity.GetCharacter(tonumber(target))
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

  local giveResult = InventoryControllers.MoveInventoryItems(sourceInventoryId, destinationInventoryId, { item }, {
    actorSource = src,
    actorCharacterId = character.id,
    reason = 'give',
    resource = 'feather-inventory',
    -- Proximity authorizes this specific deposit without granting the giver
    -- general access to the recipient's inventory.
    allowTargetInsert = true
  })
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

  if not InventoryAPI.Accessible(src, fromInventory) then
    warn('Rejected MoveItem: src ' .. src .. ' does not have access to source inventory ' .. tostring(fromInventory))
    Feather.Notify.RightNotify(src, Translate(src, 'err_no_access', 'You do not have access to that inventory.'), 3000)
    return res({ error = true, message = 'You do not have access to that inventory.' })
  end

  if not InventoryAPI.Accessible(src, toInventory) then
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

  -- (Stack merge) Dropping a stack onto another stack of the SAME item tops
  -- it up rather than swapping the two compartments. Without this there was
  -- no way to recombine stacks at all -- split was one-way, and any drag
  -- onto a matching stack just traded their positions.
  --
  -- Only a single-definition compartment on each side can merge; a mixed
  -- slot (not producible through normal play, but not forbidden by the
  -- schema either) falls through to the swap path rather than guessing.
  local movingBreakdown = InventoryControllers.GetSlotItemBreakdown(fromInventory, fromSlot)
  local occupantBreakdown = InventoryControllers.GetSlotItemBreakdown(toInventory, toSlot)
  local mergeCount = 0

  if #movingBreakdown == 1 and #occupantBreakdown == 1
      and tostring(movingBreakdown[1].item_id) == tostring(occupantBreakdown[1].item_id)
      and InventoryControllers.AreSlotsStackCompatible(fromInventory, fromSlot, toInventory, toSlot) then
    local stackSize = math.max(tonumber(occupantBreakdown[1].max_stack_size) or 1, 1)
    local room = stackSize - (tonumber(occupantBreakdown[1].count) or 0)
    if room > 0 then
      mergeCount = math.min(tonumber(movingBreakdown[1].count) or 0, room)
    end
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
  --
  -- A merge needs different math from a swap: EvaluateSlotMove assumes the
  -- occupant vacates to make room, but in a merge it stays put. Validating a
  -- merge with swap math would credit the destination for weight that never
  -- leaves it. Within one inventory nothing changes hands at all, so only a
  -- cross-inventory merge needs checking, as a pure addition of the units
  -- actually moving.
  local canMove
  if mergeCount > 0 then
    if tostring(fromInventory) ~= tostring(toInventory) then
      local _, toMaxWeight, toIgnoreLimit = InventoryControllers.GetInventoryById(toInventory, 'id')
      canMove = InventoryAPI.EvaluateInventoryAcceptance(toInventory, toMaxWeight, toIgnoreLimit,
        { { item = movingBreakdown[1].name, quantity = mergeCount } })
    else
      canMove = Result.Ok({ accepted = true, message = '' })
    end
  else
    canMove = InventoryAPI.EvaluateSlotMove(fromInventory, fromSlot, toInventory, toSlot)
  end

  if not Result.IsOk(canMove) or canMove.value.accepted == false then
    local failure = Result.IsOk(canMove) and canMove.value or canMove.error
    local rejectMessage = (failure and failure.message) or 'Target inventory cannot hold this item.'
    warn('Rejected MoveItem: src ' .. src .. ' -- ' .. tostring(rejectMessage) ..
      ' (from inventory ' .. tostring(fromInventory) .. ' slot ' .. tostring(fromSlot) ..
      ' to inventory ' .. tostring(toInventory) .. ' slot ' .. tostring(toSlot) .. ')')
    Feather.Notify.RightNotify(src, TranslateResult(src, canMove, 'err_move_failed'), 3000)
    return res({ error = true, message = rejectMessage })
  end

  if mergeCount > 0 then
    -- Only the units that fit move; any remainder stays where it was, so
    -- dragging 15 onto a stack with room for 5 tops it up and leaves 10
    -- behind rather than silently overfilling past max_stack_size.
    --
    -- The merge path announces its own movement. Every other route emits
    -- ItemMoved from inside the controller that performs it, but
    -- MoveSlotItemsPartial had no emit at all -- for as long as the legacy
    -- ItemAdded/ItemRemoved pair existed here, that gap was invisible,
    -- because those two were firing in its place. Removing them surfaced it.
    local player = InventoryIdentity.GetCharacter(src)
    local character = player and player.char
    local merged = InventoryControllers.MoveSlotItemsPartial(
      fromInventory, fromSlot, toInventory, toSlot, mergeCount, {
        actorSource = src,
        actorCharacterId = character and character.id,
        reason = 'slot_merge',
        resource = 'feather-inventory'
      })
    if merged < 1 then
      Feather.Notify.RightNotify(src, Translate(src, 'err_move_failed', 'The inventory changed; try again.'), 3000)
      return res({ error = true, code = 'conflict', message = 'The inventory changed; try again.' })
    end
  else
    -- MoveSlotItems emits ItemMoved itself, post-commit, and only when the
    -- item actually changed inventory.
    local player = InventoryIdentity.GetCharacter(src)
    local character = player and player.char
    local moved, code, message = InventoryControllers.MoveSlotItems(fromInventory, fromSlot, toInventory, toSlot, {
      actorSource = src,
      actorCharacterId = character and character.id,
      reason = 'slot_move',
      resource = 'feather-inventory'
    })
    if not moved then
      local failure = { error = true, code = code or 'conflict', message = message or 'The inventory changed; try again.' }
      Feather.Notify.RightNotify(src, TranslateResult(src, failure, 'err_move_failed'), 3000)
      return res(failure)
    end
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

  if not InventoryAPI.Accessible(src, inventory) then
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

  local player = InventoryIdentity.GetCharacter(src)
  local character = player and player.char
  local moved = InventoryControllers.SplitSlotItems(inventory, fromSlot, freeSlot, quantity, {
    actorSource = src,
    actorCharacterId = character and character.id,
    reason = 'split_stack',
    resource = 'feather-inventory'
  })
  if moved ~= quantity then
    Feather.Notify.RightNotify(src, Translate(src, 'err_move_failed', 'The inventory changed; try again.'), 3000)
    return res({ error = true, code = 'conflict', message = 'The inventory changed; try again.' })
  end

  res({
    sourceItems = InventoryControllers.GetInventoryItems(inventory),
    targetItems = InventoryControllers.GetInventoryItems(inventory)
  })
end)

-- (§10.3 quick-loot) Moves everything from one inventory into the caller's
-- own, respecting capacity.
--
-- Deliberately GREEDY rather than all-or-nothing, which is why it isn't just
-- UpdateInventory with every id: MoveInventoryItems capacity-checks the whole
-- batch and rejects it entirely if the lot won't fit, so "take all" from a
-- pile larger than your remaining room would take nothing at all. Here each
-- item is attempted independently and failures are skipped -- a heavy item
-- that doesn't fit must not block the lighter ones behind it.
--
-- Reports how many actually moved so the UI can tell "took everything" from
-- "took what fit", rather than both looking like success.
Feather.RPC.Register('Feather:Inventory:TakeAll', function(params, res, src)
  local fromInventory = params.fromInventory

  if not fromInventory then
    return res({ error = true, message = 'Invalid inventory.' })
  end

  local player = InventoryIdentity.GetCharacter(src)
  local character = player and player.char
  if not character then
    return res({ error = true, code = 'no_character', message = 'No character loaded.' })
  end

  local targetInventory = InventoryControllers.GetInventoryByCharacter(character.id)
  if not targetInventory then
    Feather.Notify.RightNotify(src, Translate(src, 'err_invalid_inventory', 'Inventory not available.'), 3000)
    return res({ error = true, code = 'invalid_inventory', message = 'Inventory not available.' })
  end

  -- Same ownership rule as every other movement path: re-derived from src,
  -- never trusted from the client, and re-checked here rather than relying on
  -- the inventory merely being open.
  if not InventoryAPI.Accessible(src, fromInventory) then
    warn('Rejected TakeAll: src ' .. src .. ' does not have access to inventory ' .. tostring(fromInventory))
    Feather.Notify.RightNotify(src, Translate(src, 'err_no_access', 'You do not have access to that inventory.'), 3000)
    return res({ error = true, code = 'no_access', message = 'You do not have access to that inventory.' })
  end

  if tostring(fromInventory) == tostring(targetInventory) then
    return res({ error = true, message = 'Cannot take from your own inventory.' })
  end

  local sourceItems = InventoryControllers.GetInventoryItems(fromInventory)
  local moved, skipped = 0, 0
  local context = {
      actorSource = src,
      actorCharacterId = character.id,
      reason = 'take_all',
      resource = 'feather-inventory'
  }

  -- The usual case is that everything fits. Move the complete set through
  -- one locked transaction instead of opening one transaction per owned row
  -- (55 items previously meant 55 sequential round trips). If the complete
  -- set cannot fit, preserve Take All's greedy contract by falling back to
  -- individual attempts so lighter/smaller items can still move.
  local instanceIds = {}
  for _, item in pairs(sourceItems) do instanceIds[#instanceIds + 1] = item.id end
  if #instanceIds > 0 then
    local batch = InventoryControllers.MoveInventoryItems(
      fromInventory, targetInventory, instanceIds, context)
    if not (batch and batch.error) then
      moved = #instanceIds
    else
      for _, item in pairs(sourceItems) do
        local result = InventoryControllers.MoveInventoryItems(
          fromInventory, targetInventory, { item.id }, context)
        if result and result.error then
          skipped = skipped + 1
        else
          moved = moved + 1
        end
      end
    end
  end

  if moved == 0 and skipped > 0 then
    Feather.Notify.RightNotify(src, Translate(src, 'err_inventory_full', 'There is no room for that.'), 3000)
  elseif skipped > 0 then
    Feather.Notify.RightNotify(src, Translate(src, 'msg_took_what_fit', 'Took what would fit.'), 3000)
  end

  res({
    error = false,
    moved = moved,
    skipped = skipped,
    expectedSourceCount = math.max(0, #sourceItems - moved),
    sourceItems = InventoryControllers.GetInventoryItems(fromInventory),
    targetItems = InventoryControllers.GetInventoryItems(targetInventory)
  })
end)

-- (INV-11) Access-list management for owned/shared inventories (storage,
-- saddlebags, job lockers, ...). Authorization (owner or admin) is checked
-- inside each InventoryAPI function itself, re-derived from `src` -- these
-- RPCs are thin wrappers, not a separate trust boundary.
Feather.RPC.Register('Feather:Inventory:GrantAccess', function(params, res, src)
  -- Unwrapped at the NUI boundary; the browser keeps the { error, ... } shape.
  local outcome = InventoryAPI.GrantInventoryAccess(src, params.inventoryId, params.targetCharacterId)
  res(Result.IsOk(outcome) and { error = false, value = outcome.value }
    or { error = true, code = outcome.error.code, message = outcome.error.message })
end)

Feather.RPC.Register('Feather:Inventory:RevokeAccess', function(params, res, src)
  -- Unwrapped at the NUI boundary; the browser keeps the { error, ... } shape.
  local outcome = InventoryAPI.RevokeInventoryAccess(src, params.inventoryId, params.targetCharacterId)
  res(Result.IsOk(outcome) and { error = false, value = outcome.value }
    or { error = true, code = outcome.error.code, message = outcome.error.message })
end)

Feather.RPC.Register('Feather:Inventory:SetPublic', function(params, res, src)
  -- Unwrapped at the NUI boundary; the browser keeps the { error, ... } shape.
  local outcome = InventoryAPI.SetInventoryPublic(src, params.inventoryId, params.isPublic and true or false)
  res(Result.IsOk(outcome) and { error = false, value = outcome.value }
    or { error = true, code = outcome.error.code, message = outcome.error.message })
end)

Feather.RPC.Register('Feather:Inventory:ListAccess', function(params, res, src)
  -- Unwrapped at the NUI boundary; the browser keeps the { error, ... } shape.
  local outcome = InventoryAPI.ListInventoryAccess(src, params.inventoryId)
  res(Result.IsOk(outcome) and { error = false, value = outcome.value }
    or { error = true, code = outcome.error.code, message = outcome.error.message })
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
  local player = InventoryIdentity.GetCharacter(src)
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
