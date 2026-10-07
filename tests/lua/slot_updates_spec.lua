-- Deterministic controller/adapter tests with a transactional SQL model.
-- This is not a substitute for MariaDB locks or two-player game acceptance.
local root = arg and arg[1] or '.'
Config = { UpdateBatchSize = 100, maxItemSlots = 20, maxWeight = 1000 }
Boolean = { [true] = true, [false] = false, [1] = true, [0] = false }
local convars, rows, policies, definitions, restrictions, events, writes, failWrite, throwWrite, denied, accessDenied, preflightReads, groundCreated, broadcasts, containerEvents, beforeTransaction
local clock = 0
GetGameTimer = function() clock = clock + 1; return clock end
GetConvarInt = function(name, fallback) return convars[name] or fallback end
GetInvokingResource = function() return 'test' end
AddEventHandler = function() end
warn = function() end
TriggerEvent = function() containerEvents = containerEvents + 1 end
json = { decode = function(value) return { value = value } end, encode = function() return '{}' end }
Result = { IsOk = function(result) return result.ok end }
InventoryAPI = { AccessModes = { REMOVE = 'remove', INSERT = 'insert' },
  CanAccessInventory = function() return { ok = not accessDenied } end }
GuardsAPI = {
  PrepareDestroySnapshots = function() return true end,
  CanDestroyInstanceSnapshot = function(item) return item.id ~= denied end,
  EmitItemCreated = function(id) events[#events + 1] = { id = id } end,
  EmitItemDestroyed = function(id) events[#events + 1] = { id = id } end,
  EmitTransactionCommitted = function() end,
  PrepareMoveSnapshots = function() return true end,
  CanMoveInstanceSnapshot = function(item) return item.id ~= denied end,
  EmitItemMoved = function(id, source, destination, context, fact)
    events[#events + 1] = { id = id, source = source, destination = destination, revision = fact.revision }
  end,
}
local function copy(value)
  if type(value) ~= 'table' then return value end
  local result = {}; for key, entry in pairs(value) do result[key] = copy(entry) end; return result
end
local function selectRows(predicate)
  local result = {}
  for _, row in ipairs(rows) do
    if predicate(row) then
      local entry = copy(row)
      for _, field in ipairs({'max_quantity', 'max_stack_size', 'instance_mode'}) do
        entry[field] = definitions[row.item_id][field]
      end
      result[#result + 1] = entry
    end
  end
  table.sort(result, function(a, b) return a.id < b.id end)
  return result
end
local function query(sql, params)
  if sql:match('^INSERT INTO `inventory_items`') then
    writes = writes + 1
    if writes == throwWrite then error('injected insert failure') end
    local inserted = {}
    local units = 0; for _ in sql:gmatch('%?') do units = units + 1 end
    for offset = 0, units - 4, 4 do
      local maximum = 0; for _, row in ipairs(rows) do maximum = math.max(maximum, row.id) end
      local def = definitions[params[offset + 2]]
      local row = { id = maximum + 1, inventory_id = params[offset + 1], item_id = params[offset + 2],
        slot_index = params[offset + 3], metadata = params[offset + 4], row_revision = 0,
        name = def.name, weight = def.weight, instance_mode = def.instance_mode }
      rows[#rows + 1] = row; inserted[#inserted + 1] = { id = row.id }
    end
    if writes == failWrite then table.remove(inserted) end
    return inserted
  elseif sql:match('^UPDATE') then
    writes = writes + 1
    if writes == throwWrite then error('injected SQL failure') end
    assert(sql:find('`row_revision`=`row_revision`+1', 1, true))
    assert(sql:find('WHERE `inventory_id`=?', 1, true) and sql:find('AND `id` IN', 1, true))
    local slotScoped = sql:find('AND `slot_index`=?', 1, true)
    local selected = {}; for index = slotScoped and 5 or 4, #params do selected[params[index]] = true end
    local affected = 0
    for _, row in ipairs(rows) do
      if selected[row.id] and row.inventory_id == params[3] and (not slotScoped or row.slot_index == params[4]) then
        row.inventory_id, row.slot_index = params[1], params[2]
        row.row_revision = row.row_revision + 1
        affected = affected + 1
      end
    end
    return { affectedRows = writes == failWrite and affected - 1 or affected }
  elseif sql:find('DELETE FROM `inventory_items`', 1, true) then
    writes = writes + 1
    local selected, remaining, affected = {}, {}, 0
    local scopedDefinition = sql:find('AND `item_id`=?', 1, true)
    for index = scopedDefinition and 3 or 2, #params do selected[params[index]] = true end
    for _, row in ipairs(rows) do
      if row.inventory_id == params[1] and (not scopedDefinition or row.item_id == params[2]) and selected[row.id] then affected = affected + 1
      else remaining[#remaining + 1] = row end
    end
    rows = remaining
    return { affectedRows = writes == failWrite and affected - 1 or affected }
  elseif sql:find('DELETE FROM `inventory`', 1, true) then
    if policies[params[1]] and policies[params[1]].location == params[2] then
      policies[params[1]] = nil; return { affectedRows = 1 }
    end
    return { affectedRows = 0 }
  elseif sql:find('WHERE ii.`inventory_id` IN', 1, true) and not sql:find('FOR UPDATE', 1, true) then
    return selectRows(function(row) return row.inventory_id == params[1] or row.inventory_id == params[2] end)
  elseif sql:find('FROM `inventory`', 1, true) then
    assert(sql:find('FOR UPDATE', 1, true) or sql:find('SELECT `max_slots`', 1, true), 'Policy must be locked')
    local result, seen = {}, {}
    for _, id in ipairs(params) do
      if policies[id] and not seen[id] then result[#result + 1] = copy(policies[id]); seen[id] = true end
    end
    return result
  elseif sql:find('FROM `inventory_blacklist`', 1, true) then
    if #params == 1 then
      local result = {}
      for key, restricted in pairs(restrictions) do
        local inventory, item = key:match('^(%d+):(%d+)$')
        if restricted and tonumber(inventory) == params[1] then result[#result + 1] = {item_id = tonumber(item)} end
      end
      return result
    end
    return restrictions[tostring(params[1]) .. ':' .. tostring(params[2])] and { { inventory_id = params[1] } } or {}
  elseif sql:find('FROM `items` WHERE `id`', 1, true) then
    return definitions[params[1]] and { copy(definitions[params[1]]) } or {}
  elseif sql:find('FROM `items` WHERE `name`', 1, true) then
    for _, def in pairs(definitions) do if def.name == params[1] then return { copy(def) } end end
    return {}
  elseif sql:find('COALESCE(SUM', 1, true) then
    local weight = 0
    for _, row in ipairs(rows) do if row.inventory_id == params[1] then weight = weight + row.weight end end
    return { { weight = weight } }
  elseif sql:find('GROUP BY `slot_index`', 1, true) then
    local groups = {}
    for _, row in ipairs(rows) do
      if row.inventory_id == params[1] then
        local key = row.slot_index .. ':' .. row.item_id
        groups[key] = groups[key] or { slot_index = row.slot_index, item_id = row.item_id, count = 0 }
        groups[key].count = groups[key].count + 1
      end
    end
    local result = {}; for _, group in pairs(groups) do result[#result + 1] = group end; return result
  elseif sql:find('SELECT COUNT(`id`)', 1, true) then
    return { { count = #selectRows(function(row) return row.inventory_id == params[1] and row.item_id == params[2] end) } }
  elseif sql:find('FROM `inventory_items`', 1, true) then
    if sql:find('WHERE `inventory_id`=? AND `id` IN', 1, true) then
      preflightReads = preflightReads + 1
      local selected = {}; for index = 2, #params do selected[params[index]] = true end
      return selectRows(function(row) return row.inventory_id == params[1] and selected[row.id] end)
    end
    if sql:find('`slot_index` IS NOT NULL', 1, true) then
      return selectRows(function(row) return row.inventory_id == params[1] and row.slot_index ~= nil end)
    end
    assert(sql:find('FOR UPDATE', 1, true), 'Item snapshot must be locked')
    if sql:find('WHERE ii.`inventory_id`=? AND ii.`item_id`=?', 1, true) then
      local selected
      if sql:find('AND ii.`id` IN', 1, true) then
        selected = {}; for index = 3, #params do selected[params[index]] = true end
      end
      local result = selectRows(function(row)
        return row.inventory_id == params[1] and row.item_id == params[2] and (not selected or selected[row.id])
      end)
      local limit = tonumber(sql:match('LIMIT (%d+)'))
      if limit then while #result > limit do table.remove(result) end end
      return result
    end
    if sql:find('WHERE ii.`id` IN', 1, true) then
      local selected = {}; for _, id in ipairs(params) do selected[id] = true end
      return selectRows(function(row) return selected[row.id] end)
    end
    if sql:find('WHERE ii.`inventory_id` IN', 1, true) then
      return selectRows(function(row) return row.inventory_id == params[1] or row.inventory_id == params[2] end)
    end
    if sql:find('AND', 1, true) then
      return selectRows(function(row) return row.inventory_id == params[1] and row.slot_index == params[2] end)
    end
    return selectRows(function(row) return row.inventory_id == params[1] end)
  end
  error('Unexpected SQL: ' .. sql)
end
DB = { transaction = function(body)
  if beforeTransaction then local hook = beforeTransaction; beforeTransaction = nil; hook() end
  local snapshot = copy(rows)
  local policySnapshot = copy(policies)
  local ok, result = pcall(body, { raw = function(sql, ...) return query(sql, { ... }) end })
  if not ok or result ~= true then rows, policies = snapshot, policySnapshot end
  if not ok then error(result) end
  return result == true
end, query = function(sql, ...) return query(sql, { ... }) end }
dofile(root .. '/server/helpers/mutation_metrics.lua')
dofile(root .. '/server/helpers/metadata_compatibility.lua')
dofile(root .. '/server/helpers/move_planner.lua')
dofile(root .. '/server/services/transactions.lua')
dofile(root .. '/server/controllers/inventory.lua')
InventoryControllers.GetInventoryItems = function(inventory)
  return selectRows(function(row) return row.inventory_id == inventory end)
end
dofile(root .. '/server/helpers/result.lua')
dofile(root .. '/server/services/items.lua')
GroundControllers = {
  GetClosestGroundByCoords = function() return 1 end,
  CreateGround = function() groundCreated = groundCreated + 1; return { {id = 1} } end,
}
InventoryAPI.RegisterInventory = function() return Result.Ok({ id = 2 }) end
UpdateClientWithGroundLocations = function() broadcasts = broadcasts + 1 end
Config.Dropped = { GroupingRadius = 1 }

local function reset()
  Config.UpdateBatchSize, Config.MutationTiming = 100, false
  convars, rows, definitions, restrictions, events = {}, {}, {}, {}, {}
  writes, failWrite, throwWrite, denied, accessDenied = 0, nil, nil, nil, false
  preflightReads, groundCreated, broadcasts, containerEvents = 0, 0, 0, 0
  beforeTransaction = nil
  policies = {
    [1] = { id = 1, max_slots = 20, max_weight = 1000, ignore_item_limit = 0, uuid = 'one', location = 'storage' },
    [2] = { id = 2, max_slots = 20, max_weight = 1000, ignore_item_limit = 0 },
  }
end
local function add(amount, inventory, slot, definition, weight, metadata)
  definitions[definition] = definitions[definition] or { id = definition, name = 'item' .. definition,
    max_quantity = 10000, max_stack_size = 1000, weight = weight, instance_mode = 'stack' }
  for _ = 1, amount do
    rows[#rows + 1] = { id = #rows + 1, inventory_id = inventory, slot_index = slot, item_id = definition,
      metadata = metadata or '{}', row_revision = 4, name = 'item' .. definition, weight = weight,
      max_quantity = definitions[definition].max_quantity, max_stack_size = definitions[definition].max_stack_size,
      instance_mode = 'stack' }
  end
end
local function count(inventory, slot)
  return #selectRows(function(row) return row.inventory_id == inventory and row.slot_index == slot end)
end
local function unchanged(snapshot)
  assert(#rows == #snapshot and #events == 0)
  for index, row in ipairs(rows) do
    for key, value in pairs(row) do assert(value == snapshot[index][key], 'Rollback changed ' .. key) end
  end
end
local total = 0
local function test(name, body)
  reset(); body(); total = total + 1; print('PASS ' .. name)
end

test('200 rows become two writes; IDs, metadata, revisions and events preserved', function()
  add(200, 1, 0, 1, 1, 'document')
  assert(InventoryControllers.MoveSlotItems(1, 0, 2, 0))
  assert(writes == 2 and count(2, 0) == 200 and #events == 200)
  for index, row in ipairs(rows) do assert(row.id == index and row.metadata == 'document' and row.row_revision == 5) end
end)
test('batch-size 1 provides the sequential-write comparison', function()
  Config.UpdateBatchSize = 1; add(200, 1, 0, 1, 1)
  assert(InventoryControllers.MoveSlotItems(1, 0, 2, 0)); assert(writes == 200)
end)
test('swaps use captured IDs and increment both sides once', function()
  add(150, 1, 0, 1, 1); add(120, 2, 1, 2, 1)
  assert(InventoryControllers.MoveSlotItems(1, 0, 2, 1))
  assert(writes == 4 and count(1, 0) == 120 and count(2, 1) == 150 and #events == 270)
  for _, row in ipairs(rows) do assert(row.row_revision == 5) end
end)
test('later chunk mismatch rolls back earlier writes and emits nothing', function()
  add(201, 1, 0, 1, 1); local before = copy(rows); failWrite = 2
  assert(not InventoryControllers.MoveSlotItems(1, 0, 2, 0)); assert(writes == 2); unchanged(before)
end)
test('swap failure rolls back the already-relocated occupant', function()
  add(101, 1, 0, 1, 1); add(5, 2, 1, 2, 1); local before = copy(rows); failWrite = 3
  assert(not InventoryControllers.MoveSlotItems(1, 0, 2, 1)); unchanged(before)
end)
test('SQL exception rolls back the entire move', function()
  add(101, 1, 0, 1, 1); local before = copy(rows); throwWrite = 2
  assert(not InventoryControllers.MoveSlotItems(1, 0, 2, 0)); unchanged(before)
end)
test('duplicate locked IDs cannot be written twice', function()
  add(2, 1, 0, 1, 1); rows[2].id = rows[1].id
  local before = copy(rows)
  assert(not InventoryControllers.MoveSlotItems(1, 0, 2, 0) and writes == 0); unchanged(before)
end)
test('out-of-range configured batch sizes are bounded', function()
  Config.UpdateBatchSize = 999; add(201, 1, 0, 1, 1)
  assert(InventoryControllers.MoveSlotItems(1, 0, 2, 0) and writes == 2)
  Config.UpdateBatchSize = 0
  assert(InventoryControllers.MoveSlotItems(2, 0, 1, 0) and writes == 203)
end)
for _, destination in ipairs({1, 2}) do
  test('weight limit rejects overfill of inventory ' .. destination, function()
    local source = destination == 1 and 2 or 1
    add(2, source, 0, 1, 6); policies[destination].max_weight = 11; local before = copy(rows)
    local moved, code = InventoryControllers.MoveSlotItems(source, 0, destination, 0)
    assert(not moved and code == 'weight_limit' and writes == 0); unchanged(before)
  end)
end
test('exact weight boundary succeeds', function()
  add(2, 1, 0, 1, 6); policies[2].max_weight = 12
  assert(InventoryControllers.MoveSlotItems(1, 0, 2, 0))
end)
test('NULL weight uses configured fallback while zero remains unlimited', function()
  add(2, 1, 0, 1, 600); policies[2].max_weight = nil
  assert(not InventoryControllers.MoveSlotItems(1, 0, 2, 0))
  policies[2].max_weight = 0
  assert(InventoryControllers.MoveSlotItems(1, 0, 2, 0))
end)
test('reverse side of swap must fit the heavier occupant', function()
  add(1, 1, 0, 1, 1); add(1, 2, 0, 2, 5); policies[1].max_weight = 4
  local before = copy(rows); assert(not InventoryControllers.MoveSlotItems(1, 0, 2, 0)); unchanged(before)
end)
test('slot boundary is checked against locked destination policy', function()
  add(2, 1, 0, 1, 1); policies[2].max_slots = 1
  local moved, code = InventoryControllers.MoveSlotItems(1, 0, 2, 1)
  assert(not moved and code == 'invalid_slot' and writes == 0)
end)
test('occupied final slot can swap without creating a new slot', function()
  policies[1].max_slots, policies[2].max_slots = 1, 1
  add(2, 1, 0, 1, 1); add(1, 2, 0, 2, 1)
  assert(InventoryControllers.MoveSlotItems(1, 0, 2, 0)); assert(count(1, 0) == 1 and count(2, 0) == 2)
end)
test('quantity limit and blacklist still reject before writes', function()
  add(2, 1, 0, 1, 1); definitions[1].max_quantity = 1
  assert(not InventoryControllers.MoveSlotItems(1, 0, 2, 0)); assert(writes == 0)
  definitions[1].max_quantity = 10000
  restrictions['2:1'] = true
  assert(not InventoryControllers.MoveSlotItems(1, 0, 2, 0)); assert(writes == 0)
end)
test('ignore quantity policy does not bypass weight limits', function()
  add(2, 1, 0, 1, 6); policies[2].ignore_item_limit = 1; policies[2].max_weight = 11
  assert(not InventoryControllers.MoveSlotItems(1, 0, 2, 0)); assert(writes == 0)
end)
test('guard and revoked access failures emit no events', function()
  add(2, 1, 0, 1, 1); local before = copy(rows); denied = 2
  assert(not InventoryControllers.MoveSlotItems(1, 0, 2, 0)); unchanged(before)
  denied = nil; accessDenied = true
  assert(not InventoryControllers.MoveSlotItems(1, 0, 2, 0, { actorSource = 1 })); unchanged(before)
end)
test('same-inventory swap preserves total weight and row identities', function()
  add(2, 1, 0, 1, 1); add(3, 1, 1, 2, 1)
  assert(InventoryControllers.MoveSlotItems(1, 0, 1, 1)); assert(count(1, 0) == 3 and count(1, 1) == 2)
end)
test('partial merge moves only the available compatible stack space', function()
  add(200, 1, 0, 1, 1); add(200, 2, 0, 1, 1)
  definitions[1].max_stack_size = 300
  for _, row in ipairs(rows) do row.max_stack_size = 300 end
  local moved = InventoryControllers.MoveSlotItemsPartial(1, 0, 2, 0, 200)
  assert(moved == 100 and writes == 1 and count(1, 0) == 100 and count(2, 0) == 300 and #events == 100)
end)
test('merge checks weight under the transaction', function()
  add(2, 1, 0, 1, 6); add(1, 2, 0, 1, 6); policies[2].max_weight = 11
  local before = copy(rows)
  assert(InventoryControllers.MoveSlotItemsPartial(1, 0, 2, 0, 1) == 0); unchanged(before)
end)
test('merge failure in a later chunk retains source and target records', function()
  add(201, 1, 0, 1, 1); add(1, 2, 0, 1, 1); local before = copy(rows); failWrite = 2
  assert(InventoryControllers.MoveSlotItemsPartial(1, 0, 2, 0, 201) == 0); unchanged(before)
end)
test('incompatible metadata cannot merge', function()
  add(2, 1, 0, 1, 1, 'one'); add(1, 2, 0, 1, 1, 'two')
  assert(InventoryControllers.MoveSlotItemsPartial(1, 0, 2, 0, 1) == 0 and writes == 0)
end)
test('split batches the exact selected subset and retains remainder', function()
  add(250, 1, 0, 1, 1)
  assert(InventoryControllers.SplitSlotItems(1, 0, 1, 200) == 200)
  assert(writes == 2 and count(1, 0) == 50 and count(1, 1) == 200 and #events == 200)
end)
test('split chunk mismatch rolls everything back', function()
  add(250, 1, 0, 1, 1); local before = copy(rows); failWrite = 2
  assert(InventoryControllers.SplitSlotItems(1, 0, 1, 200) == 0); unchanged(before)
end)
test('split cannot target occupied or out-of-range slots', function()
  add(3, 1, 0, 1, 1); add(1, 1, 1, 2, 1)
  assert(InventoryControllers.SplitSlotItems(1, 0, 1, 1) == 0)
  policies[1].max_slots = 2
  assert(InventoryControllers.SplitSlotItems(1, 0, 2, 1) == 0 and writes == 0)
end)
test('opt-in metrics count writes and disabled timings preserve envelopes', function()
  assert(InventoryMutationMetrics.Begin('test') == nil)
  local response = {}; assert(InventoryMutationMetrics.Finish(nil, response) == response and next(response) == nil)
  Config.MutationTiming = true
  local metrics = InventoryMutationMetrics.Begin('test', 'nui-1')
  add(200, 1, 0, 1, 1)
  assert(InventoryControllers.MoveSlotItems(1, 0, 2, 0, { _timing = metrics }))
  assert(metrics.committed and metrics.updateStatements == 2 and metrics.plannedRows == 200 and metrics.batchSize == 100)
  assert(metrics.sqlStatements == 5, 'Restriction read must occur once per definition, not once per row')
  assert(metrics.transactionMs > 0 and metrics.sqlMs > 0)
  assert(InventoryMutationMetrics.Begin('test', 'bad\ntrace').traceId == nil)
end)
test('adapter preserves NULL trailing parameters with timings on and off', function()
  local original = DB.transaction
  DB.transaction = function(body)
    return body({ raw = function(sql, ...)
      local values = table.pack(...); assert(values.n == 2 and values[1] == 1 and values[2] == nil); return {}
    end })
  end
  for _, enabled in ipairs({0, 1}) do
    Config.MutationTiming = enabled == 1
    local ok, committed = RunLegacyStyleTransaction(function(bound)
      bound('SELECT ?, ?', {1, nil}); return true
    end, InventoryMutationMetrics.Begin('adapter'))
    assert(ok and committed)
  end
  DB.transaction = original
end)
local function ids(inventory)
  local result = {}; for _, row in ipairs(rows) do if row.inventory_id == inventory then result[#result + 1] = row.id end end
  return result
end
test('automatic placement batches a 200-record stack into two writes', function()
  add(200, 1, 0, 1, 1)
  local result = InventoryControllers.MoveInventoryItems(1, 2, ids(1))
  assert(not result.error and writes == 2 and count(2, 0) == 200 and #events == 200)
  assert(#result.sourceItems == 0 and #result.targetItems == 200)
  for _, row in ipairs(rows) do assert(row.row_revision == 5 and row.metadata == '{}') end
end)
test('automatic placement obeys the live batch-size comparison', function()
  Config.UpdateBatchSize = 1; add(200, 1, 0, 1, 1)
  assert(not InventoryControllers.MoveInventoryItems(1, 2, ids(1)).error and writes == 200)
end)
test('automatic placement finishes planning before writing any group', function()
  add(2, 1, 0, 1, 1, 'source'); add(1, 2, 0, 1, 1, 'different')
  policies[2].max_slots = 1
  local before = copy(rows); local result = InventoryControllers.MoveInventoryItems(1, 2, ids(1))
  assert(result.error and result.code == 'inventory_full' and writes == 0); unchanged(before)
end)
test('automatic placement fills compatible room then uses a new slot', function()
  add(6, 1, 0, 1, 1); add(4, 2, 0, 1, 1); definitions[1].max_stack_size = 5
  for _, row in ipairs(rows) do row.max_stack_size = 5 end
  assert(not InventoryControllers.MoveInventoryItems(1, 2, ids(1)).error)
  assert(count(2, 0) == 5 and count(2, 1) == 5 and writes == 2 and #events == 6)
end)
test('unique records remain in distinct slots', function()
  add(3, 1, 0, 1, 1)
  definitions[1].instance_mode, definitions[1].max_stack_size = 'unique', 1
  for _, row in ipairs(rows) do row.instance_mode, row.max_stack_size = 'unique', 1 end
  assert(not InventoryControllers.MoveInventoryItems(1, 2, ids(1)).error)
  assert(count(2, 0) == 1 and count(2, 1) == 1 and count(2, 2) == 1)
end)
test('automatic placement chunk mismatch rolls back all groups', function()
  add(201, 1, 0, 1, 1); failWrite = 2; local before = copy(rows)
  local result = InventoryControllers.MoveInventoryItems(1, 2, ids(1))
  assert(result.error and result.code == 'conflict'); unchanged(before)
end)
test('automatic placement supports previously unplaced source rows', function()
  add(2, 1, 0, 1, 1); for _, row in ipairs(rows) do row.slot_index = nil end
  assert(not InventoryControllers.MoveInventoryItems(1, 2, ids(1)).error and count(2, 0) == 2)
end)
test('automatic placement rejects duplicate and invalid IDs', function()
  add(1, 1, 0, 1, 1)
  for _, references in ipairs({{1, 1}, {0}, {-1}, {1.5}, {}, {'bad'}}) do
    local result = InventoryControllers.MoveInventoryItems(1, 2, references)
    assert(result.error and result.code == 'invalid_input' and writes == 0)
  end
end)
test('automatic placement verifies locked ownership and guards', function()
  add(1, 1, 0, 1, 1); add(1, 2, 0, 1, 1); local before = copy(rows)
  assert(InventoryControllers.MoveInventoryItems(1, 2, {2}).code == 'not_found'); unchanged(before)
  denied = 1
  assert(InventoryControllers.MoveInventoryItems(1, 2, {1}).code == 'denied'); unchanged(before)
end)
for _, destination in ipairs({1, 2}) do
  test('automatic placement enforces weight and quantity for inventory ' .. destination, function()
    local source = destination == 1 and 2 or 1
    add(2, source, 0, 1, 6); policies[destination].max_weight = 11
    assert(InventoryControllers.MoveInventoryItems(source, destination, ids(source)).code == 'weight_limit' and writes == 0)
    policies[destination].max_weight = 12; definitions[1].max_quantity = 1
    assert(InventoryControllers.MoveInventoryItems(source, destination, ids(source)).code == 'item_limit' and writes == 0)
    definitions[1].max_quantity = 2
    assert(not InventoryControllers.MoveInventoryItems(source, destination, ids(source)).error)
  end)
end
test('automatic placement enforces blacklist and final-slot capacity', function()
  add(2, 1, 0, 1, 1); restrictions['2:1'] = true
  assert(InventoryControllers.MoveInventoryItems(1, 2, ids(1)).code == 'item_restricted' and writes == 0)
  restrictions = {}; policies[2].max_slots = 1; definitions[1].max_stack_size = 1
  assert(InventoryControllers.MoveInventoryItems(1, 2, ids(1)).code == 'inventory_full' and writes == 0)
end)
test('automatic placement reports controller SQL counts when timing is enabled', function()
  Config.MutationTiming = true; add(200, 1, 0, 1, 1)
  local result = InventoryControllers.MoveInventoryItems(1, 2, ids(1), { reason = 'ground_drop' })
  assert(result.mutationTiming.operation == 'move_items' and result.mutationTiming.reason == 'ground_drop')
  assert(result.mutationTiming.updateStatements == 2 and result.mutationTiming.committed)
end)
test('recovery deletes its source only after all grouped updates commit', function()
  add(200, 1, 0, 1, 1)
  local result = InventoryControllers.MoveInventoryItems(1, 2, ids(1), {deleteSource = {expectedLocation = 'storage'}})
  assert(not result.error and policies[1] == nil and containerEvents == 1 and #events == 200)
end)
test('recovery with remaining source rows rolls back grouped updates', function()
  add(201, 1, 0, 1, 1); local before = copy(rows)
  local selected = {}; for index = 1, 200 do selected[index] = index end
  local result = InventoryControllers.MoveInventoryItems(1, 2, selected, {deleteSource = {expectedLocation = 'storage'}})
  assert(result.error and result.code == 'conflict' and policies[1] and containerEvents == 0); unchanged(before)
end)
test('ground drop uses bounded preflight reads and the grouped mutation path', function()
  add(201, 1, 0, 1, 1); policies[2].max_weight = 0
  local result = ItemsAPI.DropItemsOnGround(1, ids(1), 0, 0, 0, {reason = 'ground_drop'})
  assert(Result.IsOk(result) and preflightReads == 2 and writes == 3 and broadcasts == 1)
  assert(count(2, 0) == 201 and #result.value.inventory.sourceItems == 0)
end)
test('ground drop rejects foreign IDs before creating or broadcasting a pile', function()
  add(1, 2, 0, 1, 1)
  local result = ItemsAPI.DropItemsOnGround(1, {1}, 0, 0, 0)
  assert(not Result.IsOk(result) and result.error.code == 'denied' and groundCreated == 0 and broadcasts == 0 and writes == 0)
end)
test('ground drop rechecks membership after a successful preflight', function()
  add(1, 1, 0, 1, 1)
  beforeTransaction = function() rows[1].inventory_id = 3 end
  local result = ItemsAPI.DropItemsOnGround(1, {1}, 0, 0, 0)
  assert(not Result.IsOk(result) and rows[1].inventory_id == 3 and writes == 0 and #events == 0 and broadcasts == 0)
end)
test('ground drop retains slot limits despite unlimited ground weight', function()
  add(2, 1, 0, 1, 1); policies[2].max_weight, policies[2].max_slots = 0, 1; definitions[1].max_stack_size = 1
  local before = copy(rows); local result = ItemsAPI.DropItemsOnGround(1, ids(1), 0, 0, 0)
  assert(not Result.IsOk(result) and result.error.code == 'inventory_full' and broadcasts == 0); unchanged(before)
end)
test('ground RPC returns full-operation timing with the browser trace ID', function()
  Config.MutationTiming = true
  local registered = {}
  Feather = { RPC = { Register = function(name, handler) registered[name] = handler end },
    Notify = { RightNotify = function() end } }
  RegisterServerEvent = function() end
  CreateThread = function() end
  InventoryIdentity = { GetCharacter = function() return {char = {id = 1}} end,
    GetPosition = function() return 0, 0, 0 end }
  Translate = function(_, _, fallback) return fallback end
  TranslateResult = function() return 'rejected' end
  InventoryControllers.GetInventoryByCharacter = function() return 1 end
  Config.Dropped.PromptViewDistance = 5
  dofile(root .. '/server/services/ground.lua')
  UpdateClientWithGroundLocations = function() broadcasts = broadcasts + 1 end
  add(200, 1, 0, 1, 1); policies[2].max_weight = 0
  local response
  registered['Feather:Inventory:DropItemsOnGround']({items = ids(1), x = 0, y = 0, z = 0, traceId = 'nui-ground-1'},
    function(value) response = value end, 1)
  assert(response and not response.error and response.mutationTiming.operation == 'ground_drop')
  assert(response.mutationTiming.traceId == 'nui-ground-1' and response.mutationTiming.dropPreflightStatements == 1)
  assert(response.mutationTiming.updateStatements == 2 and response.mutationTiming.serverMs > 0)
end)
local function takeAllHandler(access)
  local registered = {}
  Feather = { RPC = { Register = function(name, handler) registered[name] = handler end },
    Notify = { RightNotify = function() end } }
  InventoryIdentity = { GetCharacter = function() return { char = { id = 1 } } end }
  InventoryControllers.GetInventoryByCharacter = function() return 1 end
  InventoryAPI.Accessible = access or function() return true end
  Translate = function(_, _, fallback) return fallback end
  dofile(root .. '/server/services/callbacks.lua')
  return registered['Feather:Inventory:TakeAll']
end
test('planner uses four state reads plus grouped writes regardless of definitions', function()
  Config.MutationTiming = true
  add(10, 2, 0, 1, 1); add(10, 2, 1, 2, 1); add(10, 2, 2, 3, 1)
  local result = InventoryControllers.MoveInventoryItems(2, 1, ids(2))
  assert(not result.error and result.movedCount == 30 and result.skippedCount == 0)
  -- This model stubs access/equipment queries; actual providers add those reads.
  assert(result.mutationTiming.sqlStatements == 7 and result.mutationTiming.updateStatements == 3)
end)
test('greedy planner skips heavy items then admits lighter candidates in one transaction', function()
  add(1, 2, 0, 1, 6); add(2, 2, 1, 2, 2); policies[1].max_weight = 4
  local transactions, original = 0, DB.transaction
  DB.transaction = function(body) transactions = transactions + 1; return original(body) end
  local result = InventoryControllers.MoveInventoryItems(2, 1, ids(2), { takeWhatFits = true })
  DB.transaction = original
  assert(not result.error and result.movedCount == 2 and result.skippedCount == 1 and transactions == 1)
  assert(rows[1].inventory_id == 2 and #events == 2 and count(1, 0) == 2)
end)
test('greedy reservations enforce quantity and slots after each accepted candidate', function()
  add(3, 2, 0, 1, 1); add(1, 2, 1, 2, 1)
  definitions[1].max_quantity, definitions[1].max_stack_size = 2, 2
  policies[1].max_slots = 1
  local result = InventoryControllers.MoveInventoryItems(2, 1, ids(2), { takeWhatFits = true })
  assert(not result.error and result.movedCount == 2 and result.skippedCount == 2)
  assert(count(1, 0) == 2 and #events == 2)
end)
test('greedy planner keeps vetoed and blacklisted rows in the source', function()
  add(2, 2, 0, 1, 1); add(1, 2, 1, 2, 1)
  denied = 1; restrictions['1:2'] = true
  local result = InventoryControllers.MoveInventoryItems(2, 1, ids(2), { takeWhatFits = true })
  assert(not result.error and result.movedCount == 1 and result.skippedCount == 2)
  assert(rows[1].inventory_id == 2 and rows[3].inventory_id == 2 and #events == 1)
end)
test('unplaced target rows count toward locked weight and quantity', function()
  add(1, 1, nil, 1, 5); add(1, 2, 0, 1, 5); policies[1].max_weight = 9
  local before = copy(rows)
  assert(InventoryControllers.MoveInventoryItems(2, 1, ids(2)).code == 'weight_limit'); unchanged(before)
  policies[1].max_weight = 10; definitions[1].max_quantity = 1
  assert(InventoryControllers.MoveInventoryItems(2, 1, ids(2)).code == 'item_limit'); unchanged(before)
end)
test('greedy compatible placement fills final stack room without an extra slot', function()
  add(1, 1, 0, 1, 1); add(3, 2, 0, 1, 1)
  definitions[1].max_stack_size = 3; policies[1].max_slots = 1
  local result = InventoryControllers.MoveInventoryItems(2, 1, ids(2), { takeWhatFits = true })
  assert(not result.error and result.movedCount == 2 and result.skippedCount == 1 and count(1, 0) == 3)
end)
test('greedy write failure rolls back all accepted groups and emits no events', function()
  add(1, 2, 0, 1, 1); add(1, 2, 1, 2, 1); local before = copy(rows); failWrite = 2
  local result = InventoryControllers.MoveInventoryItems(2, 1, ids(2), { takeWhatFits = true })
  assert(result.error and result.code == 'conflict'); unchanged(before)
end)
test('greedy no-fit result conserves all rows and emits no movement events', function()
  add(3, 2, 0, 1, 2); policies[1].max_weight = 1; local before = copy(rows)
  local result = InventoryControllers.MoveInventoryItems(2, 1, ids(2), { takeWhatFits = true })
  assert(not result.error and result.movedCount == 0 and result.skippedCount == 3 and writes == 0)
  unchanged(before)
end)
test('planner sees capacity filled before its transaction starts', function()
  add(1, 2, 0, 1, 1); policies[1].max_slots = 1
  beforeTransaction = function() add(1, 1, 0, 2, 1) end
  local result = InventoryControllers.MoveInventoryItems(2, 1, ids(2))
  assert(result.error and result.code == 'inventory_full' and writes == 0 and #events == 0)
end)
test('Take All returns one fresh post-commit pair and complete RPC timing', function()
  Config.MutationTiming = true
  add(30, 2, 0, 1, 1)
  local handler = takeAllHandler()
  local reads, original = 0, InventoryControllers.GetInventoryItems
  InventoryControllers.GetInventoryItems = function(inventory)
    reads = reads + 1
    return original(inventory)
  end
  local response
  handler({ fromInventory = 2, traceId = 'nui-take-all' }, function(value) response = value end, 1)
  InventoryControllers.GetInventoryItems = original
  assert(not response.error and response.moved == 30 and response.skipped == 0)
  assert(#response.sourceItems == 0 and #response.targetItems == 30 and reads == 1)
  assert(response.mutationTiming.operation == 'take_all' and response.mutationTiming.traceId == 'nui-take-all')
  assert(response.mutationTiming.updateStatements == 1 and response.mutationTiming.sourceReadMs)
end)
test('Take All preserves partial-fit weight and slot limits with one final pair', function()
  add(3, 2, 0, 1, 1); policies[1].max_weight = 2; policies[1].max_slots = 1
  local response
  takeAllHandler()({ fromInventory = 2 }, function(value) response = value end, 1)
  assert(not response.error and response.moved == 2 and response.skipped == 1)
  assert(#response.sourceItems == 1 and #response.targetItems == 2)
end)
test('Take All does not expose final arrays after access is revoked', function()
  add(1, 2, 0, 1, 1)
  local checks, response = 0
  local handler = takeAllHandler(function() checks = checks + 1; return checks == 1 end)
  handler({ fromInventory = 2 }, function(value) response = value end, 1)
  assert(response.error and response.code == 'no_access' and response.sourceItems == nil)
end)
test('locked drag auto-merges only target stack room and preserves remainder', function()
  add(6, 1, 0, 1, 1); add(4, 2, 0, 1, 1); definitions[1].max_stack_size = 5
  local moved, _, _, selected = InventoryControllers.MoveSlotItems(1, 0, 2, 0, { autoMerge = true, expectedItemId = 1 })
  assert(moved and #selected == 1 and count(1, 0) == 5 and count(2, 0) == 5 and #events == 1)
end)
test('locked drag swaps full or metadata-incompatible stacks instead of merging', function()
  add(2, 1, 0, 1, 1, 'source'); add(2, 2, 0, 1, 1, 'target')
  assert(InventoryControllers.MoveSlotItems(1, 0, 2, 0, { autoMerge = true }))
  assert(rows[1].inventory_id == 2 and rows[3].inventory_id == 1 and #events == 4)
end)
test('locked drag rejects stale dragged instance rather than moving its replacement stack', function()
  add(2, 1, 0, 1, 1); local before = copy(rows)
  local moved, code = InventoryControllers.MoveSlotItems(1, 0, 2, 0, { autoMerge = true, expectedItemId = 99 })
  assert(not moved and code == 'conflict'); unchanged(before)
end)
test('drag RPC uses locked planner without preliminary breakdown or acceptance reads', function()
  takeAllHandler()
  local registered = {}
  Feather.RPC.Register = function(name, handler) registered[name] = handler end
  dofile(root .. '/server/services/callbacks.lua')
  local old = InventoryControllers.GetInventoryItemById
  InventoryControllers.GetInventoryItemById = function(id)
    for _, row in ipairs(rows) do if row.id == id then return copy(row) end end
  end
  local originalCapacity, originalBreakdown = InventoryControllers.GetInventoryCapacity, InventoryControllers.GetSlotItemBreakdown
  InventoryControllers.GetInventoryCapacity = function() error('Preliminary capacity read') end
  InventoryControllers.GetSlotItemBreakdown = function() error('Preliminary breakdown read') end
  add(6, 1, 0, 1, 1); add(4, 2, 0, 1, 1); definitions[1].max_stack_size = 5
  local response
  registered['Feather:Inventory:MoveItem']({ itemId = 1, toInventory = 2, toSlot = 0 }, function(value) response = value end, 1)
  InventoryControllers.GetInventoryItemById = old
  InventoryControllers.GetInventoryCapacity, InventoryControllers.GetSlotItemBreakdown = originalCapacity, originalBreakdown
  assert(response and not response.error and #response.sourceItems == 5 and #response.targetItems == 5)
end)
test('bulk destruction clears 731 locked records in four delete statements', function()
  add(731, 1, 0, 1, 1); policies[1].location = 'ground'
  local result = TransactionAPI.DestroyInstances({ reason = 'ground_restart_cleanup' },
    { inventoryId = 1, expectedLocation = 'ground', instanceIds = ids(1) })
  assert(Result.IsOk(result) and #result.value.destroyedInstanceIds == 731 and writes == 4 and #rows == 0 and #events == 731)
end)
test('bulk destruction guard veto preserves the entire pile', function()
  add(250, 1, 0, 1, 1); policies[1].location = 'ground'; denied = 249; local before = copy(rows)
  local result = TransactionAPI.DestroyInstances({}, { inventoryId = 1, expectedLocation = 'ground', instanceIds = ids(1) })
  assert(not Result.IsOk(result) and writes == 0); unchanged(before)
end)
test('bulk destruction later delete mismatch rolls back all earlier chunks', function()
  add(250, 1, 0, 1, 1); policies[1].location = 'ground'; failWrite = 2; local before = copy(rows)
  local result = TransactionAPI.DestroyInstances({}, { inventoryId = 1, expectedLocation = 'ground', instanceIds = ids(1) })
  assert(not Result.IsOk(result)); unchanged(before)
end)
test('authoritative pair uses one read and partitions both inventories without leaking IDs', function()
  add(2, 1, 0, 1, 1); add(1, 2, 0, 2, 1)
  local queries, original = 0, DB.query
  DB.query = function(sql, ...) queries = queries + 1; return original(sql, ...) end
  local pair = InventoryControllers.GetInventoryItemsPair(1, 2)
  assert(queries == 1 and #pair.sourceItems == 2 and #pair.targetItems == 1)
  assert(pair.sourceItems[1].inventory_id == nil and type(pair.sourceItems[1].metadata) == 'table')
  pair = InventoryControllers.GetInventoryItemsPair(1, 1)
  assert(queries == 2 and #pair.sourceItems == 2 and #pair.targetItems == 2)
  pair = InventoryControllers.GetInventoryItemsPair(1, 3)
  assert(queries == 3 and #pair.targetItems == 0)
  DB.query = original
end)
test('Take All NUI makes exactly one RPC and preserves full timing response', function()
  local callbacks, calls, waits = {}, 0, 0
  RegisterNUICallback = function(name, callback) callbacks[name] = callback end
  Wait = function() waits = waits + 1 end
  Feather.RPC.CallAsync = function(name)
    assert(name == 'Feather:Inventory:TakeAll')
    calls = calls + 1
    return { error = false, sourceItems = {}, targetItems = {}, mutationTiming = {} }
  end
  dofile(root .. '/client/services/nuicallbacks.lua')
  local response
  callbacks['Feather:Inventory:TakeAll']({ fromInventory = 2 }, function(value) response = value end)
  assert(calls == 1 and waits == 0 and response.mutationTiming.clientRpcMs)
end)
test('bulk grant batches inserts and preserves NULL metadata and returned identities', function()
  add(1, 1, 0, 1, 1)
  local result = TransactionAPI.Transaction({}, function(tx) return tx:AddQuantity(1, 1, 250) end)
  assert(Result.IsOk(result), result.error and result.error.message)
  assert(#result.value == 250 and writes == 3 and #rows == 251)
  local seen = {}; for _, id in ipairs(result.value) do assert(not seen[id]); seen[id] = true end
  assert(rows[#rows].metadata == nil)
end)
test('bulk grant short RETURNING batch rolls back all earlier inserts', function()
  add(1, 1, 0, 1, 1); failWrite = 2; local before = copy(rows)
  local result = TransactionAPI.Transaction({}, function(tx) return tx:AddQuantity(1, 1, 250) end)
  assert(not Result.IsOk(result)); unchanged(before)
end)
test('bulk grant capacity rejection writes nothing', function()
  add(1, 1, 0, 1, 1); policies[1].max_weight = 2
  local result = TransactionAPI.Transaction({}, function(tx) return tx:AddQuantity(1, 1, 2) end)
  assert(not Result.IsOk(result) and writes == 0)
end)
test('bulk quantity removal uses bounded deletes and preserves unrelated records', function()
  add(250, 1, 0, 1, 1); add(2, 1, 1, 2, 1)
  local result = TransactionAPI.Transaction({}, function(tx) return tx:RemoveQuantity(1, 1, 230) end)
  assert(Result.IsOk(result) and #result.value == 230 and writes == 3 and #rows == 22)
end)
test('bulk removal later mismatch rolls back and emits no events', function()
  add(250, 1, 0, 1, 1); failWrite = 2; local before = copy(rows)
  local result = TransactionAPI.Transaction({}, function(tx) return tx:RemoveInstances(1, 1, ids(1)) end)
  assert(not Result.IsOk(result)); unchanged(before)
end)
test('bulk removal veto is checked before any delete', function()
  add(250, 1, 0, 1, 1); denied = 230; local before = copy(rows)
  local result = TransactionAPI.Transaction({}, function(tx) return tx:RemoveQuantity(1, 1, 250) end)
  assert(not Result.IsOk(result) and writes == 0); unchanged(before)
end)
test('bulk exact removal rejects duplicates and foreign definitions', function()
  add(2, 1, 0, 1, 1); add(1, 1, 1, 2, 1)
  local result = TransactionAPI.Transaction({}, function(tx) return tx:RemoveInstances(1, 1, {1, 1}) end)
  assert(not Result.IsOk(result) and writes == 0)
  result = TransactionAPI.Transaction({}, function(tx) return tx:RemoveInstances(1, 1, {1, 3}) end)
  assert(not Result.IsOk(result) and writes == 0)
end)
test('Give uses one transaction and transfers only recipient capacity', function()
  Config.MutationTiming = true
  local registered = {}
  Feather = { RPC = { Register = function(name, handler) registered[name] = handler end },
    Notify = { RightNotify = function() end } }
  InventoryIdentity = { GetCharacter = function(src) return {char = {id = src}} end }
  InventoryControllers.GetInventoryByCharacter = function(id) return id end
  IsWithinGiveDistance = function() return true end
  dofile(root .. '/server/services/callbacks.lua')
  add(20, 1, 0, 1, 1); policies[2].max_weight = 7
  local response
  registered['Feather:Inventory:GiveItem']({target = 2, items = ids(1), traceId = 'give-test'},
    function(value) response = value end, 1)
  assert(not response.error and response.movedCount == 7 and response.skippedCount == 13)
  assert(writes == 1 and count(2, 0) == 7 and #response.sourceItems == 13)
  assert(response.mutationTiming.operation == 'give_items' and response.mutationTiming.updateStatements == 1)
end)
test('Give recipient moving away before write rejects everything', function()
  add(20, 1, 0, 1, 1); local before = copy(rows)
  InventoryIdentity = { GetCharacter = function() return {char = {id = 2}} end }
  IsWithinGiveDistance = function() return false end
  local response = InventoryControllers.MoveInventoryItems(1, 2, ids(1), {
    reason = 'give', actorSource = 1, targetSource = 2, targetCharacterId = 2, allowTargetInsert = true,
  })
  assert(response.error and writes == 0); unchanged(before)
end)
test('Give NUI submits all IDs in one RPC without exposing recipient contents', function()
  local callbacks, calls = {}, 0
  RegisterNUICallback = function(name, callback) callbacks[name] = callback end
  GetPedInFront = function() return 10 end
  GetPlayerFromPed = function() return 2 end
  Feather.RPC.CallAsync = function(name, args)
    assert(name == 'Feather:Inventory:GiveItem' and args.target == 2 and #args.items == 3)
    calls = calls + 1
    return {error = false, sourceItems = {}, targetItems = {{id = 99}}, movedCount = 3, skippedCount = 0}
  end
  dofile(root .. '/client/services/nuicallbacks.lua')
  local response
  callbacks['Feather:Inventory:GiveItem']({items = {1, 2, 3}}, function(value) response = value end)
  assert(calls == 1 and response.movedCount == 3 and response.targetItems == nil)
end)
test('bulk smoke command restores test stock and refuses existing stock', function()
  local commands = {}
  Config.DevMode, Config.Debug = false, true
  RegisterCommand = function(name, handler, restricted)
    assert(name == 'InvBulkMutationSmokeTest' and restricted == false)
    commands[name] = handler
  end
  InventoryIdentity = {GetCharacter = function() return {char = {id = 1}} end}
  InventoryControllers.GetInventoryByCharacter = function() return 1 end
  local oldCount = InventoryControllers.InventoryItemCount
  InventoryControllers.InventoryItemCount = function(inventory, definition)
    return #selectRows(function(row) return row.inventory_id == inventory and row.item_id == definition end)
  end
  add(1, 2, 0, 1, 1)
  ItemControllers = {GetItemDefinitionByName = function() return definitions[1] end}
  dofile(root .. '/server/services/commands.lua')
  commands.InvBulkMutationSmokeTest(1, {'item1', '250'})
  assert(#rows == 1 and writes == 7, tostring(#rows) .. ':' .. tostring(writes))
  add(1, 1, 0, 1, 1)
  commands.InvBulkMutationSmokeTest(1, {'item1', '20'})
  assert(#rows == 2 and writes == 7)
  InventoryControllers.InventoryItemCount = oldCount
  Config.DevMode, Config.Debug = nil, false
  local registeredAgain = false
  RegisterCommand = function() registeredAgain = true end
  dofile(root .. '/server/services/commands.lua')
  assert(not registeredAgain)
end)
test('bulk grant fills compatible stack room and keeps unique units in separate slots', function()
  add(2, 1, 0, 1, 1); definitions[1].max_stack_size = 3
  local result = TransactionAPI.Transaction({}, function(tx) return tx:AddQuantity(1, 1, 5, {value = '{}'}) end)
  assert(Result.IsOk(result) and count(1, 0) == 3 and count(1, 1) == 3 and count(1, 2) == 1)
  definitions[1].instance_mode = 'unique'; definitions[1].max_stack_size = 99
  result = TransactionAPI.Transaction({}, function(tx) return tx:AddQuantity(1, 1, 3, {serial = 'test'}) end)
  assert(Result.IsOk(result) and count(1, 3) == 1 and count(1, 4) == 1 and count(1, 5) == 1)
end)
test('bulk grant uses every compatible partial stack when no empty slots remain', function()
  add(2, 1, 0, 1, 1); add(2, 1, 1, 1, 1)
  policies[1].max_slots = 2; definitions[1].max_stack_size = 3
  local result = TransactionAPI.Transaction({}, function(tx) return tx:AddQuantity(1, 1, 2, {value = '{}'}) end)
  assert(Result.IsOk(result) and count(1, 0) == 3 and count(1, 1) == 3 and writes == 1)
end)
print(('PASS %d inventory update / transaction tests'):format(total))
