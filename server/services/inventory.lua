InventoryAPI = {}
local RegisteredForeignKeys = {}
local OpenInventories = {}

---
-- Register Script with Inventory
--
-- Creates a foreign key in the inventory table to link to your script's table.
--
-- @param tableName Name of your Database Table
-- @param foreignKeyType Type of the foreign key (e.g. BIGINT UNSIGNED, VARCHAR(255), etc.)
-- @param primaryKeyName Name of the primary key in your table (e.g. id)
-- @return None
--
-- (INV-18) tableName/primaryKeyName end up concatenated directly into DDL
-- below. Both come from other resources' RegisterForeignKey calls rather
-- than client input, but a whitelist check costs nothing and turns a typo'd
-- or malicious identifier into a clean rejection instead of arbitrary SQL
-- landing in an ALTER TABLE statement. foreignKeyType is passed through as
-- typed (e.g. "BIGINT UNSIGNED") since it's a SQL type, not an identifier.
local function IsSafeIdentifier(name)
  return type(name) == 'string' and name:match('^[A-Za-z_][A-Za-z0-9_]*$') ~= nil
end

InventoryAPI.RegisterForeignKey = function(tableName, foreignKeyType, primaryKeyName)
  if not tableName or not foreignKeyType or not primaryKeyName then
    warn(
      'All parameters are required!')
    return
  end

  if not IsSafeIdentifier(tableName) or not IsSafeIdentifier(primaryKeyName) then
    warn('Invalid tableName or primaryKeyName. Must be a valid SQL identifier.')
    return
  end

  if RegisteredForeignKeys[tableName] then
    warn('This foreign key has already been registered by a different resource.')
    return
  end

  local foreignKey = string.lower(tableName) .. '_id'
  local constraint = 'FK_Inventory' .. FirstToUpper(string.lower(tableName))
  local column = MySQL.query.await("SHOW COLUMNS FROM `inventory` LIKE ?;", { foreignKey })
  if #(column) < 1 then
    local query = 'ALTER TABLE `inventory` ADD COLUMN IF NOT EXISTS (`' ..
        foreignKey ..
        '` ' ..
        foreignKeyType ..
        ' NULL), ADD CONSTRAINT `' ..
        constraint ..
        '` FOREIGN KEY IF NOT EXISTS (`' ..
        foreignKey ..
        '`) REFERENCES `' .. tableName .. '` (`' .. primaryKeyName .. '`) ON DELETE CASCADE ON UPDATE CASCADE;'

    print(query)
    MySQL.query.await(query)
  end

  -- (Tier 1 audit sweep) Was `table.insert(RegisteredForeignKeys, 'tableName')`
  -- -- array-appending the literal string "tableName" instead of setting
  -- the dict key the guard above (`RegisteredForeignKeys[tableName]`)
  -- actually reads, so the "already registered by a different resource"
  -- check never triggered.
  RegisteredForeignKeys[tableName] = true
end

