-- (INV-W3) Movement guards and structured post-commit events, per
-- DEPENDENCY_SUPPORT_PLAN §4.4 and §3.3.
--
-- Two halves of the same idea: something outside this resource needs to be
-- able to say "not yet" BEFORE an item moves, and to know reliably AFTER it
-- did. The motivating case is an equipped weapon -- feather-weapons has to
-- force an authoritative unequip before the item leaves the inventory,
-- because a weapon that moves while still equipped leaves the game-native
-- state and the database disagreeing about who is holding what.
--
-- GUARD CONTRACT (documented, because §3.3 requires a veto to be one):
--
--   * Guards are SYNCHRONOUS. A guard must not yield -- no Wait, no
--     CallAsync, no MySQL await. There is no way to enforce that in Lua, so
--     it is stated here and in the registration function: a yielding guard
--     stalls every mutation behind it.
--   * A guard returns `true` to allow, or `false, reason` to veto.
--   * A guard that ERRORS is treated as a VETO, not as an allow. Failing
--     closed is the whole point -- a guard exists to prevent something, so a
--     broken guard must not silently become permission. §3.4's "fail clearly
--     rather than partially start" applied to the mutation path.
--   * Guards never leave a lock behind. They are a pure question asked at
--     one moment; there is nothing to release, so a crashed consumer cannot
--     wedge the inventory (the "no permanent locks" requirement).
--
-- EVENT CONTRACT:
--
--   * Emitted only AFTER the mutation is committed (§3.3). A consumer can
--     therefore trust that what it is told already happened.
--   * Internal `TriggerEvent`, deliberately NOT `RegisterServerEvent`. A
--     network-registered mutation event is spoofable by any client -- see
--     feather-weapons' own note about exactly this on ItemRemoved.
--   * Payloads carry stable ids and immutable summaries, never live tables a
--     consumer could mutate underneath the resource.

GuardsAPI = {}

local MoveGuards = {}
local DestroyGuards = {}
local ActiveEquipmentSnapshots = {}

