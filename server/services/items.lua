--TODO: Replace errors with the core notifies

-- Item-instance operations (add/remove/use/drop) on top of the raw
-- inventory_items rows managed by InventoryControllers. `inventoryId`
-- throughout this file follows the framework's dual convention: a numeric
-- value is treated as a player src (resolved to that player's own
-- character inventory), a string is treated as a raw inventory UUID.
ItemsAPI = {}
UsableItemCallbacks = {}
local UsableItemOwners = {}
local ActiveItemUses = {}

function ItemsAPI.RegisterInternalUseGuard()
  return GuardsAPI.RegisterMoveGuard('feather-inventory:active-use', function(instance)
    if ActiveItemUses[tonumber(instance.id)] then
      return false, 'That item is currently being used.'
    end
    return true
  end)
end

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
  if definition.archived_at ~= nil then
    return Result.Err(Result.Codes.DENIED, 'Item definition is archived and cannot be granted.',
      { itemName = definition.name })
  end

  -- A `unique` definition carries per-instance state -- a weapon's serial and
  -- ammunition, a tool's condition -- and this path cannot supply it. Allowing
  -- the generic catalog to create one would produce an instance with an empty
  -- document: present and equippable, but with nothing for its owning resource
  -- to read.
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


  local inventory
  if tonumber(inventoryId) then
    local player = InventoryIdentity.GetCharacter(tonumber(inventoryId))
    local character = player and player.char
    if character then
      inventory = InventoryControllers.GetInventoryByCharacter(character.id)
    end
  else
    inventory = InventoryControllers.GetInventoryById(inventoryId)
  end
  if not inventory then
    return Result.Err('invalid_inventory', 'Inventory does not exist.')
  end

  -- Preserve the trusted legacy API while delegating capacity, blacklist,
  -- placement, locking, rollback, and post-commit facts to the authoritative
  -- transaction implementation.
  return TransactionAPI.Transaction({
    reason = 'grant',
    resource = GetInvokingResource() or 'feather-inventory'
  }, function(tx)
    local granted = tx:AddQuantity(inventory, definition.id, quantity)
    if not Result.IsOk(granted) then return granted end
    return Result.Ok({
      itemName = definition.name,
      displayName = definition.display_name,
      quantity = quantity,
      instanceIds = granted.value
    })
  end)
end

-- Grants `quantity` of `itemName` to an inventory, enforcing the per-item
-- quantity cap, slot capacity, and weight limit (see
-- EvaluateInventoryAcceptance). Emits Feather:Inventory:ItemCreated once per
-- unit granted. `max_stack_size` governs only how many compartments those
-- units are spread across, never how many the inventory may hold.
ItemsAPI.AddItem = function(itemName, quantity, metadata, inventoryId)
  quantity = tonumber(quantity)
  if not quantity or quantity < 1 or quantity % 1 ~= 0 then
    warn('Invalid quantity. Must be greater than 0.')
    return Result.Err(Result.Codes.INVALID_INPUT, "Quantity must be greater than 0.")
  end

  local itemId = ItemControllers.GetItemByName(itemName)
  if not itemId then
    warn('Invalid itemName. Please make sure it is in the items table in your database.')
    return Result.Err(Result.Codes.NOT_FOUND, "Item does not exist in the items table.")
  end
  local actorSource = tonumber(inventoryId)
  local inventory = nil
  if actorSource then
    local player = InventoryIdentity.GetCharacter(actorSource)
    local character = player and player.char
    -- (Phase 6 consistency pass) No character loaded for this src used to
    -- crash here (nil index on `.id`) instead of falling through to the
    -- "Invalid inventory ID" rejection below, same as every other resolved-
    -- character branch in this file.
    if character then
      inventory = InventoryControllers.GetInventoryByCharacter(character.id)
    end
  else
    inventory = InventoryControllers.GetInventoryById(inventoryId)
  end

  if not inventory then
    warn('Invalid inventory ID.')
    return Result.Err("invalid_inventory", "Inventory does not exist.")
  end

  if metadata ~= nil and type(metadata) ~= 'table' then
    warn(
      "Invalid format for meta data. Meta data must be a table of key value pairs. Example: { quality = 'poor', durability = 50, maxDurability = 100 }")
    return Result.Err(Result.Codes.INVALID_INPUT, "Metadata must be a table of key/value pairs.")
  end

  return TransactionAPI.Transaction({
    actorSource = actorSource,
    reason = 'legacy_add',
    resource = GetInvokingResource() or 'feather-inventory'
  }, function(tx)
    local granted = tx:AddQuantity(inventory, itemId, quantity, metadata)
    if not Result.IsOk(granted) then return granted end
    return Result.Ok({ granted = #granted.value, requested = quantity,
      instanceIds = granted.value })
  end)
end