---
-- Register Inventory
--
-- Register a custom inventory for an  entity.
--
-- @param tableName Name of your Database Table
-- @param id Foreign Key ID of the entity
-- @param displayName the name of the inventory (default: storage)
-- @param ignoreItemLimits Ignore the max quantity of items that can be added to the inventory
-- @param maxWeight Override the maximum weight of the inventory (nill to use default)
-- @param restrictedItems Table of items that are restricted from being added to the inventory. e.g. { "apple", "matches" }
-- @param ownerCharacterId (INV-11) Character id that owns this inventory's access list -- the owner
--   may always open it and is the only non-admin who can grant/revoke access to others
--   (see InventoryAPI.GrantInventoryAccess). Leave nil for an inventory with no ACL owner.
-- @param isPublic (INV-11/INV-12) If true, any src holding a valid temporary access grant
--   (InventoryAPI.GrantTemporaryAccess) may open this inventory, in addition to the owner/ACL.
--   Ignored (treated as false) on update if not explicitly passed, same as the other flags below.
-- @param maxSlots (§10.4) How many compartments this inventory has. Leave nil to use
--   Config.maxItemSlots -- capacity is a per-inventory property now, so a wagon or a
--   storage chest can be genuinely bigger than a player's own book rather than every
--   container in the world sharing one global size. The ledger UI scrolls to whatever
--   this is, so it is not bounded by what fits on one visible page.
-- @return Inventory UUID for accessing the inventory later (can be saved in your database table)
--
InventoryAPI.RegisterInventory = function(tableName, id, displayName, ignoreItemLimits, maxWeight, restrictedItems, ownerCharacterId, isPublic, maxSlots)
  if not tableName or not id then
    warn(
      'All parameters are required!')
    return
  end

  -- (INV-18) Same rationale as RegisterForeignKey -- tableName is
  -- concatenated into DDL/DML below via `foreignKey`.
  if not IsSafeIdentifier(tableName) then
    warn('Invalid tableName. Must be a valid SQL identifier.')
    return
  end

  local foreignKey = string.lower(tableName) .. '_id'
  local column = MySQL.query.await("SHOW COLUMNS FROM `inventory` LIKE ?;", { foreignKey })
  if #(column) < 1 then
    warn(
      'A foreign key for this script has not been registered. Please refer to the documentation to register a foreign key.')
    return
  end

  -- Check if inventory already exists
  local query = 'SELECT `id`, `uuid`, `max_weight`, `ignore_item_limit` FROM `inventory` WHERE `' .. foreignKey .. '`=?'
  local inventory = MySQL.query.await(query, { id })

  -- Inventory exists. Check Max Weight and Ignore Item Limits. Return Inventory UUID
  if inventory ~= nil and inventory[1] then
    -- (Re-register update bug) This previously wrote `inventory[1].max_weight`
    -- -- the value already in the database -- rather than the `maxWeight`
    -- argument, so re-registering an inventory could never actually change
    -- its weight limit; the UPDATE set the column to itself. Rewritten to
    -- write the passed value, and only when one was explicitly passed, which
    -- matches the ownerCharacterId/isPublic/maxSlots rule below: omitting an
    -- argument must not silently reset a stored setting.
    if maxWeight ~= nil then
      MySQL.query.await('UPDATE `inventory` SET `max_weight`=? WHERE `id`=?;',
        { tonumber(maxWeight), inventory[1].id })
    end
    if ignoreItemLimits ~= nil then
      MySQL.query.await('UPDATE `inventory` SET `ignore_item_limit`=? WHERE `id`=?;',
        { ignoreItemLimits and 1 or 0, inventory[1].id })
    end

    if restrictedItems then
      InventoryControllers.UpdateRestrictedItems(inventory[1].id, restrictedItems)
    end

    if ownerCharacterId ~= nil then
      MySQL.query.await('UPDATE `inventory` SET `owner_character_id`=? WHERE `id`=?;', { ownerCharacterId, inventory[1].id })
    end
    if isPublic ~= nil then
      MySQL.query.await('UPDATE `inventory` SET `is_public`=? WHERE `id`=?;', { isPublic and 1 or 0, inventory[1].id })
    end
    -- Only written when explicitly passed, same as the two flags above --
    -- omitting it on a re-register must not silently reset a container that
    -- was already given a custom size back to the Config default.
    if maxSlots ~= nil then
      MySQL.query.await('UPDATE `inventory` SET `max_slots`=? WHERE `id`=?;', { tonumber(maxSlots), inventory[1].id })
    end

    return inventory[1].uuid, inventory[1].id
  end

  -- Create new inventory
  query = 'INSERT INTO `inventory` (' .. foreignKey .. ', location, name, max_weight, ignore_item_limit, owner_character_id, is_public, max_slots) VALUES (?, ?, ?, ?, ?, ?, ?, ?) RETURNING *;'
  inventory = MySQL.query.await(query, { id, tableName, displayName or 'storage', maxWeight or nil, ignoreItemLimits or false, ownerCharacterId or nil, isPublic and 1 or 0, maxSlots and tonumber(maxSlots) or nil })

  if not inventory or not inventory[1] then
    return nil
  end

  return inventory[1].uuid, inventory[1].id