-- Movement controllers already hold the item locks. Use a current locking
-- read for equipment too, never a transaction's older consistent-read view.
function GuardsAPI.PrepareMoveSnapshots(query, rows)
    if next(MoveGuards) == nil or #rows == 0 then return true end
    local ids, seen, equipped = {}, {}, {}
    for _, row in ipairs(rows) do
        local id = tonumber(row.id)
        if not id then return false end
        if not seen[id] then ids[#ids + 1] = id; seen[id] = true end
    end
    table.sort(ids)
    for first = 1, #ids, 200 do
        local last = math.min(first + 199, #ids)
        local placeholders, params = {}, {}
        for index = first, last do
            placeholders[#placeholders + 1] = '?'
            params[#params + 1] = ids[index]
        end
        local assignments = query('SELECT `inventory_items_id` FROM `character_equipment`' ..
            ' WHERE `inventory_items_id` IN (' .. table.concat(placeholders, ',') ..
            ') ORDER BY `inventory_items_id` FOR UPDATE;', params)
        if type(assignments) ~= 'table' then return false end
        for _, assignment in ipairs(assignments) do equipped[tonumber(assignment.inventory_items_id)] = true end
    end
    for _, row in ipairs(rows) do
        row._equipmentVerified = true
        row._equipmentEquipped = equipped[tonumber(row.id)] == true
    end
    return true
end

-- Existing cross-resource guards may call Equipment.IsInstanceEquipped.
-- This lookup is scoped to an active guard on this exact locked item; other
-- calls retain the ordinary DB path. Token sets make nested/overlapping
-- evaluations safe to clean up in either order.
function GuardsAPI.GetLockedEquipmentState(instanceId)
    local active = ActiveEquipmentSnapshots[tonumber(instanceId)]
    if not active then return nil, false end
    local value
    for _, state in pairs(active) do
        if value ~= nil and value ~= state.equipped then return nil, false end
        value = state.equipped
    end
    return value, value ~= nil
end

-- Cfx serializes callbacks crossing a resource boundary as callable tables.
-- Use rawget because their metatable intentionally rejects normal indexing.
local function IsGuardCallback(value)
    return type(value) == 'function'
        or (type(value) == 'table'
            and type(rawget(value, '__cfx_functionReference')) == 'string')
end
------------------------------------------------------------------
-- Registration
------------------------------------------------------------------

---
-- Register Move Guard
--
-- @param name Unique identifier; re-registering the same name replaces it,
--        so a resource restart cannot accumulate duplicate guards.
-- @param fn function(instance, context) -> boolean, reason
--        MUST be synchronous -- see the guard contract above.
--
function GuardsAPI.RegisterMoveGuard(name, fn)
    if type(name) ~= 'string' or name == '' or not IsGuardCallback(fn) then
        warn('RegisterMoveGuard requires a name and a callable function reference.')
        return Result.Err(Result.Codes.INVALID_INPUT, 'A guard name and callable function reference are required.')
    end
    MoveGuards[name] = fn
    return Result.Ok(true)
end

function GuardsAPI.RegisterDestroyGuard(name, fn)
    if type(name) ~= 'string' or name == '' or not IsGuardCallback(fn) then
        warn('RegisterDestroyGuard requires a name and a callable function reference.')
        return Result.Err(Result.Codes.INVALID_INPUT, 'A guard name and callable function reference are required.')
    end
    DestroyGuards[name] = fn
    return Result.Ok(true)
end

function GuardsAPI.UnregisterMoveGuard(name)
    MoveGuards[name] = nil
end

function GuardsAPI.UnregisterDestroyGuard(name)
    DestroyGuards[name] = nil
end

------------------------------------------------------------------
-- Evaluation
------------------------------------------------------------------

local function RunResolvedGuards(registry, instance, context)
    for name, guard in pairs(registry) do
        local metrics = context and context._timing
        local started = metrics and GetGameTimer()
        local ok, allowed, reason = pcall(guard, instance, context or {})
        if metrics then
            metrics.guardConsumers = metrics.guardConsumers or {}
            local timing = metrics.guardConsumers[name] or { calls = 0, ms = 0 }
            timing.calls = timing.calls + 1
            timing.ms = timing.ms + InventoryMutationMetrics.Elapsed(started)
            metrics.guardConsumers[name] = timing
        end
        if not ok then
            warn(('Guard "%s" errored (%s); vetoing as fail-closed.'):format(name, tostring(allowed)))
            return false, ('Guard "%s" failed.'):format(name)
        end
        if allowed == false then
            return false, reason or ('Blocked by guard "%s".'):format(name)
        end
    end
    return true
end

local function RunGuards(registry, instanceId, context)
    -- Nothing registered is the overwhelmingly common case (no consumer
    -- resource loaded), so skip the instance read entirely rather than
    -- paying a query per moved item for guards that do not exist.
    if next(registry) == nil then
        return true
    end

    local instance = InstancesAPI.GetInstance(instanceId)
    if not Result.IsOk(instance) then
        -- Cannot describe what is moving, so cannot let a guard make an
        -- informed decision about it. Fail closed.
        return false, 'Item instance could not be read for guard evaluation.'
    end

    return RunResolvedGuards(registry, instance.value, context)
end

---
-- Can Move Instance
--
-- @return true, or false plus a reason
--
function GuardsAPI.CanMoveInstance(instanceId, context)
    return RunGuards(MoveGuards, instanceId, context)
end

-- Transaction paths already hold a normalized snapshot from their locking
-- SELECT. Reusing it prevents a second connection from querying a row locked
-- by the transaction itself while preserving the exact guard contract.
function GuardsAPI.CanMoveInstanceSnapshot(instance, context)
    if next(MoveGuards) == nil then return true end
    if type(instance) ~= 'table' or not tonumber(instance.id) then
        return false, 'Item instance could not be read for guard evaluation.'
    end
    local snapshot = instance.equipmentSnapshot
    if type(snapshot) ~= 'table' or type(snapshot.equipped) ~= 'boolean' then
        return RunResolvedGuards(MoveGuards, instance, context)
    end
    local id, token = tonumber(instance.id), {}
    local active = ActiveEquipmentSnapshots[id] or {}
    ActiveEquipmentSnapshots[id] = active
    active[token] = { equipped = snapshot.equipped }
    local values = table.pack(pcall(RunResolvedGuards, MoveGuards, instance, context))
    active[token] = nil
    if next(active) == nil then ActiveEquipmentSnapshots[id] = nil end
    if not values[1] then
        warn('Movement guard evaluation failed; vetoing as fail-closed.')
        return false, 'Movement guard evaluation failed.'
    end
    return table.unpack(values, 2, values.n)
end

function GuardsAPI.CanDestroyInstance(instanceId, context)
    return RunGuards(DestroyGuards, instanceId, context)
end

function GuardsAPI.CanDestroyInstanceSnapshot(instance, context)
    if next(DestroyGuards) == nil then return true end
    if type(instance) ~= 'table' or not tonumber(instance.id) then
        return false, 'Item instance could not be read for guard evaluation.'
    end
    return RunResolvedGuards(DestroyGuards, instance, context)
end

------------------------------------------------------------------
-- Post-commit events
------------------------------------------------------------------

-- Names match DEPENDENCY_SUPPORT_PLAN §4.4 exactly, so a consumer written
-- against that document listens for the right thing without translation.
GuardsAPI.Events = {
    ItemCreated = 'Feather:Inventory:ItemCreated',
    ItemMoved = 'Feather:Inventory:ItemMoved',
    ItemMetadataChanged = 'Feather:Inventory:ItemMetadataChanged',
    ItemDestroyed = 'Feather:Inventory:ItemDestroyed',
    DefinitionMigrated = 'Feather:Inventory:DefinitionMigrated',
    TransactionCommitted = 'Feather:Inventory:TransactionCommitted',
}

local function Emit(eventName, payload)
    -- TriggerEvent, never TriggerClientEvent or a networked registration:
    -- these describe committed server state and have no business being
    -- reachable from, or broadcast to, a client.
    TriggerEvent(eventName, payload)
end

local function MutationFact(operation, context)
    return {
        operation = operation,
        outcome = 'committed',
        quantity = 1,
        actorSource = context and context.actorSource,
        actorCharacterId = context and context.actorCharacterId,
        resource = context and context.resource,
        correlationId = context and context.correlationId,
        reason = context and context.reason,
        occurredAt = os.time(),
    }
end

function GuardsAPI.EmitItemCreated(instanceId, definitionId, inventoryId, context)
    local fact = MutationFact('create', context)
    fact.instanceId = instanceId
    fact.definitionId = definitionId
    fact.inventoryId = inventoryId
    fact.destination = { inventoryId = inventoryId }
    Emit(GuardsAPI.Events.ItemCreated, fact)
end

function GuardsAPI.EmitItemMoved(instanceId, fromInventoryId, toInventoryId, context, extra)
    -- (Weapons review) `extra` carries definitionId/revision where the caller
    -- knows them. The transaction path previously passed nil for both, so a
    -- consumer had to re-query to learn what had just moved.
    extra = extra or {}
    local fact = MutationFact('move', context)
    fact.instanceId = instanceId
    fact.definitionId = extra.definitionId
    fact.revision = extra.revision
    fact.fromInventoryId = fromInventoryId
    fact.toInventoryId = toInventoryId
    fact.origin = { inventoryId = fromInventoryId, slot = extra.fromSlot }
    fact.destination = { inventoryId = toInventoryId, slot = extra.toSlot }
    Emit(GuardsAPI.Events.ItemMoved, fact)
end

function GuardsAPI.EmitItemMetadataChanged(instanceId, revision, context, extra)
    extra = extra or {}
    local fact = MutationFact('metadata_write', context)
    fact.instanceId = instanceId
    fact.definitionId = extra.definitionId
    fact.inventoryId = extra.inventoryId
    fact.origin = { inventoryId = extra.inventoryId, slot = extra.slot }
    fact.destination = { inventoryId = extra.inventoryId, slot = extra.slot }
    fact.revision = revision
    Emit(GuardsAPI.Events.ItemMetadataChanged, fact)
end

function GuardsAPI.EmitItemDestroyed(instanceId, definitionId, inventoryId, context)
    local fact = MutationFact('destroy', context)
    fact.instanceId = instanceId
    fact.definitionId = definitionId
    fact.inventoryId = inventoryId
    fact.origin = { inventoryId = inventoryId }
    Emit(GuardsAPI.Events.ItemDestroyed, fact)
end

function GuardsAPI.EmitTransactionCommitted(context, summary)
    local fact = MutationFact('transaction', context)
    fact.quantity = nil
    fact.summary = summary
    Emit(GuardsAPI.Events.TransactionCommitted, fact)
end

function GuardsAPI.EmitDefinitionMigrated(sourceDefinitionId, targetDefinitionId, quantity, context)
    local fact = MutationFact('definition_migration', context)
    fact.quantity = tonumber(quantity) or 0
    fact.sourceDefinitionId = tonumber(sourceDefinitionId)
    fact.targetDefinitionId = tonumber(targetDefinitionId)
    Emit(GuardsAPI.Events.DefinitionMigrated, fact)
end
