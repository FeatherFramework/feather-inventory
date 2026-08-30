InventoryControllers = {}

local function NormalizeLockedItem(row)
  local metadata = {}
  if row.metadata and row.metadata ~= '' then
    local decoded, value = pcall(json.decode, row.metadata)
    if decoded and type(value) == 'table' then metadata = value end
  end
  return {
    id = tonumber(row.id),
    inventoryId = tonumber(row.inventory_id),
    slot = row.slot_index ~= nil and tonumber(row.slot_index) or nil,
    metadata = metadata,
    revision = tonumber(row.row_revision) or 0,
    definition = {
      id = tonumber(row.item_id), name = row.name,
      displayName = row.display_name, weight = tonumber(row.weight),
      type = row.type, maxQuantity = tonumber(row.max_quantity),
      maxStackSize = tonumber(row.max_stack_size),
      instanceMode = row.instance_mode or 'stack',
    }
  }
end

local function MutationContext(context, reason)
  local copy = {}
  for key, value in pairs(context or {}) do copy[key] = value end
  copy.reason = reason or copy.reason
  copy.resource = copy.resource or GetInvokingResource() or 'feather-inventory'
  return copy
end

local function ContextCanAccess(context, inventoryId, action)
  if not context or not context.actorSource then return true end
  local decision = InventoryAPI.CanAccessInventory(context.actorSource, inventoryId, action, context)
  return Result.IsOk(decision)
end