-- Removes n number of items by name. (No specific order)
ItemsAPI.RemoveItemByName = function(itemName, quantity, inventoryId)
  quantity = tonumber(quantity)
  if not quantity or quantity < 1 or quantity % 1 ~= 0 then
    warn('Invalid quantity. Must be greater than 0.')
    return Result.Err(Result.Codes.INVALID_INPUT, "Quantity must be greater than 0.")
  end

  local itemId, _, _ = ItemControllers.GetItemByName(itemName)
  if not itemId then
    warn('Invalid itemName. Please make sure it is in the items table in your database.')
    return Result.Err(Result.Codes.NOT_FOUND, "Item does not exist in the items table.")
  end

  local actorSource = tonumber(inventoryId)
  local inventory = nil
  if actorSource then
    local player = InventoryIdentity.GetCharacter(actorSource)
    local character = player and player.char
    if character then
      inventory = InventoryControllers.GetInventoryByCharacter(character.id)
    end
  else
    inventory = InventoryControllers.GetInventoryById(inventoryId)
  end
  if not inventory then
    warn('Invalid inventory ID.')
    return Result.Err("invalid_inventory", "Inventory does not exist.")
  end

  -- Legacy signature retained, but authority now lives in the same locked
  -- transaction pipeline as newer consumers. Selection, guard checks, delete,
  -- rollback and post-commit facts are therefore one operation.
  return TransactionAPI.Transaction({
    actorSource = actorSource,
    reason = 'remove_by_name',
    resource = GetInvokingResource() or 'feather-inventory'
  }, function(tx)
    local removed = tx:RemoveQuantity(inventory, itemId, quantity)
    if not Result.IsOk(removed) then return removed end
    return Result.Ok({ removed = #removed.value, instanceIds = removed.value })
  end)
end

-- Removes a specific item from the players inventory.
ItemsAPI.RemoveItemById = function(id)
  local numericId = tonumber(id)
  if not numericId then
    return Result.Err(Result.Codes.INVALID_INPUT, "A valid item instance id is required.")
  end

  return TransactionAPI.Transaction({
    reason = 'remove_by_id',
    resource = GetInvokingResource() or 'feather-inventory'
  }, function(tx)
    local item = tx:GetItemForUpdate(numericId)
    if not Result.IsOk(item) then return item end
    local removed = tx:RemoveInstances(item.value.inventoryId, item.value.definition.id, { numericId })
    if not Result.IsOk(removed) then return removed end
    return Result.Ok(true)
  end)
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
ItemsAPI.RegisterUsableItem = function(itemName, callback, ownerResource)
  if type(itemName) ~= 'string' or itemName == '' or not IsUsableItemCallback(callback) then
    return Result.Err(Result.Codes.INVALID_INPUT, 'An item name and a callback function are required.')
  end

  local invokingResource = GetInvokingResource()
  ownerResource = ownerResource or invokingResource or GetCurrentResourceName()
  if type(ownerResource) ~= 'string' or ownerResource == '' then
    return Result.Err(Result.Codes.INVALID_INPUT, 'A usable-item owner resource is required.')
  end
  if invokingResource and invokingResource ~= ownerResource then
    return Result.Err(Result.Codes.DENIED, 'A resource cannot register usable items for another owner.', {
      itemName = itemName,
      owner = ownerResource,
      invokingResource = invokingResource
    })
  end

  local currentOwner = UsableItemOwners[itemName]
  if UsableItemCallbacks[itemName] and currentOwner ~= ownerResource then
    warn('An item by that name has already been registered. Item: ' .. itemName)
    return Result.Err(Result.Codes.CONFLICT, 'An item by that name is already registered.', {
      itemName = itemName,
      owner = currentOwner
    })
  end

  UsableItemCallbacks[itemName] = callback
  UsableItemOwners[itemName] = ownerResource
  return Result.Ok({ itemName = itemName, owner = ownerResource, replaced = currentOwner == ownerResource })
end

AddEventHandler('onResourceStop', function(resourceName)
  local released = 0
  for itemName, owner in pairs(UsableItemOwners) do
    if owner == resourceName then
      UsableItemCallbacks[itemName] = nil
      UsableItemOwners[itemName] = nil
      released = released + 1
    end
  end
  if released > 0 then
    print(('[feather-inventory] released %d usable item registration(s) owned by %s')
      :format(released, resourceName))
  end
end)

ItemsAPI.UseItem = function(itemID, src, context)
  local numericId = tonumber(itemID)
  if not numericId then
    return Result.Err(Result.Codes.INVALID_INPUT, 'A valid item instance id is required.')
  end
  if ActiveItemUses[numericId] then
    return Result.Err(Result.Codes.CONFLICT, 'That item is already being used.')
  end

  local item = InventoryControllers.GetInventoryItemById(numericId)
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
  local callback = UsableItemCallbacks[item.name]
  if callback then
    -- Recheck after the yielding database reads above. Two concurrent requests
    -- may both begin validation, but only one may enter consumer code.
    if ActiveItemUses[numericId] then
      return Result.Err(Result.Codes.CONFLICT, 'That item is already being used.')
    end
    ActiveItemUses[numericId] = {
      source = tonumber(src),
      resource = UsableItemOwners[item.name],
      reason = context and context.reason or 'use'
    }
    local ok, callbackResult = pcall(callback, item, src, function()
      -- Refresh the inventory ui on callback
      TriggerClientEvent('Feather:Inventory:OpenInventory', src, nil, "player")
    end)
    ActiveItemUses[numericId] = nil

    if not ok then
      warn(('Usable item callback failed for %s instance %s: %s')
        :format(tostring(item.name), tostring(numericId), tostring(callbackResult)))
      return Result.Err(Result.Codes.INTERNAL, 'The item could not be used.', {
        itemName = item.name,
        owner = UsableItemOwners[item.name]
      })
    end
    if type(callbackResult) == 'table' and callbackResult.ok == false then
      return callbackResult
    end
  else
    warn('No usable callback defined for item: ' .. item.name)
    return Result.Err(Result.Codes.UNSUPPORTED, 'That item has no registered use behaviour.', { itemName = item.name })
  end
  -- end

  return Result.Ok(true)
end


ItemsAPI.DropItemsOnGround = function(inventoryId, items, x, y, z, context)
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
  local updateinv = InventoryControllers.MoveInventoryItems(inventoryId, groundInventoryID, items,
    context or { reason = 'ground_drop', resource = GetInvokingResource() or 'feather-inventory' })

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
