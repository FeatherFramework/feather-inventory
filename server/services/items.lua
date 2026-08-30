--TODO: Replace errors with the core notifies

-- Item-instance operations (add/remove/use/drop) on top of the raw
-- inventory_items rows managed by InventoryControllers. `inventoryId`
-- throughout this file follows the framework's dual convention: a numeric
-- value is treated as a player src (resolved to that player's own
-- character inventory), a string is treated as a raw inventory UUID.
ItemsAPI = {}
UsableItemCallbacks = {}

-- Cfx serializes callbacks crossing a resource boundary as callable tables.
-- Use rawget because their metatable intentionally rejects normal indexing.
local function IsUsableItemCallback(value)
  return type(value) == 'function'
    or (type(value) == 'table'
      and type(rawget(value, '__cfx_functionReference')) == 'string')
end
function ItemsAPI.GetDefinitions()
  return Result.Ok(ItemControllers.GetItemDefinitions())
end

-- Atomically grants catalog items without metadata. Intended for trusted
-- server resources such as administration, rewards, and scripted payouts.
function ItemsAPI.GrantItem(itemName, quantity, inventoryId)
  if type(itemName) ~= 'string' or itemName == '' then
    return Result.Err('invalid_item', 'Invalid item name.')
  end
  quantity = tonumber(quantity)
  if not quantity or quantity < 1 or quantity % 1 ~= 0 or quantity > 10000 then
    return Result.Err('invalid_quantity', 'Invalid quantity.')
  end

  local definition = ItemControllers.GetItemDefinitionByName(itemName)
  if not definition then
    return Result.Err('invalid_item', 'Item does not exist.')
  end

  -- A `unique` definition carries per-instance state -- a weapon's serial and
  -- ammunition, a tool's condition -- and this path cannot supply it. Rows are
  -- created below by a batched INSERT with no metadata, so granting a weapon
  -- through the generic catalog produces an instance with an empty document:
  -- present and equippable, but with nothing for its owning resource to read.
  --
  -- Refused at the source rather than left for each admin-style consumer to
  -- remember. Unique definitions are issued by whichever resource models them
  -- (feather-weapons' Issuance.Issue), which creates the instance and its
  -- complete initial document in one transaction.
  if definition.instance_mode == 'unique' then
    return Result.Err('unique_requires_issuer',
      ('%s is a unique item and must be issued by the resource that owns it, not granted generically.')
        :format(definition.name),
      { itemName = definition.name, instanceMode = 'unique' })
  end


  local inventory, maxWeight, ignoreItemLimit
  if tonumber(inventoryId) then
    local player = InventoryIdentity.GetCharacter(tonumber(inventoryId))
    local character = player and player.char
    if character then
      inventory, maxWeight, ignoreItemLimit = InventoryControllers.GetInventoryByCharacter(character.id)
    end
  else
    inventory, maxWeight, ignoreItemLimit = InventoryControllers.GetInventoryById(inventoryId)
  end
  if not inventory then
    return Result.Err('invalid_inventory', 'Inventory does not exist.')
  end

  -- (Capacity model unification) Was three separate checks here, two of them
  -- wrong in the same way AddItem's were -- see EvaluateInventoryAcceptance
  -- (server/services/inventory.lua). The slot check counted item *units*
  -- against Config.maxItemSlots, so 25 apples stacked into 2 compartments
  -- reported a full 25-slot book; the quantity check used
  -- math.min(max_quantity, max_stack_size), capping an item at its
  -- per-compartment stack size no matter how much the inventory was actually
  -- allowed to hold.
  local acceptance = InventoryAPI.EvaluateInventoryAcceptance(inventory, maxWeight, ignoreItemLimit,
    { { item = definition.name, quantity = quantity } })
  if not Result.IsOk(acceptance) then
    return acceptance
  end
  if acceptance.value.accepted == false then
    return Result.Err(acceptance.value.code or 'inventory_full',
      acceptance.value.message or 'Inventory cannot hold these items.')
  end

  -- Steampunk ledger: same slot-assignment as AddItem below -- join an
  -- under-full stack of this item first, then roll into fresh free slots.
  local maxStackSize = tonumber(definition.max_stack_size) or 1
  local currentSlot = InventoryControllers.GetJoinableSlot(inventory, definition.id, maxStackSize)
  local currentSlotCount = currentSlot ~= nil and #InventoryControllers.GetItemsInSlot(inventory, currentSlot) or 0
  -- (§10.4) Hoisted out of the loop -- per-inventory capacity is a DB read
  -- now, and it can't change while this grant is being assembled.
  local capacity = InventoryControllers.GetInventoryCapacity(inventory)

  -- (Over-stacking bugfix) This loop builds ONE batched INSERT, executed only
  -- after it finishes -- so nothing it places is visible to a database read
  -- taken during it. Calling GetFreeSlot per unit therefore returned the same
  -- free compartment every single time, and every unit past the first full
  -- stack landed in that one slot: a grant of 100 apples with max_stack_size
  -- 20 produced a compartment holding 78, wildly past the stack limit.
  --
  -- Claim slots against a local set instead, seeded once from the database
  -- and marked as this loop consumes them. (AddItem below is unaffected --
  -- it writes each row as it goes, so its GetFreeSlot calls do see prior
  -- placements.)
  local occupied = InventoryControllers.GetOccupiedSlotSet(inventory)
  if currentSlot ~= nil then
    occupied[tonumber(currentSlot)] = true
  end

  local function claimFreeSlot()
    for index = 0, capacity - 1 do
      if not occupied[index] then
        occupied[index] = true
        return index
      end
    end
    return nil
  end

  local placeholders = {}
  local values = {}
  for index = 1, quantity do
    if currentSlot == nil or currentSlotCount >= maxStackSize then
      currentSlot = claimFreeSlot()
      currentSlotCount = 0
      if currentSlot == nil then
        return Result.Err('inventory_full', 'Inventory has no available slots.')
      end
    end

    placeholders[index] = '(?, ?, ?)'
    values[#values + 1] = inventory
    values[#values + 1] = definition.id
    values[#values + 1] = currentSlot
    currentSlotCount = currentSlotCount + 1
  end
  -- (Weapons review #8) RETURNING `id` so the real instance ids are known.
  -- This previously fired ItemAdded with `definition.id` while the movement
  -- paths fired it with an inventory_items.id -- the same event carrying two
  -- different kinds of identifier depending on which route produced it, so a
  -- consumer could not tell what it had been handed. Every path now emits an
  -- INSTANCE id.
  local succeeded, inserted = pcall(MySQL.query.await,
    ('INSERT INTO inventory_items (inventory_id, item_id, slot_index) VALUES %s RETURNING `id`;')
    :format(table.concat(placeholders, ', ')), values)
  if not succeeded or type(inserted) ~= 'table' or #inserted == 0 then
    return Result.Err('database_error', 'Items could not be granted.')
  end

  local instanceIds = {}
  for index, row in ipairs(inserted) do
    instanceIds[index] = tonumber(row.id)
    GuardsAPI.EmitItemCreated(tonumber(row.id), definition.id, inventory, { reason = 'grant' })
  end

  return Result.Ok({
    itemName = definition.name,
    displayName = definition.display_name,
    quantity = quantity,
    instanceIds = instanceIds
  })
end

-- Grants `quantity` of `itemName` to an inventory, enforcing the per-item
-- quantity cap, slot capacity, and weight limit (see
-- EvaluateInventoryAcceptance). Emits Feather:Inventory:ItemCreated once per
-- unit granted. `max_stack_size` governs only how many compartments those
-- units are spread across, never how many the inventory may hold.
ItemsAPI.AddItem = function(itemName, quantity, metadata, inventoryId)
  quantity = tonumber(quantity)
  if not quantity or quantity < 1 or quantity % 1 ~= 0 then
    warn('Invalid quantity. Must be creater than 0.')
    return Result.Err(Result.Codes.INVALID_INPUT, "Quantity must be greater than 0.")
  end

  -- max_quantity/weight are read by EvaluateInventoryAcceptance itself now;
  -- only the id and stack size are needed here, for slot placement below.
  local itemId, _, _, max_stack_size = ItemControllers.GetItemByName(itemName)
  if not itemId then
    warn('Invalid itemName. Please make sure it is in the items table in your database.')
    return Result.Err(Result.Codes.NOT_FOUND, "Item does not exist in the items table.")
  end
  -- Same normalization GrantItem and EvaluateInventoryAcceptance apply -- the
  -- placement loop below compares against this, so a nil would crash it.
  max_stack_size = math.max(tonumber(max_stack_size) or 1, 1)

  local inventory, maxWeight, ignore_item_limit = nil, nil, nil
  if tonumber(inventoryId) then
    local player = InventoryIdentity.GetCharacter(inventoryId)
    local character = player and player.char
    -- (Phase 6 consistency pass) No character loaded for this src used to
    -- crash here (nil index on `.id`) instead of falling through to the
    -- "Invalid inventory ID" rejection below, same as every other resolved-
    -- character branch in this file.
    if character then
      inventory, maxWeight, ignore_item_limit, _ = InventoryControllers.GetInventoryByCharacter(character.id)
    end
  else
    inventory, maxWeight, ignore_item_limit, _ = InventoryControllers.GetInventoryById(inventoryId)
  end

  if not inventory then
    warn('Invalid inventory ID.')
    return Result.Err("invalid_inventory", "Inventory does not exist.")
  end

  -- (Capacity model unification) Quantity, slot, and weight limits are now
  -- one decision made in one place -- see EvaluateInventoryAcceptance
  -- (server/services/inventory.lua) for what each of the three checks this
  -- replaces was actually getting wrong. The headline one: the slot check
  -- here compared this inventory's total count of the item against
  -- `max_stack_size` (the per-compartment cap), so an apple with
  -- max_quantity=100 and max_stack_size=20 refused the 21st apple in the
  -- whole book rather than starting a second stack.
  local acceptance = InventoryAPI.EvaluateInventoryAcceptance(inventory, maxWeight, ignore_item_limit,
    { { item = itemName, quantity = quantity } })
  if not Result.IsOk(acceptance) then
    return acceptance
  end
  if acceptance.value.accepted == false then
    return Result.Err(acceptance.value.code or "inventory_full",
      acceptance.value.message or "Inventory cannot hold these items.")
  end

  if metadata ~= nil and type(metadata) ~= 'table' then
    warn(
      "Invalid format for meta data. Meta data must be a table of key value pairs. Example: { quality = 'poor', durability = 50, maxDurability = 100 }")
    return Result.Err(Result.Codes.INVALID_INPUT, "Metadata must be a table of key/value pairs.")
  end

  -- Steampunk ledger: each granted unit needs a real compartment (slot_index),
  -- not just a bare row. Join an existing under-full stack of this item
  -- first; once that's full (or there wasn't one), roll into fresh free
  -- slots for the rest. The max-quantity/slot checks above already confirm
  -- there's room overall, so GetFreeSlot running out here would only mean a
  -- race with another grant -- guarded rather than trusted.
  local currentSlot = InventoryControllers.GetJoinableSlot(inventory, itemId, max_stack_size)
  local currentSlotCount = currentSlot ~= nil and #InventoryControllers.GetItemsInSlot(inventory, currentSlot) or 0
  -- (§10.4) Hoisted out of the loop, same as GrantItem above.
  local capacity = InventoryControllers.GetInventoryCapacity(inventory)
  local granted = 0

  for _ = 1, quantity do
    if currentSlot == nil or currentSlotCount >= max_stack_size then
      currentSlot = InventoryControllers.GetFreeSlot(inventory, capacity)
      currentSlotCount = 0
      if currentSlot == nil then
        warn('AddItem: ran out of free slots granting ' .. itemName .. ' to inventory ' .. tostring(inventory))
        break
      end
    end

    -- (Weapons review #4) Metadata goes in with the INSERT rather than being
    -- written key-by-key afterwards, so the instance is never briefly visible
    -- without the state that defines it.
    --
    -- CreateInventoryItem emits Feather:Inventory:ItemCreated itself, carrying
    -- the new instance id, so nothing is announced from here.
    InventoryControllers.CreateInventoryItem(inventory, itemId, currentSlot, metadata)
    currentSlotCount = currentSlotCount + 1
    granted = granted + 1
  end

  -- (Capacity model unification) The loop above can still come up short if
  -- another grant raced us between the acceptance check and here. That used
  -- to `break` and then unconditionally report `{ error = false }` -- a
  -- partial grant indistinguishable from a complete one, which any caller
  -- doing "charge the player, then AddItem" would silently under-deliver on.
  -- Report what actually landed instead.
  if granted < quantity then
    return Result.Err("inventory_full", "Inventory has no available slots.", { granted = granted, requested = quantity })
  end

  return Result.Ok({ granted = granted, requested = quantity })
end

-- Removes n number of items by name. (No specific order)
ItemsAPI.RemoveItemByName = function(itemName, quantity, inventoryId)
  if quantity < 1 then
    warn('Invalid quantity. Must be creater than 0.')
    return Result.Err(Result.Codes.INVALID_INPUT, "Quantity must be greater than 0.")
  end

  local itemId, _, _ = ItemControllers.GetItemByName(itemName)
  if not itemId then
    warn('Invalid itemName. Please make sure it is in the items table in your database.')
    return Result.Err(Result.Codes.NOT_FOUND, "Item does not exist in the items table.")
  end

  local inventory, _, _ = nil, nil, nil
  if tonumber(inventoryId) then
    local player = InventoryIdentity.GetCharacter(inventoryId)
    local character = player and player.char
    if character then
      inventory, _, _ = InventoryControllers.GetInventoryByCharacter(character.id)
    end
  else
    inventory, _, _ = InventoryControllers.GetInventoryById(inventoryId)
  end
  if not inventory then
    warn('Invalid inventory ID.')
    return Result.Err("invalid_inventory", "Inventory does not exist.")
  end

  local itemCount = InventoryControllers.InventoryItemCount(inventory, itemId)
  if itemCount < quantity then
    return Result.Err("item_limit", "Withdrawing more items than available.")
  end

  -- (Tier 1 audit sweep) Was `inventory.id` -- `inventory` here is already
  -- the raw numeric inventory id (DeleteInventoryItems' own signature takes
  -- the id directly), not a table, so this indexed a number and crashed on
  -- every call. Every caller of this exported function -- crafting
  -- ingredient consumption, ammo use, anything built on RemoveItemByName --
  -- was broken.
  -- (Weapons review #8) Resolve which instances are going before deleting
  -- them, so the removal events name the rows that actually left rather than
  -- the definition. Previously this fired ItemRemoved with a definition id
  -- while RemoveItemById fired the same event with an instance id.
  local doomed = InventoryControllers.GetInstanceIdsForRemoval(inventory, itemId, quantity)

  -- (Weapons review #4) Every public removal path asks the destroy guards
  -- first. This previously called the raw delete, so an equipped weapon could
  -- be removed through a legacy API with no chance for weapons to veto or
  -- unequip -- the guard registry existed but only the new paths used it.
  -- All-or-nothing: a partial removal because one unit was vetoed would be
  -- worse than refusing the whole request.
  for _, instanceId in ipairs(doomed) do
    local allowed, reason = GuardsAPI.CanDestroyInstance(instanceId, { reason = 'remove_by_name' })
    if not allowed then
      return Result.Err(Result.Codes.DENIED, reason or "Removal blocked by a guard.")
    end
  end

  for _, instanceId in ipairs(doomed) do
    InventoryControllers.DeleteInventoryItem(instanceId)
  end

  for _, instanceId in ipairs(doomed) do
    GuardsAPI.EmitItemDestroyed(instanceId, itemId, inventory, { reason = 'remove_by_name' })
  end

  return Result.Ok({ removed = #doomed, instanceIds = doomed })
end

-- Removes a specific item from the players inventory.
ItemsAPI.RemoveItemById = function(id)
  local item = InventoryControllers.GetInventoryItemById(id)
  if not item then
    return Result.Err(Result.Codes.NOT_FOUND, "Item not available.")
  end
  -- (Weapons review #4) Guarded, like every other removal path. An equipped
  -- weapon must not be destroyable through a legacy API without weapons
  -- getting a chance to veto or unequip first.
  local allowed, reason = GuardsAPI.CanDestroyInstance(item.id, { reason = 'remove_by_id' })
  if not allowed then
    return Result.Err(Result.Codes.DENIED, reason or "Removal blocked by a guard.")
  end

  InventoryControllers.DeleteInventoryItem(item.id)

  GuardsAPI.EmitItemDestroyed(item.id, item.item_id, item.inventory_id, { reason = 'remove_by_id' })
  return Result.Ok(true)
end

-- ItemsAPI.SetMetadata was removed. It had become a pure passthrough to
-- InstancesAPI.MergeMetadata that made the result strictly worse on the way
-- out -- unwrapping the envelope into { error, code, message } and dropping
-- the correlation id. Call InstancesAPI.MergeMetadata (patch) or
-- InstancesAPI.WriteMetadata (replace, with optional compare-and-set)
-- directly instead.

------------------------------------------------------------------
-- Condition / durability (§10.3)
------------------------------------------------------------------
--
-- A generic per-instance wear value in the versioned metadata document. This resource
-- owns the convention only -- key, range, clamping, validation, display --
-- and none of the policy. When an item wears, by how much, and what a worn
-- item then does are all questions for whichever resource models that
-- behaviour (feather-weapons, a tools resource, ...). Keeping it generic here
-- is the whole point: otherwise every consumer invents its own field and
-- nothing can render a wear indicator for all of them.
--
-- Storage-agnostic by design. `condition` is a single small integer, so it
-- lives in the versioned metadata document, so it inherits compare-and-set
-- and atomic writes without the convention itself changing.

local function ConditionKey()
  return (Config.Condition and Config.Condition.Key) or 'condition'
end

local function ConditionMax()
  return tonumber(Config.Condition and Config.Condition.Max) or 100
end

---
-- Get Condition
--
-- @param itemId inventory_items.id
-- @return Integer 0..Max, or nil if this instance has no condition recorded
--
ItemsAPI.GetCondition = function(itemId)
  -- (INV-W1) Reads through the versioned metadata document.
  local metadata = InstancesAPI.ReadMetadata(tonumber(itemId))
  if not Result.IsOk(metadata) then
    return metadata
  end
  return Result.Ok(tonumber(metadata.value.document[ConditionKey()]))
end

---
-- Set Condition
--
-- Clamps to 0..Config.Condition.Max and writes it to this instance.
--
-- REFUSES STACKABLE ITEMS, deliberately. A compartment stacks by item_id
-- alone (see GetJoinableSlot) -- metadata is invisible to it -- so two units
-- of a stackable item carrying different conditions would silently merge into
-- one compartment and one of the values would be lost. Per-instance state on
-- a stackable definition needs INV-W1's unique-instance model first; until
-- then this fails closed rather than quietly corrupting a stack. Every
-- currently-seeded degradable item (weapons, tools) is max_stack_size = 1 and
-- is unaffected.
--
-- @param itemId inventory_items.id
-- @param value Desired condition; clamped into range
-- @return { error, code, message, condition }
--
ItemsAPI.SetCondition = function(itemId, value)
  local numericId = tonumber(itemId)
  local numericValue = tonumber(value)
  if not numericId or not numericValue then
    return Result.Err('invalid_quantity', 'Invalid item id or condition value.')
  end

  local item = InventoryControllers.GetInventoryItemById(numericId)
  if not item then
    return Result.Err('invalid_item', 'Item does not exist.')
  end

  if (tonumber(item.max_stack_size) or 1) > 1 then
    return Result.Err("condition_not_supported", "Condition cannot be set on a stackable item.")
  end

  local clamped = math.max(0, math.min(math.floor(numericValue), ConditionMax()))

  -- (INV-W1) Written through MergeMetadata rather than a direct key write, so
  -- condition inherits the document's compare-and-set semantics: two callers
  -- wearing the same item concurrently can no longer silently clobber one
  -- another's value, which the old one-key-at-a-time flat write allowed.
  local written = InstancesAPI.MergeMetadata(numericId, { [ConditionKey()] = clamped })
  if not Result.IsOk(written) then
    return written
  end

  return Result.Ok({ condition = clamped, revision = written.value.revision })
end

---
-- Adjust Condition
--
-- Relative change -- the common case, since wear is expressed as "this cost
-- 5 condition" far more often than as an absolute target. An instance with
-- no condition recorded yet is treated as full, so a consumer can wear an
-- item that was never explicitly initialised.
--
-- @param itemId inventory_items.id
-- @param delta Signed change (negative wears, positive repairs)
-- @return { error, code, message, condition }
--
ItemsAPI.AdjustCondition = function(itemId, delta)
  local numericDelta = tonumber(delta)
  if not numericDelta then
    return Result.Err('invalid_quantity', 'Invalid condition delta.')
  end

  local current = ItemsAPI.GetCondition(itemId)
  if current == nil then
    current = ConditionMax()
  end

  return ItemsAPI.SetCondition(itemId, current + numericDelta)
end

ItemsAPI.GetItem = function(id)
  local item = InventoryControllers.GetInventoryItemById(id)
  if not item then
    return Result.Err(Result.Codes.NOT_FOUND, "Item instance does not exist.")
  end

  return Result.Ok(item)
end

---
-- Get Item Count
--
-- @return The number held, or `nil` when the item or inventory is invalid.
--
-- Returns nil rather than the old -1 sentinel. -1 is a plausible-looking
-- number, so a failure survived arithmetic and picked a different wrong
-- answer depending on how the caller asked: `count > 0` read an error as
-- "has none", `count ~= 0` read the same error as "has some". nil is not a
-- number, so a caller that forgets to check fails loudly instead.
--
ItemsAPI.GetItemCount = function(itemName, inventoryId)
  local itemId, _, _ = ItemControllers.GetItemByName(itemName)
  if not itemId then
    warn("Invalid itemName. Please make sure it is in the items table in your database.")
    return Result.Err(Result.Codes.NOT_FOUND, "Item does not exist in the items table.")
  end

  local inventory, _, _ = nil, nil, nil
  if tonumber(inventoryId) then
    local player = InventoryIdentity.GetCharacter(inventoryId)
    local character = player and player.char
    if character then
      inventory, _, _ = InventoryControllers.GetInventoryByCharacter(character.id)
    end
  else
    inventory, _, _ = InventoryControllers.GetInventoryById(inventoryId)
  end
  -- (Phase 6 consistency pass) `not inventory == nil` -- `not` binds tighter
  -- than `==`, so this was `(not inventory) == nil`, a boolean compared to
  -- nil, which is always false. An invalid inventoryId silently fell
  -- through to InventoryItemCount(nil, itemId) instead of ever hitting this
  -- rejection (harmless there -- a nil inventory_id just matches nothing in
  -- SQL -- but not the intended "unresolvable inventory" contract).
  if not inventory then
    warn("Invalid inventory ID.")
    return Result.Err("invalid_inventory", "Inventory does not exist.")
  end

  return Result.Ok(InventoryControllers.InventoryItemCount(inventory, itemId))
end

-- (INV-15) Was inverted -- returned false when the item *was* found and true
-- when it wasn't, so every caller's "does this item exist" check read
-- backwards.
ItemsAPI.ItemExists = function(itemName)
  local itemId, _, _ = ItemControllers.GetItemByName(itemName)
  return Result.Ok(itemId ~= nil and itemId ~= false)
end

ItemsAPI.InventoryHasItems = function(items, inventoryId)
  local numberOfItems = #items
  local count = 0

  local inventory, _, _ = nil, nil, nil
  if tonumber(inventoryId) then
    local player = InventoryIdentity.GetCharacter(inventoryId)
    local character = player and player.char
    if character then
      inventory, _, _ = InventoryControllers.GetInventoryByCharacter(character.id)
    end
  else
    inventory, _, _ = InventoryControllers.GetInventoryById(inventoryId)
  end
  if not inventory then
    return Result.Err("invalid_inventory", "Inventory does not exist.")
  end
  local playerItems = InventoryControllers.InventoryItemCounts(inventory)

  -- Error Checks
  if not IsTable(items) then
    warn('items must be a table! e.g. {{name = "apple", quantity = 2}, {name = "lemon", quantity = 1}}')
    return Result.Err(Result.Codes.INVALID_INPUT, 'items must be a table of { name, quantity } entries.')
  end

  for _, v in pairs(items) do
    if not IsTable(v) then
      warn('items must be a table! e.g. {{name = "apple", quantity = 2}, {name = "lemon", quantity = 1}}')
      return Result.Err(Result.Codes.INVALID_INPUT, 'items must be a table of { name, quantity } entries.')
    end

    if v.name == nil or tonumber(v.quantity) == nil then
      warn('items must be a table! e.g. {{name = "apple", quantity = 2}, {name = "lemon", quantity = 1}}')
      return Result.Err(Result.Codes.INVALID_INPUT, 'items must be a table of { name, quantity } entries.')
    end
  end

  -- (INV-15) Two bugs: `playerItem['COUNT[...]']` never matched the query's
  -- actual column key (now `.count`, see InventoryControllers.
  -- InventoryItemCounts), so the quantity comparison always errored/failed;
  -- and the final `count < numberOfItems` was backwards -- it should report
  -- "has items" when every requested item was satisfied, not when fewer than
  -- all of them were.
  for _, requestedItem in pairs(items) do
    for _, playerItem in pairs(playerItems) do
      if playerItem and requestedItem.name == playerItem.name and tonumber(playerItem.count) >= tonumber(requestedItem.quantity) then
        count = count + 1
      end
    end
  end

  return Result.Ok(count >= numberOfItems)
end

-- Lets other resources (e.g. feather-weapons, for every weapon item) attach
-- a "use" behavior to an item by name. Looked up by ItemsAPI.UseItem below
-- when a player actually uses the item from their inventory.
ItemsAPI.RegisterUsableItem = function(itemName, callback)
  if type(itemName) ~= 'string' or itemName == '' or not IsUsableItemCallback(callback) then
    return Result.Err(Result.Codes.INVALID_INPUT, 'An item name and a callback function are required.')
  end
  if UsableItemCallbacks[itemName] then
    warn('An item by that name has already been registered. Item: ' .. itemName)
    return Result.Err(Result.Codes.CONFLICT, 'An item by that name is already registered.', { itemName = itemName })
  end

  UsableItemCallbacks[itemName] = callback
  return Result.Ok(true)
end

ItemsAPI.UseItem = function(itemID, src, context)
  local item = InventoryControllers.GetInventoryItemById(itemID)
  if not item then
    warn('Item not found in the database! ItemID: ' .. tostring(itemID))
    return Result.Err(Result.Codes.NOT_FOUND, 'Item instance does not exist.')
  end
  if tonumber(src) == nil then
    warn('Invalid Player Source')
    return Result.Err(Result.Codes.INVALID_INPUT, 'A valid player source is required.')
  end

  -- (INV-02) This ownership check was commented out, so any client could
  -- "use" any item id -- including ones it didn't own -- which chains into
  -- free weapon equips via feather-weapons' usable-item registration.
  -- Re-enabled, and compares against the item's actual current
  -- inventory_id (not something client-suppliable) rather than the
  -- original draft's approach.
  local player = InventoryIdentity.GetCharacter(src)
  local character = player and player.char
  if not character then
    warn('No character loaded for src: ' .. tostring(src))
    return Result.Err("no_character", 'No character is loaded for that player.')
  end

  local inventory = InventoryControllers.GetInventoryByCharacter(character.id)
  if not inventory or tostring(item.inventory_id) ~= tostring(inventory) then
    warn('Rejected UseItem: src ' .. tostring(src) .. ' does not own item ' .. tostring(itemID))
    return Result.Err(Result.Codes.DENIED, 'That item is not in your inventory.')
  end

  -- if item.type == 'item_weapon' then
  --   TriggerEvent('Feather:Inventory:UsedItem', src, item)
  -- elseif item.type == 'item_ammo' then
  --   TriggerEvent('Feather:Inventory:UsedItem', src, item)
  -- else
  if UsableItemCallbacks[item.name] then
    UsableItemCallbacks[item.name](item, src, function()
      -- A hotbar use happens while the ledger is closed; refreshing it by
      -- firing OpenInventory would unexpectedly open the whole book after a
      -- quick-use action. Refresh the compact HUD instead. Existing callers
      -- keep the original inventory refresh behavior.
      if context and context.hotbar then
        TriggerClientEvent('Feather:Inventory:HotbarRefresh', src)
      else
        TriggerClientEvent('Feather:Inventory:OpenInventory', src, nil, "player")
      end
    end)
  else
    warn('No usable callback defined for item: ' .. item.name)
    return Result.Err(Result.Codes.UNSUPPORTED, 'That item has no registered use behaviour.', { itemName = item.name })
  end
  -- end

  return Result.Ok(true)
end


ItemsAPI.DropItemsOnGround = function(inventoryId, items, x, y, z)
  if type(items) ~= 'table' or #items == 0 then
    return Result.Err(Result.Codes.INVALID_INPUT, "No items specified.")
  end

  -- (INV-03) The old check only validated items[1]'s name/count via
  -- GetItemCount, then let MoveInventoryItems move every items[].id
  -- regardless of whether it actually matched that name or belonged to
  -- inventoryId -- a client could mix in foreign item ids to duplicate/
  -- steal items onto the ground. Every item is now checked against
  -- inventoryId up front (inventoryId itself is already server-derived
  -- from src by the caller, not client-supplied).
  for _, entry in ipairs(items) do
    local id = type(entry) == 'table' and entry.id or entry
    local item = InventoryControllers.GetInventoryItemById(id)
    if not item or tostring(item.inventory_id) ~= tostring(inventoryId) then
      warn('Rejected DropItemsOnGround: item ' .. tostring(id) .. ' does not belong to inventory ' .. tostring(inventoryId))
      return Result.Err(Result.Codes.DENIED, "One or more items are not in your inventory.")
    end
  end

  -- (INV-16) Was `Config.groundGroupingRadius`, which doesn't exist -- the
  -- real key is `Config.Dropped.GroupingRadius` (see config.lua and
  -- services/errors.lua's startup validation of it). Reading the wrong key
  -- passed nil as the radius, silently disabling grouping: every drop made
  -- its own ground pile instead of joining a nearby one.
  local groundID = GroundControllers.GetClosestGroundByCoords(x, y, z, Config.Dropped.GroupingRadius)
  
  -- No nearby ground, lets create a new one
  if groundID == nil or groundID == 'nil' then
    groundID = GroundControllers.CreateGround(x, y, z)[1].id
  end

  -- (INV-11/INV-12) isPublic=true: anyone may open a ground pile, but only
  -- after GetGroundUID (server/services/ground.lua) has verified they're
  -- actually standing near it and issued a short-lived grant -- see
  -- InventoryAPI.GrantTemporaryAccess / IsAuthorizedForOwnedInventory.
  -- maxWeight = 0 means "no weight limit" (see GetInventoryWeightLimit). A
  -- heap on the floor has nothing doing the carrying, so a weight cap on it
  -- is meaningless -- but slot capacity and per-item quantity limits still
  -- apply, which is why only the weight argument is zeroed here.
  local registered = InventoryAPI.RegisterInventory('ground', groundID, 'Ground', nil, 0, nil, nil, true)
  if not Result.IsOk(registered) then
    return registered
  end
  local groundInventoryID = registered.value.id
  local updateinv = InventoryControllers.MoveInventoryItems(inventoryId, groundInventoryID, items)

  -- This always reported `error = false` even when MoveInventoryItems
  -- itself rejected the move (e.g. capacity) -- the ground pile row would
  -- exist but the item never actually left the source inventory, with no
  -- error surfaced to the client to explain why.
  -- MoveInventoryItems is a controller, not an export -- it keeps its own
  -- { error, code, message } shape, which this converts at the API boundary.
  if updateinv and updateinv.error then
    return Result.Err(updateinv.code or Result.Codes.INTERNAL,
      updateinv.message or "Items could not be dropped.", { inventory = updateinv })
  end

  UpdateClientWithGroundLocations(-1)

  return Result.Ok({ inventory = updateinv })
end