local function SlotMoveAcceptanceInTransaction(query, fromInventory, fromSlot, toInventory, toSlot)
  local firstInventory = math.min(tonumber(fromInventory), tonumber(toInventory))
  local secondInventory = math.max(tonumber(fromInventory), tonumber(toInventory))
  local sameInventory = firstInventory == secondInventory
  local inventoryRows = query(sameInventory
    and [[SELECT `id`, `max_weight`, `ignore_item_limit`
      FROM `inventory` WHERE `id`=? FOR UPDATE;]]
    or [[SELECT `id`, `max_weight`, `ignore_item_limit`
      FROM `inventory` WHERE `id` IN (?, ?) ORDER BY `id` FOR UPDATE;]],
    sameInventory and { firstInventory } or { firstInventory, secondInventory })
  if not inventoryRows or #inventoryRows ~= (sameInventory and 1 or 2) then
    return false, 'invalid_inventory', 'Inventory does not exist.'
  end

  local policies = {}
  for _, row in ipairs(inventoryRows) do policies[tonumber(row.id)] = row end

  -- Lock and measure every row in both inventories. This makes total weight
  -- and per-definition counts stable until the swap commits.
  local allRows = query([[SELECT ii.`id`, ii.`inventory_id`, ii.`slot_index`, ii.`item_id`,
      ii.`metadata`, ii.`row_revision`, i.`name`, i.`display_name`, i.`weight`,
      i.`type`, i.`max_quantity`, i.`max_stack_size`, i.`instance_mode`
    FROM `inventory_items` ii INNER JOIN `items` i ON i.`id`=ii.`item_id`
    WHERE ii.`inventory_id` IN (?, ?) ORDER BY ii.`inventory_id`, ii.`id` FOR UPDATE;]],
    { firstInventory, secondInventory }) or {}

  local totals, counts = {}, {}
  for _, inventoryId in ipairs({ firstInventory, secondInventory }) do
    totals[inventoryId], counts[inventoryId] = 0, {}
  end
  for _, row in ipairs(allRows) do
    local inventoryId, definitionId = tonumber(row.inventory_id), tostring(row.item_id)
    totals[inventoryId] = (totals[inventoryId] or 0) + (tonumber(row.weight) or 0)
    counts[inventoryId][definitionId] = (counts[inventoryId][definitionId] or 0) + 1
  end

  local moving, occupant = {}, {}
  for _, row in ipairs(allRows) do
    if tostring(row.inventory_id) == tostring(fromInventory)
      and tonumber(row.slot_index) == tonumber(fromSlot) then
      moving[#moving + 1] = row
    elseif tostring(row.inventory_id) == tostring(toInventory)
      and tonumber(row.slot_index) == tonumber(toSlot) then
      occupant[#occupant + 1] = row
    end
  end
  if #moving == 0 then return false, 'conflict', 'The source compartment changed.' end
  if sameInventory then return true, nil, nil, moving, occupant end

  local function evaluate(inventoryId, arriving, leaving)
    local policy = policies[tonumber(inventoryId)]
    local projectedWeight = totals[tonumber(inventoryId)] or 0
    local projectedCounts = {}
    for definitionId, count in pairs(counts[tonumber(inventoryId)] or {}) do
      projectedCounts[definitionId] = count
    end
    for _, row in ipairs(leaving or {}) do
      local definitionId = tostring(row.item_id)
      projectedCounts[definitionId] = (projectedCounts[definitionId] or 0) - 1
      projectedWeight = projectedWeight - (tonumber(row.weight) or 0)
    end
    for _, row in ipairs(arriving or {}) do
      local restricted = query(
        'SELECT `inventory_id` FROM `inventory_blacklist` WHERE `inventory_id`=? AND `item_id`=? LIMIT 1;',
        { inventoryId, row.item_id })
      if restricted and restricted[1] then return false, 'item_restricted', 'Item is restricted.' end

      local definitionId = tostring(row.item_id)
      projectedCounts[definitionId] = (projectedCounts[definitionId] or 0) + 1
      if Boolean[policy.ignore_item_limit] ~= true
        and projectedCounts[definitionId] > (tonumber(row.max_quantity) or 0) then
        return false, 'item_limit', 'Max Quantity Exceeded.'
      end
      projectedWeight = projectedWeight + (tonumber(row.weight) or 0)
    end

    local weightLimit = tonumber(policy.max_weight) or tonumber(Config.maxWeight) or 0
    if weightLimit > 0 and projectedWeight > weightLimit then
      return false, 'weight_limit', 'Max Weight Exceeded.'
    end
    return true
  end

  local accepted, code, message = evaluate(tonumber(toInventory), moving, occupant)
  if not accepted then return false, code, message end
  local sourceAccepted, sourceCode, sourceMessage = evaluate(tonumber(fromInventory), occupant, moving)
  return sourceAccepted, sourceCode, sourceMessage, moving, occupant
end

function InventoryControllers.GetInventoryById(inventoryId, type)
  if type == nil then
    type = 'uuid'
  end

  local query = ''

  if type == 'id' then
    query = 'SELECT `id`, `uuid`, `max_weight`, `ignore_item_limit`, `name` FROM `inventory` WHERE `id` = ? LIMIT 1;'
  else
    query = 'SELECT `id`, `uuid`, `max_weight`, `ignore_item_limit`, `name` FROM `inventory` WHERE `uuid` = ? LIMIT 1;'
  end


  local result = MySQL.query.await(
    query, { inventoryId })[1]
  if not result then
    return false, false, false, nil
  end
  return result.id, result.max_weight, result.ignore_item_limit, result.name
end

function InventoryControllers.GetInventoryLocationById(id)
  local result = MySQL.query.await(
    'SELECT `location` FROM `inventory` WHERE `id` = ? LIMIT 1;', { id })[1]
  if not result then
    return nil
  end
  return result.location
end

-- (§10.4 per-inventory capacity) How many compartments this inventory has.
-- `max_slots` is nullable and means "unset" rather than "zero", so a NULL
-- falls back to the Config default -- that's what keeps every pre-existing
-- inventory behaving exactly as before without a data migration.
--
-- Everything that allocates or bounds-checks a slot must resolve capacity
-- through here rather than reading Config.maxItemSlots directly, or a
-- larger container silently gets the default size at one call site and its
-- real size at another.
function InventoryControllers.GetInventoryCapacity(inventory)
  local result = MySQL.query.await('SELECT `max_slots` FROM `inventory` WHERE `id`=? LIMIT 1;', { inventory })[1]
  local configured = result and tonumber(result.max_slots)
  return configured or tonumber(Config.maxItemSlots) or 0
end

-- (Carrying-line fix) This inventory's weight limit, NULL falling back to the
-- Config default -- same shape as GetInventoryCapacity above. Needed by the
-- client payload because the ledger's carrying line was rendering
-- "<weight> / <capacity> lb.", comparing total weight against the SLOT count.
--
-- A stored value of 0 means NO WEIGHT LIMIT, and is returned as-is. NULL
-- cannot carry that meaning because it already means "use the Config
-- default". Ground piles register as 0: nothing is doing the carrying, so
-- weight is meaningless for a heap on the floor, while slot and per-item
-- quantity limits still apply to it.
function InventoryControllers.GetInventoryWeightLimit(inventory)
  local result = MySQL.query.await('SELECT `max_weight` FROM `inventory` WHERE `id`=? LIMIT 1;', { inventory })[1]
  local configured = result and tonumber(result.max_weight)
  return configured or tonumber(Config.maxWeight) or 0
end

function InventoryControllers.GetCustomInventoryById(key, id)
  local field = key..'_id'
  local result = MySQL.query.await('SELECT `id`, `uuid`, `max_weight`, `ignore_item_limit` FROM `inventory` WHERE `'..field..'` = ? LIMIT 1;', { id })[1]

  if result == nil then
    return false, false, false
  end
  
  return result.id, result.uuid, result.max_weight, result.ignore_item_limit
end

function InventoryControllers.GetInventoryByCharacter(character)
  local result = MySQL.query.await(
        'SELECT `id`, `max_weight`, `ignore_item_limit`, `name` FROM `inventory` WHERE `character_id` = ? LIMIT 1;',
        { character })
      [1]
  if not result then
    return false, false, false, nil
  end
  return result.id, result.max_weight, result.ignore_item_limit, result.name
end

function InventoryControllers.InventoryItemCount(inventory, itemId)
  local result = MySQL.query.await('SELECT COUNT(id) FROM `inventory_items` WHERE `inventory_id`=? AND `item_id`=?',
    { inventory, itemId })

  return result[1]["COUNT(id)"]
end

function InventoryControllers.GetInventoryItemById(id)
  local result = MySQL.query.await('SELECT `inventory_items`.`id`, `inventory_items`.`updated_at`, `inventory_items`.`slot_index`, `items`.`display_name`, `items`.`name`, `items`.`description`, `items`.`usable`, `items`.`weight`, `items`.`category_id`, `items`.`max_quantity`, `items`.`max_stack_size`, `inventory_items`.`metadata` AS `metadata`, `inventory_items`.`inventory_id` FROM `inventory_items` INNER JOIN `items` ON `inventory_items`.`item_id` = `items`.`id` WHERE `inventory_items`.`id`=? GROUP BY `inventory_items`.`metadata`, `inventory_items`.`id`, `inventory_items`.`slot_index`, `items`.`display_name`, `items`.`name`, `items`.`description`, `items`.`usable`, `items`.`weight`, `items`.`category_id`, `items`.`max_quantity`, `items`.`max_stack_size` LIMIT 1;', { id })[1]

  if result == nil then
    return false
  end

  if result["metadata"] and result["metadata"] ~= nil then
    result["metadata"] = json.decode(result["metadata"])
  end

  return result
end

-- (INV-15-pattern) Same bug as InventoryItemCounts had: the unaliased
-- SUM(...) expression's actual returned column key is the full expression
-- text "SUM(`items`.`weight`)", not the bare "`items`.`weight`" this used
-- to index -- so this always fell through to `return 0`, silently making
-- InventoryCanHold's weight-limit check (INV-14) a no-op: it only ever saw
-- the new items' weight, never what the inventory already held. Explicit
-- `AS weight` fixes the mismatch.
function InventoryControllers.GetInventoryTotalWeight(inventory)
  local result = MySQL.query.await(
    'SELECT SUM(`items`.`weight`) AS `weight` FROM `items` INNER JOIN `inventory_items` ON `items`.`id`=`inventory_items`.`item_id` WHERE `inventory_items`.`inventory_id`=?',
    { inventory })
  if not result[1] or not result[1].weight then
    return 0
  end

  -- tonumber because a DECIMAL column can arrive as a STRING depending on the
  -- driver -- the same reason every read of characters.x/y/z is wrapped. Lua
  -- coerces strings in arithmetic but NOT in comparison, so an unguarded
  -- `weight > limit` would error rather than misbehave quietly.
  return tonumber(result[1].weight) or 0
end

function InventoryControllers.GetInventoryItems(inventory)
  local items = MySQL.query.await( 'SELECT `inventory_items`.`id`, `inventory_items`.`updated_at`, `inventory_items`.`slot_index`, `items`.`display_name`, `items`.`name`, `items`.`description`, `items`.`usable`, `items`.`weight`, `items`.`category_id`, `items`.`max_quantity`, `items`.`max_stack_size`, `inventory_items`.`metadata` AS `metadata` FROM `inventory_items` INNER JOIN `items` ON `inventory_items`.`item_id` = `items`.`id` WHERE `inventory_items`.`inventory_id` = ? GROUP BY `inventory_items`.`metadata`, `inventory_items`.`id`, `inventory_items`.`slot_index`, `items`.`display_name`, `items`.`name`, `items`.`description`, `items`.`usable`, `items`.`weight`, `items`.`category_id`, `items`.`max_quantity`, `items`.`max_stack_size`;', { inventory })
  for key, value in pairs(items) do
    if value["metadata"] and value["metadata"] ~= nil then
      items[key]["metadata"] = json.decode(value["metadata"])
    end
  end

  return items
end

function InventoryControllers.InventoryItemCounts(inventory)
  -- (INV-15) Explicit `AS count` -- the unaliased COUNT(...) expression's
  -- returned column key doesn't match the bracket-string ItemsAPI.
  -- InventoryHasItems used to index it by, so every lookup read nil.
  return MySQL.query.await(
    'SELECT `items`.`name`, COUNT(`items`.`name`) AS `count` FROM `inventory_items` INNER JOIN `items` ON `inventory_items`.`item_id`=`items`.`id` WHERE `inventory_items`.`inventory_id`=? GROUP BY `items`.`name`;',
    { inventory })
end

function InventoryControllers.GetInventoryTotalItemCounts(inventory)
  return MySQL.query.await(
    'SELECT COUNT(`id`) AS `count` FROM `inventory_items` WHERE `inventory_id`=?;',
    { inventory })
end


-- (Weapons review #4) `metadata` is written in the SAME INSERT that creates
-- the row. Previously the row was created and metadata written afterwards,
-- key by key, so a failure between the two left an item that existed without
-- the state that defines it -- a weapon with no ammo count or serial.
function InventoryControllers.CreateInventoryItem(inventory, itemId, slotIndex, metadata)
  local encoded = nil
  if type(metadata) == 'table' and next(metadata) ~= nil then
    encoded = json.encode(metadata)
  end

  local created = MySQL.query.await('INSERT INTO `inventory_items` (`inventory_id`, `item_id`, `slot_index`, `metadata`) VALUES (?, ?, ?, ?) RETURNING *;',
    { inventory, itemId, slotIndex, encoded })

  -- (INV-W3) Post-commit: the row exists by the time this fires.
  if created and created[1] then
    GuardsAPI.EmitItemCreated(created[1].id, itemId, inventory, { reason = 'grant' })
  end

  return created
end

-- Steampunk ledger: a compartment already holding this item with room left
-- under its stack limit -- new units join it instead of claiming a fresh
-- slot, same "stack up to max_stack_size" behavior the client used to fake
-- with lodash chunk/groupBy, now actually persisted.
-- (INV-W1) A `unique` definition never joins an existing compartment, no
-- matter what its max_stack_size says. This is the single chokepoint where
-- "unique instances cannot stack" is actually enforced -- every grant and
-- transfer path resolves placement through here, so guarding it once covers
-- AddItem, GrantItem and MoveInventoryItems together rather than three
-- separately-maintained checks.
--
-- The join is what makes that possible: matching on `item_id` alone is
-- exactly why per-instance state (condition, and later spoilage) could
-- silently merge into one compartment and lose a value.
function InventoryControllers.GetJoinableSlot(inventory, itemId, maxStackSize)
  local result = MySQL.query.await([[
    SELECT ii.`slot_index`, COUNT(*) AS `count`
    FROM `inventory_items` ii
    INNER JOIN `items` i ON i.`id` = ii.`item_id`
    WHERE ii.`inventory_id`=? AND ii.`item_id`=? AND ii.`slot_index` IS NOT NULL
      AND i.`instance_mode` <> 'unique'
    GROUP BY ii.`slot_index`
    HAVING COUNT(*) < ?
    LIMIT 1;
  ]], { inventory, itemId, maxStackSize })
  if not result[1] then
    return nil
  end
  return result[1].slot_index
end

-- Set of compartment indices currently holding anything, as { [index] = true }.
--
-- Exposed separately from GetFreeSlot because a caller that places several
-- units before writing any of them (GrantItem batches one INSERT for the
-- whole grant) cannot re-query per unit -- the database still shows the
-- pre-grant state, so every lookup would hand back the same free slot. Such
-- a caller takes this set once and marks its own claims as it goes.
function InventoryControllers.GetOccupiedSlotSet(inventory)
  local used = MySQL.query.await(
    'SELECT DISTINCT `slot_index` FROM `inventory_items` WHERE `inventory_id`=? AND `slot_index` IS NOT NULL;',
    { inventory })
  local occupied = {}
  for _, row in pairs(used) do
    occupied[tonumber(row.slot_index)] = true
  end
  return occupied
end

-- First compartment index in [0, capacity) not occupied by any item at all.
-- Safe only for callers that write each placement before asking again.
function InventoryControllers.GetFreeSlot(inventory, capacity)
  local occupied = InventoryControllers.GetOccupiedSlotSet(inventory)
  for i = 0, capacity - 1 do
    if not occupied[i] then
      return i
    end
  end
  return nil
end

-- Every row sharing an (inventory, slot) pair -- a whole compartment's stack,
-- since a slot can hold more than one unit of the same item.
function InventoryControllers.GetItemsInSlot(inventory, slot)
  return MySQL.query.await('SELECT `id` FROM `inventory_items` WHERE `inventory_id`=? AND `slot_index`=?;',
    { inventory, slot })
end

-- (Capacity model) How many units of `itemId` sit in each compartment that
-- already holds it. GetJoinableSlot answers "is there *a* stack with room"
-- for placement; this answers "how much room do *all* of them have", which
-- is what deciding whether N more units fit actually requires.
function InventoryControllers.GetItemStackCounts(inventory, itemId)
  return MySQL.query.await(
    'SELECT `slot_index`, COUNT(*) AS `count` FROM `inventory_items` WHERE `inventory_id`=? AND `item_id`=? AND `slot_index` IS NOT NULL GROUP BY `slot_index`;',
    { inventory, itemId })
end

-- (Swap capacity math) What one compartment actually holds, grouped by item
-- definition: name, unit count, and the per-unit weight/quantity limit needed
-- to reason about moving the whole compartment somewhere else. GetItemsInSlot
-- returns bare row ids, which is enough to *move* a stack but not enough to
-- decide whether the destination can afford it.
--
-- Grouped rather than assumed single-item: a compartment holds one item type
-- by construction (GetJoinableSlot only ever joins matching items), but
-- nothing in the schema enforces that, and a mixed slot should be costed
-- correctly rather than silently mis-costed off its first row.
function InventoryControllers.GetSlotItemBreakdown(inventory, slot)
  return MySQL.query.await([[
    SELECT `items`.`id` AS `item_id`, `items`.`name`, `items`.`weight`,
           `items`.`max_quantity`, `items`.`max_stack_size`, COUNT(*) AS `count`
    FROM `inventory_items`
    INNER JOIN `items` ON `items`.`id` = `inventory_items`.`item_id`
    WHERE `inventory_items`.`inventory_id`=? AND `inventory_items`.`slot_index`=?
    GROUP BY `items`.`id`, `items`.`name`, `items`.`weight`, `items`.`max_quantity`,
             `items`.`max_stack_size`;
  ]], { inventory, slot })
end

-- (Stack merge) Moves `quantity` rows from one compartment into another,
-- across inventories if needed, leaving the remainder behind. MoveSlotItems
-- relocates a whole compartment and SplitSlotItems is same-inventory only;
-- this is the general partial move both of those are special cases of.
--
-- Rows are re-read from the source slot rather than taken from a caller's
-- list, and each UPDATE is scoped by the source inventory_id, so a row that
-- isn't actually there can't be pulled in by naming its id.
-- Returns the count moved and the instance ids that moved. The ids matter:
-- this is the stack-merge path, and it is the caller's only way to announce
-- what happened -- see the ItemMoved emit in the MoveItem RPC.
function InventoryControllers.MoveSlotItemsPartial(fromInventory, fromSlot, toInventory, toSlot, quantity, context)
  local wanted = math.floor(tonumber(quantity) or 0)
  if wanted < 1 then return 0, {} end
  local crossInventory = tostring(fromInventory) ~= tostring(toInventory)
  context = MutationContext(context, 'slot_merge')
  local moved = 0
  local movedIds = {}
  local movedFacts = {}

  local executed, committed = pcall(MySQL.startTransaction, function(query)
    if not ContextCanAccess(context, fromInventory, InventoryAPI.AccessModes.REMOVE)
      or (crossInventory and not ContextCanAccess(context, toInventory, InventoryAPI.AccessModes.INSERT)) then
      return false
    end
    local selectSlot = [[
      SELECT ii.`id`, ii.`inventory_id`, ii.`slot_index`, ii.`item_id`,
             ii.`metadata`, ii.`row_revision`, i.`name`, i.`display_name`,
             i.`weight`, i.`type`, i.`max_quantity`, i.`max_stack_size`, i.`instance_mode`
      FROM `inventory_items` ii INNER JOIN `items` i ON i.`id`=ii.`item_id`
      WHERE ii.`inventory_id`=? AND ii.`slot_index`=? ORDER BY ii.`id` FOR UPDATE;
    ]]
    local sourceFirst = tonumber(fromInventory) < tonumber(toInventory)
      or (tonumber(fromInventory) == tonumber(toInventory) and tonumber(fromSlot) <= tonumber(toSlot))
    local first = query(selectSlot, sourceFirst and { fromInventory, fromSlot } or { toInventory, toSlot })
    local second = query(selectSlot, sourceFirst and { toInventory, toSlot } or { fromInventory, fromSlot })
    local source = sourceFirst and first or second
    local target = sourceFirst and second or first
    if not source or #source == 0 or not target or #target == 0 then return false end

    local definitionId = tostring(source[1].item_id)
    for _, row in ipairs(source) do if tostring(row.item_id) ~= definitionId then return false end end
    for _, row in ipairs(target) do if tostring(row.item_id) ~= definitionId then return false end end

    local stackSize = math.max(tonumber(target[1].max_stack_size) or 1, 1)
    local amount = math.min(wanted, #source, math.max(stackSize - #target, 0))
    if amount < 1 then return false end

    if crossInventory then
      local accepted = InventoryControllers.AcceptanceInTransaction(query, toInventory,
        { { item = source[1].name, quantity = amount } })
      if not accepted then return false end
      for index = 1, amount do
        local snapshot = NormalizeLockedItem(source[index])
        local allowed = GuardsAPI.CanMoveInstanceSnapshot(snapshot, context)
        if not allowed then return false end
        movedFacts[snapshot.id] = {
          definitionId = snapshot.definition.id, revision = snapshot.revision + 1 }
      end
    end

    local revisionBump = crossInventory and ', `row_revision`=`row_revision`+1' or ''
    for index = 1, amount do
      local row = source[index]
      local changed = query(
        'UPDATE `inventory_items` SET `inventory_id`=?, `slot_index`=?' .. revisionBump ..
          ' WHERE `id`=? AND `inventory_id`=? AND `slot_index`=?;',
        { toInventory, toSlot, row.id, fromInventory, fromSlot })
      local affected = tonumber(changed and (changed.affectedRows or changed.affected_rows)) or 0
      if affected ~= 1 then return false end
      moved = moved + 1
      movedIds[moved] = tonumber(row.id)
    end
    return true
  end)

  if not executed or committed ~= true then return 0, {} end

  if crossInventory then
    for _, id in ipairs(movedIds) do
      GuardsAPI.EmitItemMoved(id, fromInventory, toInventory, context, movedFacts[id])
    end
  end

  return moved, movedIds
end

-- (Capacity model) Number of distinct compartments in use, regardless of what
-- or how much is in them. Note this counts *slots*, not units -- an inventory
-- holding 20 apples in one compartment occupies 1 slot, not 20. Conflating
-- those two is what made GrantItem reject grants into a nearly-empty book.
function InventoryControllers.GetOccupiedSlotCount(inventory)
  local result = MySQL.query.await(
    'SELECT COUNT(DISTINCT `slot_index`) AS `count` FROM `inventory_items` WHERE `inventory_id`=? AND `slot_index` IS NOT NULL;',
    { inventory })
  if not result[1] or not result[1].count then
    return 0
  end
  return tonumber(result[1].count) or 0
end

-- Steampunk ledger drag-and-drop: moves every row in (fromInventory, fromSlot)
-- to (toInventory, toSlot). If toSlot is already occupied, swaps -- the
-- occupant's rows move to (fromInventory, fromSlot) instead of being
-- displaced silently. Matches the design's "drop on empty moves, drop on
-- occupied swaps," and moves the whole compartment's stack at once.
--
-- Dragging is always all-or-nothing; peeling part of a stack off is the
-- explicit Split action instead (SplitSlotItems below, driven by the
-- context menu's quantity prompt).
-- Steampunk ledger drag-and-drop: moves every row in (fromInventory, fromSlot)
-- to (toInventory, toSlot). If toSlot is already occupied, swaps -- the
-- occupant's rows move to (fromInventory, fromSlot) instead of being
-- displaced silently.
--
-- (Weapons review #7) Now ATOMIC. This used to issue N independent UPDATEs:
-- first relocating the occupant to the source slot, then the moving stack to
-- the target. A failure between those two loops left the occupant already
-- moved and the moving stack not -- BOTH stacks in the source compartment and
-- the target empty. Nothing is lost, but the placement is corrupt and no
-- retry repairs it. One transaction makes it all-or-nothing, and the rows are
-- locked so a concurrent move cannot interleave with the swap.
--
-- Guards receive the locked row snapshot, so they run inside the transaction
-- without re-querying the locked item through another connection.
function InventoryControllers.MoveSlotItems(fromInventory, fromSlot, toInventory, toSlot, context)
  local crossInventory = tostring(fromInventory) ~= tostring(toInventory)
  context = MutationContext(context, 'slot_move')
  local movedRows, occupantRows = {}, {}
  local movedFacts, occupantFacts = {}, {}
  local failureCode, failureMessage

  local executed, committed = pcall(MySQL.startTransaction, function(query)
    if not ContextCanAccess(context, fromInventory, InventoryAPI.AccessModes.REMOVE)
      or (crossInventory and not ContextCanAccess(context, toInventory, InventoryAPI.AccessModes.INSERT)) then
      return false
    end
    -- Lock policy rows first, then all item rows in inventory/id order. This
    -- matches the capacity pipeline and prevents lock-order inversion between
    -- swaps and grants/transfers.
    local accepted, code, message, moving, occupant = SlotMoveAcceptanceInTransaction(
      query, fromInventory, fromSlot, toInventory, toSlot)
    if not accepted then
      failureCode, failureMessage = code, message
      return false
    end

    if crossInventory then
      for _, row in ipairs(moving) do
        local allowed = GuardsAPI.CanMoveInstanceSnapshot(NormalizeLockedItem(row), context)
        if not allowed then return false end
        movedFacts[tonumber(row.id)] = {
          definitionId = tonumber(row.item_id), revision = (tonumber(row.row_revision) or 0) + 1 }
      end
      local swapContext = MutationContext(context, 'slot_swap')
      for _, row in ipairs(occupant or {}) do
        local allowed = GuardsAPI.CanMoveInstanceSnapshot(NormalizeLockedItem(row), swapContext)
        if not allowed then return false end
        occupantFacts[tonumber(row.id)] = {
          definitionId = tonumber(row.item_id), revision = (tonumber(row.row_revision) or 0) + 1 }
      end
    end

    local revisionBump = crossInventory and ', `row_revision`=`row_revision`+1' or ''

    for _, row in ipairs(occupant or {}) do
      query('UPDATE `inventory_items` SET `inventory_id`=?, `slot_index`=?' .. revisionBump .. ' WHERE `id`=?;',
        { fromInventory, fromSlot, row.id })
      occupantRows[#occupantRows + 1] = tonumber(row.id)
    end

    for _, row in ipairs(moving) do
      query('UPDATE `inventory_items` SET `inventory_id`=?, `slot_index`=?' .. revisionBump .. ' WHERE `id`=?;',
        { toInventory, toSlot, row.id })
      movedRows[#movedRows + 1] = tonumber(row.id)
    end

    return true
  end)

  if not executed or committed ~= true then
    return false, failureCode or 'conflict', failureMessage or 'The inventory changed; try again.'
  end

  -- Post-commit only, and only when the item actually changed inventory --
  -- rearranging compartments within one book is not a movement.
  if crossInventory then
    for _, id in ipairs(movedRows) do
      GuardsAPI.EmitItemMoved(id, fromInventory, toInventory, context, movedFacts[id])
    end
    local swapContext = MutationContext(context, 'slot_swap')
    for _, id in ipairs(occupantRows) do
      GuardsAPI.EmitItemMoved(id, toInventory, fromInventory, swapContext, occupantFacts[id])
    end
  end

  return #movedRows > 0
end

-- (§10.1 split stack) The partial form of MoveSlotItems: peels `quantity`
-- units out of (inventory, fromSlot) into (inventory, toSlot) and leaves the
-- remainder where it was. Same-inventory only -- splitting across inventories
-- would be a capacity-affecting transfer and belongs on the MoveItem path
-- (EvaluateSlotMove), not here.
--
-- Rows are re-read from the slot rather than taken from a client-supplied
-- list, and the UPDATE is scoped by `inventory_id` as well as `id`, so a row
-- that isn't actually in this inventory can't be dragged in by naming its id.
function InventoryControllers.SplitSlotItems(inventory, fromSlot, toSlot, quantity, context)
  local wanted = math.floor(tonumber(quantity) or 0)
  if wanted < 1 then return 0 end
  local moved = 0

  local executed, committed = pcall(MySQL.startTransaction, function(query)
    if not ContextCanAccess(context, inventory, InventoryAPI.AccessModes.REMOVE) then return false end
    local source = query(
      'SELECT `id` FROM `inventory_items` WHERE `inventory_id`=? AND `slot_index`=? ORDER BY `id` FOR UPDATE;',
      { inventory, fromSlot })
    local target = query(
      'SELECT `id` FROM `inventory_items` WHERE `inventory_id`=? AND `slot_index`=? ORDER BY `id` FOR UPDATE;',
      { inventory, toSlot })

    -- Revalidate the UI preflight at commit time: the source must still have
    -- a remainder and the destination compartment must still be free.
    if not source or wanted >= #source or (target and #target > 0) then
      return false
    end

    for index = 1, wanted do
      local changed = query(
        'UPDATE `inventory_items` SET `slot_index`=? WHERE `id`=? AND `inventory_id`=? AND `slot_index`=?;',
        { toSlot, source[index].id, inventory, fromSlot })
      local affected = tonumber(changed and (changed.affectedRows or changed.affected_rows)) or 0
      if affected ~= 1 then return false end
      moved = moved + 1
    end
    return true
  end)

  if not executed or committed ~= true then return 0 end
  return moved
end

-- Metadata lives entirely on `inventory_items.metadata` -- a versioned JSON
-- document with compare-and-set on `row_revision`. The old flat key/value
-- table is neither read nor written here, and this resource no longer uses
-- its name anywhere: the payload field the ledger reads is `metadata`, not
-- the `item_metadata` alias it carried while both existed.
--
-- The table itself is being removed at its source -- `feather-recipe` stops
-- creating it -- rather than dropped from here. See MASTER_PLAN §6.2.

-- (INV-W3) Destroy guard + post-commit event. Same chokepoint reasoning as
-- the move path: guarding here covers every removal route rather than
-- trusting each caller to remember.
function InventoryControllers.DeleteInventoryItemGuarded(id, context)
  if not GuardsAPI.CanDestroyInstance(id, context or { reason = 'destroy' }) then
    return false
  end

  local instance = InventoryControllers.GetInventoryItemById(id)
  InventoryControllers.DeleteInventoryItem(id)

  if instance then
    GuardsAPI.EmitItemDestroyed(id, instance.item_id, instance.inventory_id, context)
  end
  return true
end

function InventoryControllers.DeleteInventoryItem(id)
  -- (INV-08) `LIMIT;` with no number is a SQL syntax error -- this deletes
  -- by unique `id` already, so no LIMIT clause is needed at all.
  MySQL.query.await('DELETE FROM `inventory_items` WHERE `id`=?;', { id })
end

-- (Weapons review #8) Which instance rows a quantity-based removal will
-- actually delete. DeleteInventoryItems removes by LIMIT, so without this
-- the caller has no idea which rows went and can only name the definition
-- in its removal event. Ordered by id so it matches LIMIT's default order.
function InventoryControllers.GetInstanceIdsForRemoval(inventory, itemId, quantity)
  local safeQuantity = math.floor(tonumber(quantity) or 0)
  if safeQuantity < 1 then
    return {}
  end
  local rows = MySQL.query.await(
    'SELECT `id` FROM `inventory_items` WHERE `inventory_id`=? AND `item_id`=? ORDER BY `id` LIMIT ' .. safeQuantity .. ';',
    { inventory, itemId })
  local ids = {}
  for _, row in ipairs(rows or {}) do
    ids[#ids + 1] = tonumber(row.id)
  end
  return ids
end

-- (INV-08) `quantity` was concatenated straight into the query string --
-- oxmysql can't bind LIMIT's argument as a `?` parameter, but it must still
-- never be trusted as raw client input. `quantity` today only ever comes
-- from server-side callers, but tonumber+math.floor here makes that a
-- guarantee of this function rather than an assumption about its callers.
function InventoryControllers.DeleteInventoryItems(inventory, itemId, quantity)
  local safeQuantity = math.floor(tonumber(quantity) or 0)
  if safeQuantity < 1 then
    return
  end
  local query = 'DELETE FROM `inventory_items` WHERE `inventory_id`=? AND `item_id`=? LIMIT ' .. safeQuantity .. ';'
  MySQL.query.await(query, { inventory, itemId })
end

-- (Drop bugfix) inventory_blacklist has no `id` column at all -- its
-- primary key is the composite (inventory_id, item_id) -- so this query
-- always errored outright ("Unknown column 'id' in 'SELECT'"). Masked until
-- now because every caller reached this through InventoryCanHold, which
-- always rejected one step earlier for an unrelated reason (see
-- InventoryCanHoldById's comment) and never actually got this far.
function InventoryControllers.IsItemRestricted(inventory, itemId)
  local result = MySQL.query.await("SELECT `inventory_id` FROM `inventory_blacklist` WHERE `inventory_id`=? AND `item_id`=?",
    { inventory, itemId })
  if not result[1] then
    return false
  end
  return true
end

function InventoryControllers.UpdateRestrictedItems(inventory, items)
  local result = MySQL.query.await(
    "SELECT `inventory_blacklist`.`inventory_id`, `inventory_blacklist`.`item_id`, `items`.`name` FROM `inventory_blacklist` INNER JOIN `items` ON `items`.`id`=`inventory_blacklist`.`item_id` WHERE `inventory_blacklist`.`inventory_id`=?;",
    { inventory })

  -- Add Restricted Items
  for _, item in pairs(items) do
    local itemId = ItemControllers.GetItemByName(item)
    MySQL.query.await('INSERT IGNORE INTO `inventory_blacklist` (`inventory_id`, `item_id`) VALUES (?,?);',
      { inventory, itemId })
  end

  if result[1] then
    -- Remove no longer restricted items
    for _, item in pairs(result[1]) do
      if not TableContains(items, item.name) then
        MySQL.query.await('DELETE FROM `inventory_blacklist` WHERE `inventory_id`=? AND `item_id`=?',
          { item.inventory_id, item.item_id })
      end
    end
  end
end


------------------------------------------------------------------
-- In-transaction capacity evaluation (Weapons review #7)
------------------------------------------------------------------
--
-- EvaluateInventoryAcceptance and friends use MySQL.query.await, which runs
-- on a DIFFERENT connection from an open transaction. Calling one while
-- holding row locks blocks on those locks forever -- the transaction would be
-- waiting on itself. So an in-transaction capacity check has to be expressed
-- against the transaction's own `query` function, which is what this is.
--
-- Same rules as EvaluateInventoryAcceptance: blacklist, per-item quantity
-- cap, slot capacity accounting for stacking, and weight. Kept deliberately
-- close to it in shape so the two stay comparable when either changes.
--
-- @param query The transaction-bound query function
-- @param inventory Raw inventory.id
-- @param checkItems { { item = name, quantity = n }, ... }
-- @return true, or false plus a code and message
--
function InventoryControllers.AcceptanceInTransaction(query, inventory, checkItems)
  local invRows = query(
    'SELECT `max_weight`, `ignore_item_limit`, `max_slots` FROM `inventory` WHERE `id`=? FOR UPDATE;',
    { inventory })
  local inv = invRows and invRows[1]
  if not inv then
    return false, 'invalid_inventory', 'Inventory does not exist.'
  end

  local ignoreLimits = Boolean[inv.ignore_item_limit] == true
  local capacity = tonumber(inv.max_slots) or tonumber(Config.maxItemSlots) or 0
  local weightLimit = tonumber(inv.max_weight) or tonumber(Config.maxWeight) or 0

  -- Lock every occupied compartment so a concurrent transfer cannot claim the
  -- same free slots between this read and our writes. This lock is the entire
  -- reason two concurrent transfers can no longer both pass the pre-check.
  local occupiedRows = query([[
    SELECT `slot_index`, `item_id`, COUNT(*) AS `count`
    FROM `inventory_items`
    WHERE `inventory_id`=? AND `slot_index` IS NOT NULL
    GROUP BY `slot_index`, `item_id` FOR UPDATE;
  ]], { inventory })

  local occupied, stackRoom = {}, {}
  for _, row in ipairs(occupiedRows or {}) do
    occupied[tonumber(row.slot_index)] = true
    local key = tostring(row.item_id)
    stackRoom[key] = stackRoom[key] or {}
    table.insert(stackRoom[key], tonumber(row.count) or 0)
  end

  local freeSlots = 0
  for index = 0, capacity - 1 do
    if not occupied[index] then
      freeSlots = freeSlots + 1
    end
  end

  local totalWeightRows = query(
    'SELECT COALESCE(SUM(i.`weight`), 0) AS `weight` FROM `inventory_items` ii INNER JOIN `items` i ON i.`id`=ii.`item_id` WHERE ii.`inventory_id`=?;',
    { inventory })
  local currentWeight = tonumber(totalWeightRows and totalWeightRows[1] and totalWeightRows[1].weight) or 0
  local addedWeight = 0

  for _, entry in ipairs(checkItems) do
    local defRows = query(
      'SELECT `id`, `max_quantity`, `max_stack_size`, `weight`, `instance_mode` FROM `items` WHERE `name`=? LIMIT 1;',
      { entry.item })
    local def = defRows and defRows[1]
    if not def then
      return false, 'invalid_item', 'Item does not exist.'
    end

    local restricted = query(
      'SELECT `inventory_id` FROM `inventory_blacklist` WHERE `inventory_id`=? AND `item_id`=? LIMIT 1;',
      { inventory, def.id })
    if restricted and restricted[1] then
      return false, 'item_restricted', 'Item is restricted.'
    end

    local quantity = tonumber(entry.quantity) or 0

    if not ignoreLimits then
      local heldRows = query(
        'SELECT COUNT(`id`) AS `count` FROM `inventory_items` WHERE `inventory_id`=? AND `item_id`=?;',
        { inventory, def.id })
      local held = tonumber(heldRows and heldRows[1] and heldRows[1].count) or 0
      if (held + quantity) > (tonumber(def.max_quantity) or 0) then
        return false, 'item_limit', 'Max Quantity Exceeded.'
      end
    end

    local stackSize = math.max(tonumber(def.max_stack_size) or 1, 1)
    local room = 0
    if def.instance_mode ~= 'unique' then
      for _, used in ipairs(stackRoom[tostring(def.id)] or {}) do
        if used < stackSize then
          room = room + (stackSize - used)
        end
      end
    end

    local overflow = quantity - room
    if overflow > 0 then
      local needed = math.ceil(overflow / stackSize)
      if needed > freeSlots then
        return false, 'inventory_full', 'Inventory has no available slots.'
      end
      freeSlots = freeSlots - needed
    end

    addedWeight = addedWeight + ((tonumber(def.weight) or 0) * quantity)
  end

  if weightLimit > 0 and (currentWeight + addedWeight) > weightLimit then
    return false, 'weight_limit', 'Max Weight Exceeded.'
  end

  return true
end

-- (INV-01 root cause / INV-09) Previously moved every item by raw id with
-- no check that it actually belonged to sourceInventory -- a caller could
-- name any inventory_items.id and pull it out of wherever it actually
-- lived, regardless of sourceInventory. Membership is now verified here so
-- every caller (RPC handlers, GiveItem, any future resource) gets this for
-- free, not just the one call site that happened to get patched. This also
-- fixes the nested-loop bug that fired ItemRemoved/ItemAdded #items^2
-- times instead of once per moved item.
-- (INV-01 root cause / INV-09) Verifies every item actually belongs to
-- sourceInventory before moving it, so a caller cannot name an arbitrary
-- inventory_items.id and pull it out of wherever it really lives.
--
-- (Weapons review #7) Now ATOMIC, with capacity evaluated INSIDE the
-- transaction against locked rows. Previously the capacity check ran before
-- the loop and outside any transaction, so two concurrent transfers could
-- both pass the same pre-check and together overfill the destination. The
-- per-item UPDATEs were also independent, so a failure partway left some
-- items moved and some not.
--
function InventoryControllers.MoveInventoryItems(sourceInventory, targetInventory, items, context)
  context = context or { reason = 'move', resource = GetInvokingResource() or 'feather-inventory' }
  local requested = {}
  for _, item in pairs(items) do
    local id = type(item) == 'table' and item.id or item
    if type(id) ~= 'number' and tonumber(id) == nil then
      warn('Invalid Item type in MoveItems')
      return { error = true, code = 'invalid_input', message = 'Invalid item reference.' }
    end
    requested[#requested + 1] = tonumber(id)
  end

  if #requested == 0 then
    return { error = true, code = 'invalid_input', message = 'No items specified.' }
  end

  local failureCode, failureMessage
  local moved = {}

  local executed, committed = pcall(MySQL.startTransaction, function(query)
    if not ContextCanAccess(context, sourceInventory, InventoryAPI.AccessModes.REMOVE)
      or (not context.allowTargetInsert
        and not ContextCanAccess(context, targetInventory, InventoryAPI.AccessModes.INSERT)) then
      failureCode, failureMessage = 'denied', 'Inventory access changed before the move committed.'
      return false
    end
    -- Lock the rows being moved and confirm membership under that lock, so a
    -- concurrent transfer cannot move them out from under this one between
    -- the check and the write.
    local counts = {}
    for _, id in ipairs(requested) do
      local rows = query([[
        SELECT ii.`id`, ii.`inventory_id`, ii.`slot_index`, ii.`item_id`,
               ii.`metadata`, ii.`row_revision`, i.`name`, i.`display_name`,
               i.`weight`, i.`type`, i.`max_quantity`, i.`max_stack_size`,
               i.`instance_mode`
        FROM `inventory_items` ii INNER JOIN `items` i ON i.`id` = ii.`item_id`
        WHERE ii.`id`=? FOR UPDATE;
      ]], { id })
      local row = rows and rows[1]
      if not row or tostring(row.inventory_id) ~= tostring(sourceInventory) then
        failureCode, failureMessage = 'not_found', 'One or more items are not in the source inventory.'
        return false
      end
      -- Evaluate the guard after locking and verifying the row. A guard result
      -- taken before the transaction could become stale before the UPDATE.
      local allowed, reason = GuardsAPI.CanMoveInstanceSnapshot(NormalizeLockedItem(row), context)
      if not allowed then
        failureCode, failureMessage = 'denied', reason or 'That item cannot be moved right now.'
        return false
      end
      counts[row.name] = (counts[row.name] or 0) + 1
      moved[id] = {
        definitionId = tonumber(row.item_id),
        revision = (tonumber(row.row_revision) or 0) + 1,
      }
    end

    local checkItems = {}
    for name, quantity in pairs(counts) do
      checkItems[#checkItems + 1] = { item = name, quantity = quantity }
    end

    local ok, code, message = InventoryControllers.AcceptanceInTransaction(query, targetInventory, checkItems)
    if not ok then
      failureCode, failureMessage = code, message
      return false
    end

    local capacityRows = query('SELECT `max_slots` FROM `inventory` WHERE `id`=? LIMIT 1;', { targetInventory })
    local capacity = tonumber(capacityRows and capacityRows[1] and capacityRows[1].max_slots)
      or tonumber(Config.maxItemSlots) or 0

    for _, id in ipairs(requested) do
      -- Placement resolved inside the transaction so it sees rows this loop
      -- has already written -- the batched-insert bug GrantItem had, avoided
      -- here by construction.
      local defRows = query([[
        SELECT ii.`item_id`, i.`max_stack_size`, i.`instance_mode`
        FROM `inventory_items` ii INNER JOIN `items` i ON i.`id` = ii.`item_id`
        WHERE ii.`id`=? LIMIT 1;
      ]], { id })
      local def = defRows and defRows[1]
      local stackSize = math.max(tonumber(def and def.max_stack_size) or 1, 1)

      local targetSlot
      if def and def.instance_mode ~= 'unique' then
        local joinable = query([[
          SELECT `slot_index` FROM `inventory_items`
          WHERE `inventory_id`=? AND `item_id`=? AND `slot_index` IS NOT NULL
          GROUP BY `slot_index` HAVING COUNT(*) < ? LIMIT 1;
        ]], { targetInventory, def.item_id, stackSize })
        targetSlot = joinable and joinable[1] and tonumber(joinable[1].slot_index) or nil
      end

      if targetSlot == nil then
        local usedRows = query(
          'SELECT DISTINCT `slot_index` FROM `inventory_items` WHERE `inventory_id`=? AND `slot_index` IS NOT NULL;',
          { targetInventory })
        local used = {}
        for _, row in ipairs(usedRows or {}) do
          used[tonumber(row.slot_index)] = true
        end
        for index = 0, capacity - 1 do
          if not used[index] then
            targetSlot = index
            break
          end
        end
      end

      if targetSlot == nil then
        failureCode, failureMessage = 'inventory_full', 'Inventory has no available slots.'
        return false
      end

      query(
        'UPDATE `inventory_items` SET `inventory_id`=?, `slot_index`=?, `row_revision`=`row_revision`+1 WHERE `id`=?;',
        { targetInventory, targetSlot, id })
    end

    return true
  end)

  if not executed or committed ~= true then
    return {
      error = true,
      code = failureCode or 'internal',
      message = failureMessage or 'Items could not be moved.',
      sourceItems = InventoryControllers.GetInventoryItems(sourceInventory),
      targetItems = InventoryControllers.GetInventoryItems(targetInventory)
    }
  end

  for _, id in ipairs(requested) do
    local entry = moved[id] or {}
    GuardsAPI.EmitItemMoved(id, sourceInventory, targetInventory, context, entry)
  end

  return {
    sourceItems = InventoryControllers.GetInventoryItems(sourceInventory),
    targetItems = InventoryControllers.GetInventoryItems(targetInventory)
  }
end