end

---
-- Validate the {item=, quantity=} list shape shared by every capacity check.
--
-- @return True if well-formed; false (plus a warn) otherwise
--
local function IsValidItemRequestList(items)
  if type(items) ~= 'table' then
    warn(
      'Invalid items format. Must be a table of items and their quantity. { {item="apple", quantity=5}, {item="matches", quantity=10} }')
    return false
  end

  for _, v in pairs(items) do
    if not v.item or tonumber(v.quantity) == nil or tonumber(v.quantity) < 0 then
      warn(
        'Invalid items format. Must be a table of items and their quantity. { {item="apple", quantity=5}, {item="matches", quantity=10} }')
      return false
    end
  end
  return true
end

---
-- Evaluate Inventory Acceptance
--
-- (Capacity model unification) The single answer to "can this inventory take
-- N more of these items right now". Every grant and transfer path routes
-- through this, so there is exactly one definition of "full" instead of the
-- four mutually-inconsistent ones this resource used to carry:
--
--   * AddItem compared the inventory-wide count of an item against
--     `max_stack_size` (the PER-SLOT cap), so an item with max_quantity=100
--     and max_stack_size=20 was capped at 20 in total -- the reported
--     "can't hold more than 20 apples" bug.
--   * GrantItem used math.min(max_quantity, max_stack_size), the same
--     conflation by a different route.
--   * GrantItem also compared total unit COUNT against Config.maxItemSlots,
--     treating every unit as if it consumed its own compartment -- 25 apples
--     stacked into 2 slots reported a full 25-slot book.
--   * InventoryCanHold/ById had the quantity check right but summed weight
--     without multiplying by quantity, so moving 10 apples only ever counted
--     one apple's weight.
--
-- Stack size is a *placement* property, not an acceptance limit: it decides
-- how many compartments N units occupy, never how many the inventory may
-- hold in total. That distinction is the whole bug class above.
--
-- `ignoreItemLimit` exempts the per-item quantity cap only -- slots and
-- weight are physical properties of the container and stay enforced, which
-- matches what InventoryCanHold already did and what the fixed-size ledger
-- grid can actually render. (Revisit when §10.4's scrollable grid lands.)
--
-- @param inventory Raw inventory.id (already resolved)
-- @param maxWeight Inventory's max_weight, or nil to fall back to Config.maxWeight
-- @param ignoreItemLimit Inventory's ignore_item_limit flag, any DB representation
-- @param items Table of {item=name, quantity=n}, already shape-validated
-- @return { status = boolean, message = string }
--
local function EvaluateInventoryAcceptance(inventory, maxWeight, ignoreItemLimit, items)
  -- (§10.4) Per-inventory, not the global Config default -- a storage wagon
  -- registered with a larger capacity must be measured against its own size.
  local capacity = InventoryControllers.GetInventoryCapacity(inventory)
  local freeSlots = capacity - InventoryControllers.GetOccupiedSlotCount(inventory)
  -- Normalized through the Boolean lookup rather than `== 0`/`tonumber(x) ~= 1`
  -- -- this column has been read three different ways across this file,
  -- items.lua, and GrantItem. It happens to be tinyint(4) today (so it comes
  -- back a number), but `is_public` is tinyint(1) and comes back a real
  -- boolean, which is exactly how that flag silently read as false for every
  -- public inventory until Boolean gained [true]/[false] entries.
  local ignoreLimits = Boolean[ignoreItemLimit] == true
  local addedWeight = 0

  for _, entry in pairs(items) do
    local quantity = tonumber(entry.quantity) or 0
    -- (INV-14) Was `GetItemByName(v)` -- passing the whole {item=, quantity=}
    -- table where the function expects the item's name string, so every
    -- lookup resolved to `false` and no capacity check could return a real
    -- result.
    local itemId, maxQuantity, itemWeight, maxStackSize = ItemControllers.GetItemByName(entry.item)
    if not itemId then
      return { status = false, code = 'invalid_item', message = 'Item does not exist.' }
    end

    if InventoryControllers.IsItemRestricted(inventory, itemId) then
      return { status = false, code = 'item_restricted', message = 'Item is restricted.' }
    end

    -- (INV-10) `Boolean` is a lookup table (see helpers/main.lua), not a
    -- function -- calling it as `Boolean(x)` errored every time this ran.
    if not ignoreLimits then
      if (InventoryControllers.InventoryItemCount(inventory, itemId) + quantity) > (tonumber(maxQuantity) or 0) then
        return { status = false, code = 'item_limit', message = 'Max Quantity Exceeded.' }
      end
    end

    -- Units join existing under-full stacks of the same item before claiming
    -- fresh compartments -- the same placement rule AddItem/GrantItem apply
    -- when they actually assign slot_index, so the check matches the write.
    local stackSize = math.max(tonumber(maxStackSize) or 1, 1)
    local roomInExistingStacks = 0
    for _, stack in pairs(InventoryControllers.GetItemStackCounts(inventory, itemId)) do
      local used = tonumber(stack.count) or 0
      if used < stackSize then
        roomInExistingStacks = roomInExistingStacks + (stackSize - used)
      end
    end

    local overflow = quantity - roomInExistingStacks
    if overflow > 0 then
      local slotsNeeded = math.ceil(overflow / stackSize)
      if slotsNeeded > freeSlots then
        return { status = false, code = 'inventory_full', message = 'Inventory has no available slots.' }
      end
      -- Decrement so several items in one request compete for the same free
      -- compartments instead of each being checked against the full count.
      freeSlots = freeSlots - slotsNeeded
    end

    addedWeight = addedWeight + ((tonumber(itemWeight) or 0) * quantity)
  end

  -- A limit of 0 means "no weight limit" -- see GetInventoryWeightLimit.
  -- Used by ground piles: a heap on the floor has nothing doing the
  -- carrying, so weight is meaningless there, while slot and per-item
  -- quantity limits still apply.
  local weightLimit = tonumber(maxWeight) or tonumber(Config.maxWeight)
  if weightLimit and weightLimit > 0
      and (InventoryControllers.GetInventoryTotalWeight(inventory) + addedWeight) > weightLimit then
    return { status = false, code = 'weight_limit', message = 'Max Weight Exceeded.' }
  end

  return { status = true, message = '' }
end

-- Exposed for the grant paths in items.lua, which resolve their own
-- inventory/limits before calling and so would otherwise re-query for them.
InventoryAPI.EvaluateInventoryAcceptance = EvaluateInventoryAcceptance

---
-- Evaluate one side of a slot move: `inventory` gives up `leaving` and
-- receives `arriving`, both as GetSlotItemBreakdown rows.
--
-- The net-delta part is the whole point. Checking `arriving` alone against
-- the inventory's current totals double-counts, because the items in
-- `leaving` are vacating that same inventory in the same operation -- an
-- inventory at its weight limit can always accept a swap for something no
-- heavier, but an addition-only check rejects it.
--
-- @return { status = boolean, code = string?, message = string }
--
local function EvaluateSlotMoveSide(inventory, maxWeight, ignoreItemLimit, arriving, leaving)
  local ignoreLimits = Boolean[ignoreItemLimit] == true

  local leavingCountByItem = {}
  local leavingWeight = 0
  for _, row in pairs(leaving) do
    local count = tonumber(row.count) or 0
    local key = tostring(row.item_id)
    leavingCountByItem[key] = (leavingCountByItem[key] or 0) + count
    leavingWeight = leavingWeight + ((tonumber(row.weight) or 0) * count)
  end

  local arrivingWeight = 0
  for _, row in pairs(arriving) do
    local count = tonumber(row.count) or 0

    if InventoryControllers.IsItemRestricted(inventory, row.item_id) then
      return { status = false, code = 'item_restricted', message = 'Item is restricted.' }
    end

    if not ignoreLimits then
      -- Subtract any units of this same item that are leaving in this
      -- operation before adding what's arriving -- swapping one stack of
      -- apples for another must not read as doubling the apple count.
      local current = InventoryControllers.InventoryItemCount(inventory, row.item_id)
      local alsoLeaving = leavingCountByItem[tostring(row.item_id)] or 0
      if (current - alsoLeaving + count) > (tonumber(row.max_quantity) or 0) then
        return { status = false, code = 'item_limit', message = 'Max Quantity Exceeded.' }
      end
    end

    arrivingWeight = arrivingWeight + ((tonumber(row.weight) or 0) * count)
  end

  -- 0 means unlimited, same convention as EvaluateInventoryAcceptance.
  local weightLimit = tonumber(maxWeight) or tonumber(Config.maxWeight)
  if weightLimit and weightLimit > 0 then
    local projected = InventoryControllers.GetInventoryTotalWeight(inventory) - leavingWeight + arrivingWeight
    if projected > weightLimit then
      return { status = false, code = 'weight_limit', message = 'Max Weight Exceeded.' }
    end
  end

  return { status = true, message = '' }
end

---
-- Evaluate Slot Move
--
-- (§6 MoveItem bypass, second half) Whether the ledger's drag-and-drop may
-- move the whole compartment at (fromInventory, fromSlot) to
-- (toInventory, toSlot), swapping with whatever is already there.
--
-- Handles both the empty-destination and swap cases through the same
-- net-delta math, which is what made the swap case tractable at all. The
-- previous fix could only close the empty-slot half: it reused
-- InventoryCanHoldById, whose "add this on top of the current total" model
-- double-counts the stack simultaneously leaving to make room for the swap,
-- so the occupied case was left deliberately unchecked rather than shipped
-- with wrong math. Expressing both sides as (current - leaving + arriving)
-- makes the empty case fall out for free -- it is just a move whose
-- `leaving` side happens to be empty.
--
-- Slot *capacity* is deliberately not re-checked here: unlike a grant,
-- this targets one specific compartment index that the caller has already
-- bounds-checked against capacity, so no new compartment is ever claimed
-- beyond the one named. Weight, per-item quantity, and the blacklist are
-- the real constraints, and each is evaluated for both inventories --
-- an item leaving A for B has to be affordable to B *and* whatever comes
-- back has to be affordable to A.
--
-- @param fromInventory Raw inventory.id the stack currently lives in
-- @param fromSlot Its compartment index
-- @param toInventory Raw inventory.id being moved into
-- @param toSlot Destination compartment index
-- @return { status = boolean, code = string?, message = string }
--
InventoryAPI.EvaluateSlotMove = function(fromInventory, fromSlot, toInventory, toSlot)
  -- Same-inventory rearrangement changes nothing about what that inventory
  -- holds in total -- no weight, quantity, or restriction can differ.
  if tostring(fromInventory) == tostring(toInventory) then
    return { status = true, message = '' }
  end

  local fromId, fromMaxWeight, fromIgnoreLimit = InventoryControllers.GetInventoryById(fromInventory, 'id')
  local toId, toMaxWeight, toIgnoreLimit = InventoryControllers.GetInventoryById(toInventory, 'id')
  if not fromId or not toId then
    warn('Invalid inventory ID.')
    return { status = false, code = 'invalid_inventory', message = 'Inventory does not exist.' }
  end

  local moving = InventoryControllers.GetSlotItemBreakdown(fromInventory, fromSlot)
  local occupant = InventoryControllers.GetSlotItemBreakdown(toInventory, toSlot)

  local destination = EvaluateSlotMoveSide(toInventory, toMaxWeight, toIgnoreLimit, moving, occupant)
  if destination.status == false then
    return destination
  end

  -- The swap's return leg. Skipping this is how an occupied-slot swap could
  -- push the *source* inventory over its own limits with the occupant it
  -- receives back, even when the destination side was perfectly fine.
  return EvaluateSlotMoveSide(fromInventory, fromMaxWeight, fromIgnoreLimit, occupant, moving)
end

---
-- Can Inventory Hold items
--
--
-- @param items Table of items and their quantity. e.g. { {item="apple", quantity=5}, {item="matches", quantity=10} }
-- @param inventoryId Player Source or Inventory UUID
-- @return True if inventory can hold items, false if not
--
InventoryAPI.InventoryCanHold = function(items, inventoryId)
  if not IsValidItemRequestList(items) then
    return nil
  end

  local inventory, maxWeight, ignore_item_limit = nil, nil, nil
  if tonumber(inventoryId) then
    local player = Feather.Character.GetCharacter({ src = inventoryId })
    local character = player and player.char
    if character then
      inventory, maxWeight, ignore_item_limit = InventoryControllers.GetInventoryByCharacter(character.id)
    end
  else
    inventory, maxWeight, ignore_item_limit = InventoryControllers.GetInventoryById(inventoryId)
  end
  if not inventory then
    warn('Invalid inventory ID.')
    return nil
  end

  return EvaluateInventoryAcceptance(inventory, maxWeight, ignore_item_limit, items)
end

---
-- Can Inventory Hold Items, by raw inventory.id
--
-- (Drop/give bugfix) InventoryCanHold's `inventoryId` only ever means
-- "player source" (numeric) or "inventory UUID" (string) per its own
-- convention -- it has no way to mean "this specific numeric inventory.id",
-- which is exactly what MoveInventoryItems' targetInventory/sourceInventory
-- always are (raw ids from GetInventoryByCharacter/RegisterInventory, not a
-- player src). Calling InventoryCanHold with one of those numeric ids got
-- silently misread as a player source, resolved to no character, and
-- InventoryCanHold returned nil -- which MoveInventoryItems then treated as
-- "target can't hold this," rejecting every single drop/give/transfer
-- without ever actually checking capacity. This variant skips the
-- src-vs-uuid guessing entirely and always resolves by raw id.
--
-- @param items Table of items and their quantity, same shape as InventoryCanHold
-- @param inventoryId Raw inventory.id
-- @return True if inventory can hold items, false if not
--
InventoryAPI.InventoryCanHoldById = function(items, inventoryId)
  if not IsValidItemRequestList(items) then
    return nil
  end

  local inventory, maxWeight, ignore_item_limit = InventoryControllers.GetInventoryById(inventoryId, 'id')
  if not inventory then
    warn('Invalid inventory ID.')
    return nil
  end

  return EvaluateInventoryAcceptance(inventory, maxWeight, ignore_item_limit, items)
end

---
-- Open Inventory
--
-- Returns items in the specified inventories
--
-- @param src Player Source
-- @param otherInventoryId Player Source or Inventory UUID of a different inventory
-- @return Table of items in the inventory and other inventory if specified
--
InventoryAPI.InternalOpenInventory = function(src, otherInventoryId)
  local inventory, inventoryIgnoreLimits, otherInventory, otherInventoryIgnoreLimits, otherName = nil, nil, nil, nil, nil
  -- (Ground pickup bugfix) Was `local character` scoped only to this
  -- if-block -- every read of it below (the "Owned/shared inventory" branch
  -- further down, e.g. picking a dropped item back up) hit an unset global
  -- instead, crashing this whole RPC with "attempt to index a nil value
  -- (global 'character')" and taking GetInventoryItems down with it.
  local character

  -- Check to make sure inventoryId is a player source and not a string
  if tonumber(src) then
    local player = Feather.Character.GetCharacter({ src = src })
    character = player.char

    -- Check if the character is available
    if character == nil then
      -- `error` stays the developer-facing English string this has always
      -- returned; `errorCode` is what the client localizes off (§10.2), so
      -- the open-failure notice isn't hardcoded English on the way out.
      return {
        error = 'Inventory not available',
        errorCode = 'invalid_inventory'
      }
    end

    inventory, _, _, _ = InventoryControllers.GetInventoryByCharacter(character.id)
  else
    warn('Invalid Character Source!')
    return {
      error = 'No Character Available',
      errorCode = 'no_character'
    }
  end

  local inventoryItems, otherInventoryItems = InventoryControllers.GetInventoryItems(inventory), nil

  -- (INV-11/INV-23) This used to resolve otherInventoryId and hand it back
  -- unconditionally -- the mere act of calling this RPC populated
  -- OpenInventories, which IsInventoryAccessibleBySrc then treated as proof
  -- of authorization. That's circular: the caller granted themselves
  -- access by asking. Authorization now comes from state the caller cannot
  -- set themselves -- see server/services/inventory_access.lua.
  if otherInventoryId ~= nil then
    local resolvedId, resolvedIgnoreLimits, resolvedName = nil, nil, nil

    if tonumber(otherInventoryId) then
      -- Player-to-player: robbery / forced search. Requires the target to
      -- actually be near the caller AND to be in a status that justifies
      -- it -- neither alone is enough (proximity alone was INV-12's
      -- mistake; status alone would let anyone loot anyone incapacitated
      -- from across the map).
      local targetPlayer = Feather.Character.GetCharacter({ src = otherInventoryId })
      local targetCharacter = targetPlayer and targetPlayer.char

      if not targetCharacter then
        -- no target connected/loaded; leave otherInventory nil
      elseif not IsWithinRobberyDistance(src, otherInventoryId) then
        Feather.Notify.RightNotify(src, Translate(src, 'err_too_far', 'You are too far away.'), 3000)
      elseif not CanBeLootedDueToStatus(targetCharacter.id) then
        Feather.Notify.RightNotify(src, Translate(src, 'err_cannot_search', 'This player cannot be searched right now.'), 3000)
      else
        resolvedId, _, resolvedIgnoreLimits, resolvedName = InventoryControllers.GetInventoryByCharacter(targetCharacter.id)
      end
    else
      -- Owned/shared inventory (storage, saddlebags, job lockers, ground
      -- pickups, ...) -- gated by ownership, a persistent grant, or (for
      -- public inventories) a short-lived grant issued by whichever
      -- resource disclosed this UUID after checking its own proximity/
      -- consent condition.
      local uuidId, _, uuidIgnoreLimits, uuidName = InventoryControllers.GetInventoryById(otherInventoryId)
      DebugPrint('DEBUG-GROUND', 'InternalOpenInventory: src=%s requested uuid=%s -- resolved inventory.id=%s',
        tostring(src), tostring(otherInventoryId), tostring(uuidId))
      if uuidId and not IsAuthorizedForOwnedInventory(src, character.id, uuidId) then
        DebugPrint('DEBUG-GROUND', 'InternalOpenInventory: src=%s DENIED for inventory.id=%s', tostring(src), tostring(uuidId))
        Feather.Notify.RightNotify(src, Translate(src, 'err_no_access', 'You do not have access to this inventory.'), 3000)
      elseif uuidId then
        resolvedId, resolvedIgnoreLimits, resolvedName = uuidId, uuidIgnoreLimits, uuidName
      end
    end

    if resolvedId then
      if OpenInventories[tostring(resolvedId)] ~= nil then
        Feather.Notify.RightNotify(src, Translate(src, 'err_already_open', 'This inventory is already opened. Try again later.'), 3000)
      else
        otherInventory, otherInventoryIgnoreLimits, otherName = resolvedId, resolvedIgnoreLimits, resolvedName
        otherInventoryItems = InventoryControllers.GetInventoryItems(otherInventory)
        OpenInventories[tostring(otherInventory)] = {
          src = tostring(src),
          id = otherInventory,
          uuid = otherInventoryId
        }
      end
    end
  end

  return {
    inventory = inventory,
    inventoryItems = inventoryItems,
    inventoryIgnoreLimits = inventoryIgnoreLimits,
    -- (§10.4) Each book carries its own capacity. The client used to send one
    -- global Config.maxItemSlots for both, which made a large storage chest
    -- render as the same size as the player's own book -- and, worse, let the
    -- UI offer slots the server would then reject as out of range.
    inventoryMaxSlots = InventoryControllers.GetInventoryCapacity(inventory),
    inventoryMaxWeight = InventoryControllers.GetInventoryWeightLimit(inventory),
    otherName = otherName,
    otherInventory = otherInventory,
    otherInventoryItems = otherInventoryItems,
    otherInventoryIgnoreLimits = otherInventoryIgnoreLimits,
    otherInventoryMaxSlots = otherInventory and InventoryControllers.GetInventoryCapacity(otherInventory) or nil,
    otherInventoryMaxWeight = otherInventory and InventoryControllers.GetInventoryWeightLimit(otherInventory) or nil
  }
end

---
-- Is Inventory Accessible By Src
--
-- (INV-01) Authorization check for the RPCs that let a client name which
-- inventories to move items between. A src may access its own character's
-- inventory, or any inventory it currently has open via
-- InternalOpenInventory (ground pickups, storage, etc.) -- nothing else.
--
-- @param src Player Source making the request
-- @param inventoryId Raw inventory.id being requested
-- @return True if src may read/write this inventory right now
--
InventoryAPI.IsInventoryAccessibleBySrc = function(src, inventoryId)
  if not src or not inventoryId then
    return false
  end

  local player = Feather.Character.GetCharacter({ src = src })
  local character = player and player.char
  if character then
    local ownInventoryId = InventoryControllers.GetInventoryByCharacter(character.id)
    if ownInventoryId and tostring(ownInventoryId) == tostring(inventoryId) then
      return true
    end
  end

  local opened = OpenInventories[tostring(inventoryId)]
  if not opened or opened.src ~= tostring(src) then
    return false
  end

  -- (INV-11/INV-23) The lock only proves src was authorized to open this
  -- inventory at open time. For another player's own character inventory
  -- specifically, re-verify proximity and status live rather than trusting
  -- a lock that could be minutes old -- a robbery target who wakes up and
  -- runs, or who the caller simply walked away from, should stop being
  -- lootable immediately. Public/UUID inventories (storage, ground, ...)
  -- skip this: the object isn't a person and doesn't run away.
  if tonumber(opened.uuid) then
    local targetPlayer = Feather.Character.GetCharacter({ src = opened.uuid })
    local targetCharacter = targetPlayer and targetPlayer.char
    if not targetCharacter
      or not IsWithinRobberyDistance(src, opened.uuid)
      or not CanBeLootedDueToStatus(targetCharacter.id)
    then
      return false
    end
  end

  return true
end

InventoryAPI.OpenInventory = function (src, InventoryId, target)
  TriggerClientEvent('Feather:Inventory:OpenInventory', src, InventoryId, target)
end

InventoryAPI.CloseInventory = function(src)
  TriggerClientEvent('Feather:Inventory:CloseInventory', src)
end

InventoryAPI.GetInventory = function(inventoryID)
  return InventoryControllers.GetInventoryById(inventoryID)
end

InventoryAPI.GetCustomInventory = function (key, inventoryID)
  return InventoryControllers.GetCustomInventoryById(key, inventoryID)
end

InventoryAPI.GetInventoryItems = function(inventoryID)
  return InventoryControllers.GetInventoryItems(inventoryID)
end

---
-- Close Inventory
--
-- Unlocks any inventory locked by the user provided so it can be accessed by another player
--
-- @param src Player Source
-- @return None
--
InventoryAPI.InternalCloseInventory = function(src)
  for k, v in pairs(OpenInventories) do
    if v.src == tostring(src) then
      -- (INV-20) GetInventoryTotalItemCounts(...)[1] crashed InternalCloseInventory
      -- (and by extension, the playerDropped handler for every other still-
      -- connected player) whenever the query returned no rows -- e.g. the
      -- inventory row itself was deleted between opening and disconnect.
      local counts = InventoryControllers.GetInventoryTotalItemCounts(v.id)
      if counts and counts[1] and tonumber(counts[1].count) and tonumber(counts[1].count) <= 0 then
        TriggerEvent('Feather:Inventory:Empty', {
          id = v.id,
          uuid = v.uuid
        })
      end

      OpenInventories[k] = nil
      -- break
    end
  end
end

AddEventHandler('playerDropped', function()
  local src = source
  InventoryAPI.InternalCloseInventory(src)
end)

