-- (INV-W2, rewritten after the feather-weapons review) Real transactions.
--
-- CORRECTION, recorded because the previous design rested on a wrong premise
-- and someone will otherwise wonder why this changed shape:
--
-- This file previously claimed oxmysql exposed no interactive transaction,
-- and implemented optimistic concurrency with a guard statement that
-- deliberately provoked ER_SUBQUERY_NO_1_ROW to abort a batch. That claim was
-- WRONG. It came from `.luals/oxmysql.lua` -- a hand-written editor type stub
-- that stops at `MySQL.transaction.await` -- rather than from oxmysql's
-- source. `MySQL.startTransaction(cb)` exists and provides exactly what was
-- said to be missing:
--
--   startTransaction: (cb: (query: (sql, params?) => Promise<T>)
--                          => Promise<boolean | void>) => Promise<boolean>
--
-- A dedicated connection, `beginTransaction()`, a `query` bound to that
-- connection so arbitrary logic can run between reads and writes, and `false`
-- (or a raised error) to roll everything back.
--
-- So this now uses genuine pessimistic locking: `SELECT ... FOR UPDATE`
-- inside the transaction, decide, write, commit. Concurrent callers QUEUE on
-- the row lock instead of racing and retrying, and capacity is re-checked
-- inside the same transaction that commits the move -- which is what stops
-- two concurrent transfers from both passing a pre-check.
--
-- Revision compare-and-set is KEPT on top of locking, for a caller that reads
-- an instance in one request and writes it in a later one. A lock spans a
-- single transaction; a revision spans a conversation.
--
-- CAVEAT, stated rather than buried: oxmysql logs
-- `startTransaction is "experimental" and may receive breaking changes`. The
-- calling convention is therefore isolated in exactly one function
-- (RunInTransaction) so an upstream change is a one-function fix rather than
-- a rewrite, and /InvTxSmokeTest (DevMode) exercises it end to end.

TransactionAPI = {}

------------------------------------------------------------------
-- Metrics
------------------------------------------------------------------

local Metrics = {
    started = 0,
    committed = 0,
    rolledBack = 0,
    conflicts = 0,
    bodyErrors = 0,
    idempotentHits = 0,
}

function TransactionAPI.GetMetrics()
    local snapshot = {}
    for key, value in pairs(Metrics) do
        snapshot[key] = value
    end
    return snapshot
end

------------------------------------------------------------------
-- Idempotency
------------------------------------------------------------------
--
-- Bounded in-memory cache. The record only has to outlive the retry window of
-- the request that created it; persisting it would mean a schema plus a
-- cleanup job for something worthless after a restart. Bounded because an
-- unbounded cache keyed by caller-supplied strings is a memory-exhaustion
-- vector.
local IdempotencyCache = {}
local IdempotencyOrder = {}
local MAX_IDEMPOTENCY_ENTRIES = 500
local IDEMPOTENCY_TTL_MS = 60000

local function IdempotencyGet(key)
    if not key then return nil end
    local entry = IdempotencyCache[key]
    if not entry then return nil end
    if GetGameTimer() > entry.expiresAt then
        IdempotencyCache[key] = nil
        return nil
    end
    return entry.result
end

local function IdempotencyPut(key, result)
    if not key then return end
    if IdempotencyCache[key] == nil then
        IdempotencyOrder[#IdempotencyOrder + 1] = key
        while #IdempotencyOrder > MAX_IDEMPOTENCY_ENTRIES do
            IdempotencyCache[table.remove(IdempotencyOrder, 1)] = nil
        end
    end
    IdempotencyCache[key] = { result = result, expiresAt = GetGameTimer() + IDEMPOTENCY_TTL_MS }
end

------------------------------------------------------------------
-- The one place that knows oxmysql's transaction calling convention
------------------------------------------------------------------

---
-- Run In Transaction
--
-- `body(query)` receives a query function bound to the transaction's own
-- connection. Returning false, returning a failure envelope, or raising rolls
-- everything back.
--
-- @return committed (boolean), bodyResult (any), bodyError (string|nil)
--
local function RunInTransaction(body)
    local bodyResult, bodyError

    local committed = MySQL.startTransaction(function(query)
        local ok, result = pcall(body, query)
        if not ok then
            bodyError = tostring(result)
            return false
        end
        -- A body returning its own failure envelope is a deliberate
        -- rejection, not a crash: roll back, but preserve its reason.
        if type(result) == 'table' and result.ok == false then
            bodyResult = result
            return false
        end
        bodyResult = result
        return true
    end)

    return committed == true, bodyResult, bodyError
end

------------------------------------------------------------------
-- Transaction handle
------------------------------------------------------------------

local Tx = {}
Tx.__index = Tx

local function NewTx(query, context)
    return setmetatable({ query = query, context = context or {} }, Tx)
end

---
-- Get Item For Update
--
-- Reads an instance and LOCKS its row for the rest of the transaction. Another
-- transaction touching the same row blocks here until this one finishes --
-- the guarantee optimistic retry could not give. Name matches what
-- feather-weapons' adapter expects.
--
function Tx:GetItemForUpdate(instanceId)
    local id = tonumber(instanceId)
    if not id then
        return Result.Err(Result.Codes.INVALID_INPUT, 'Invalid instance id.')
    end

    local rows = self.query([[
        SELECT ii.`id`, ii.`inventory_id`, ii.`slot_index`, ii.`item_id`,
               ii.`metadata`, ii.`metadata_revision`,
               i.`name`, i.`display_name`, i.`weight`, i.`type`,
               i.`max_quantity`, i.`max_stack_size`, i.`instance_mode`
        FROM `inventory_items` ii
        INNER JOIN `items` i ON i.`id` = ii.`item_id`
        WHERE ii.`id` = ? FOR UPDATE;
    ]], { id })

    local row = rows and rows[1]
    if not row then
        return Result.Err(Result.Codes.NOT_FOUND, 'Item instance does not exist.')
    end

    local document = {}
    if row.metadata and row.metadata ~= '' then
        local parsed, decoded = pcall(json.decode, row.metadata)
        if parsed and type(decoded) == 'table' then
            document = decoded
        end
    end

    return Result.Ok({
        id = tonumber(row.id),
        inventoryId = tonumber(row.inventory_id),
        slot = row.slot_index ~= nil and tonumber(row.slot_index) or nil,
        metadata = document,
        metadataRevision = tonumber(row.metadata_revision) or 0,
        definition = {
            id = tonumber(row.item_id),
            name = row.name,
            displayName = row.display_name,
            weight = tonumber(row.weight),
            type = row.type,
            maxQuantity = tonumber(row.max_quantity),
            maxStackSize = tonumber(row.max_stack_size),
            instanceMode = row.instance_mode or 'stack',
        }
    })
end

---
-- Get Quantity
--
-- Counted inside the transaction, so it cannot drift before the decision
-- based on it commits.
--
function Tx:GetQuantity(inventoryId, definitionId)
    local rows = self.query(
        'SELECT COUNT(`id`) AS `count` FROM `inventory_items` WHERE `inventory_id`=? AND `item_id`=?;',
        { inventoryId, definitionId })
    return tonumber(rows and rows[1] and rows[1].count) or 0
end

---
-- Remove Quantity
--
-- Consumes `quantity` units of a definition. Rows are selected FOR UPDATE
-- before deletion so a concurrent transaction cannot consume the same
-- ammunition -- the duplicate-ammo case the review calls out.
--
function Tx:RemoveQuantity(inventoryId, definitionId, quantity)
    local wanted = math.floor(tonumber(quantity) or 0)
    if wanted < 1 then
        return Result.Err(Result.Codes.INVALID_INPUT, 'Quantity must be at least 1.')
    end

    local rows = self.query(
        'SELECT `id` FROM `inventory_items` WHERE `inventory_id`=? AND `item_id`=? ORDER BY `id` LIMIT ' ..
        wanted .. ' FOR UPDATE;', { inventoryId, definitionId })

    if not rows or #rows < wanted then
        return Result.Err(Result.Codes.LIMIT_EXCEEDED, 'Not enough of that item to remove.',
            { available = rows and #rows or 0, requested = wanted })
    end

    local removed = {}
    for _, row in ipairs(rows) do
        local id = tonumber(row.id)
        local allowed, reason = GuardsAPI.CanDestroyInstance(id, self.context)
        if not allowed then
            return Result.Err(Result.Codes.DENIED, reason or 'Removal blocked by a guard.', { instanceId = id })
        end
        self.query('DELETE FROM `inventory_items` WHERE `id`=?;', { id })
        removed[#removed + 1] = id
    end

    self.destroyed = self.destroyed or {}
    for _, id in ipairs(removed) do
        self.destroyed[#self.destroyed + 1] =
            { instanceId = id, definitionId = definitionId, inventoryId = inventoryId }
    end

    return Result.Ok(removed)
end

---
-- Add Quantity
--
-- Creates `quantity` new instances, placed by the same rule the
-- non-transactional paths use (join an under-full stack unless the definition
-- is `unique`, else claim free compartments). Capacity is evaluated INSIDE the
-- transaction against locked rows, which is what stops two concurrent
-- transfers from both passing a pre-check.
--
-- `metadata` is written in the SAME statement that creates the row, so a
-- unique item is never briefly visible without its state -- the atomic
-- creation the review asks for.
--
function Tx:AddQuantity(inventoryId, definitionId, quantity, metadata)
    local wanted = math.floor(tonumber(quantity) or 0)
    if wanted < 1 then
        return Result.Err(Result.Codes.INVALID_INPUT, 'Quantity must be at least 1.')
    end

    local defRows = self.query(
        'SELECT `name`, `max_stack_size`, `instance_mode` FROM `items` WHERE `id`=? LIMIT 1;', { definitionId })
    local def = defRows and defRows[1]
    if not def then
        return Result.Err(Result.Codes.NOT_FOUND, 'Item definition does not exist.')
    end

    local stackSize = math.max(tonumber(def.max_stack_size) or 1, 1)
    local unique = def.instance_mode == 'unique'

    local encoded
    if metadata ~= nil then
        if type(metadata) ~= 'table' then
            return Result.Err(Result.Codes.INVALID_INPUT, 'Metadata must be a table.')
        end
        encoded = json.encode(metadata)
        if #encoded > 4096 then
            return Result.Err(Result.Codes.LIMIT_EXCEEDED, 'Metadata document exceeds 4096 bytes.',
                { size = #encoded, limit = 4096 })
        end
    end

    -- Lock the destination's occupied compartments so a concurrent transfer
    -- cannot claim the same ones between this read and the inserts below.
    local occupiedRows = self.query([[
        SELECT `slot_index`, `item_id`, COUNT(*) AS `count`
        FROM `inventory_items`
        WHERE `inventory_id`=? AND `slot_index` IS NOT NULL
        GROUP BY `slot_index`, `item_id` FOR UPDATE;
    ]], { inventoryId })

    local occupied, joinSlot, joinCount = {}, nil, 0
    for _, row in ipairs(occupiedRows or {}) do
        local slot = tonumber(row.slot_index)
        occupied[slot] = true
        if not unique and joinSlot == nil and tostring(row.item_id) == tostring(definitionId)
            and (tonumber(row.count) or 0) < stackSize then
            joinSlot, joinCount = slot, tonumber(row.count) or 0
        end
    end

    local capacityRows = self.query('SELECT `max_slots` FROM `inventory` WHERE `id`=? LIMIT 1;', { inventoryId })
    local capacity = tonumber(capacityRows and capacityRows[1] and capacityRows[1].max_slots)
        or tonumber(Config.maxItemSlots) or 0

    local currentSlot, currentCount = joinSlot, joinCount
    local created = {}

    for _ = 1, wanted do
        if currentSlot == nil or currentCount >= stackSize then
            currentSlot = nil
            for index = 0, capacity - 1 do
                if not occupied[index] then
                    occupied[index] = true
                    currentSlot = index
                    break
                end
            end
            if currentSlot == nil then
                return Result.Err(Result.Codes.LIMIT_EXCEEDED, 'Inventory has no available slots.')
            end
            currentCount = 0
        end

        local inserted = self.query(
            'INSERT INTO `inventory_items` (`inventory_id`, `item_id`, `slot_index`, `metadata`) VALUES (?, ?, ?, ?) RETURNING `id`;',
            { inventoryId, definitionId, currentSlot, encoded })
        local newId = inserted and inserted[1] and tonumber(inserted[1].id)
        if not newId then
            return Result.Err(Result.Codes.INTERNAL, 'Item instance could not be created.')
        end

        created[#created + 1] = newId
        currentCount = currentCount + 1
    end

    self.created = self.created or {}
    for _, id in ipairs(created) do
        self.created[#self.created + 1] =
            { instanceId = id, definitionId = definitionId, inventoryId = inventoryId }
    end

    return Result.Ok(created)
end

---
-- Set Metadata
--
-- Replaces the document and bumps the revision. `expectedRevision` makes it a
-- compare-and-set, for a value derived from a read taken in an EARLIER
-- request -- the row lock only covers this transaction.
--
function Tx:SetMetadata(instanceId, document, expectedRevision)
    local id = tonumber(instanceId)
    if not id or type(document) ~= 'table' then
        return Result.Err(Result.Codes.INVALID_INPUT, 'Invalid instance id or document.')
    end

    local encoded = json.encode(document)
    if #encoded > 4096 then
        return Result.Err(Result.Codes.LIMIT_EXCEEDED, 'Metadata document exceeds 4096 bytes.',
            { size = #encoded, limit = 4096 })
    end

    if expectedRevision ~= nil then
        local current = self.query(
            'SELECT `metadata_revision` FROM `inventory_items` WHERE `id`=? FOR UPDATE;', { id })
        local actual = current and current[1] and tonumber(current[1].metadata_revision)
        if actual == nil then
            return Result.Err(Result.Codes.NOT_FOUND, 'Item instance does not exist.')
        end
        if actual ~= tonumber(expectedRevision) then
            return Result.Err(Result.Codes.CONFLICT, 'Metadata revision has moved since it was read.',
                { expected = tonumber(expectedRevision), actual = actual })
        end
    end

    self.query('UPDATE `inventory_items` SET `metadata`=?, `metadata_revision`=`metadata_revision`+1 WHERE `id`=?;',
        { encoded, id })

    local updated = self.query('SELECT `metadata_revision` FROM `inventory_items` WHERE `id`=? LIMIT 1;', { id })
    local revision = updated and updated[1] and tonumber(updated[1].metadata_revision)

    self.metadataChanged = self.metadataChanged or {}
    self.metadataChanged[#self.metadataChanged + 1] = { instanceId = id, revision = revision }

    return Result.Ok({ revision = revision })
end

---
-- Move Instance
--
-- Relocates a row, preserving identity, metadata and revision. Guarded and
-- locked before the write.
--
function Tx:MoveInstance(instanceId, toInventoryId, toSlot)
    local id = tonumber(instanceId)
    if not id or not toInventoryId then
        return Result.Err(Result.Codes.INVALID_INPUT, 'Invalid move parameters.')
    end

    local allowed, reason = GuardsAPI.CanMoveInstance(id, self.context)
    if not allowed then
        return Result.Err(Result.Codes.DENIED, reason or 'Move blocked by a guard.')
    end

    local rows = self.query('SELECT `inventory_id` FROM `inventory_items` WHERE `id`=? FOR UPDATE;', { id })
    local from = rows and rows[1] and tonumber(rows[1].inventory_id)
    if not from then
        return Result.Err(Result.Codes.NOT_FOUND, 'Item instance does not exist.')
    end

    self.query('UPDATE `inventory_items` SET `inventory_id`=?, `slot_index`=? WHERE `id`=?;',
        { toInventoryId, toSlot, id })

    self.moved = self.moved or {}
    self.moved[#self.moved + 1] =
        { instanceId = id, fromInventoryId = from, toInventoryId = toInventoryId }

    return Result.Ok(true)
end

---
-- Assert Access
--
-- Re-checks access INSIDE the transaction. The review's point: an inventory
-- having been opened earlier is not authority at commit time.
--
function Tx:AssertAccess(src, inventoryId, action)
    local decision = InventoryAPI.CanAccessInventory(src, inventoryId, action, self.context)
    if not Result.IsOk(decision) then
        return decision
    end
    return Result.Ok(true)
end

------------------------------------------------------------------
-- Runner
------------------------------------------------------------------

---
-- Transaction
--
-- @param context { actorSource, actorCharacterId, reason, correlationId, idempotencyKey, resource }
--        Improves auditability; never grants authority.
-- @param fn function(tx) -> value | Result
-- @return Result
--
function TransactionAPI.Transaction(context, fn)
    context = context or {}
    if type(fn) ~= 'function' then
        return Result.Err(Result.Codes.INVALID_INPUT, 'Transaction body must be a function.')
    end

    local cached = IdempotencyGet(context.idempotencyKey)
    if cached then
        Metrics.idempotentHits = Metrics.idempotentHits + 1
        return cached
    end

    Metrics.started = Metrics.started + 1

    local handle
    local committed, bodyResult, bodyError = RunInTransaction(function(query)
        handle = NewTx(query, context)
        return fn(handle)
    end)

    if bodyError then
        Metrics.bodyErrors = Metrics.bodyErrors + 1
        warn(('Transaction body errored (correlationId=%s, reason=%s): %s'):format(
            tostring(context.correlationId), tostring(context.reason), bodyError))
        return Result.Err(Result.Codes.INTERNAL, 'Transaction body errored: ' .. bodyError,
            nil, context.correlationId)
    end

    if not committed then
        Metrics.rolledBack = Metrics.rolledBack + 1
        if type(bodyResult) == 'table' and bodyResult.ok == false then
            if bodyResult.error and bodyResult.error.code == Result.Codes.CONFLICT then
                Metrics.conflicts = Metrics.conflicts + 1
            end
            return bodyResult
        end
        return Result.Err(Result.Codes.INTERNAL, 'Transaction rolled back.', nil, context.correlationId)
    end

    Metrics.committed = Metrics.committed + 1

    -- (INV-W3) Post-commit events, emitted only now: nothing announces itself
    -- from inside a transaction that might still roll back.
    if handle then
        for _, entry in ipairs(handle.created or {}) do
            GuardsAPI.EmitItemCreated(entry.instanceId, entry.definitionId, entry.inventoryId, context)
            TriggerEvent('feather-inventory:ItemAdded', entry.instanceId, 1, entry.inventoryId)
        end
        for _, entry in ipairs(handle.moved or {}) do
            GuardsAPI.EmitItemMoved(entry.instanceId, entry.fromInventoryId, entry.toInventoryId, context)
            if tostring(entry.fromInventoryId) ~= tostring(entry.toInventoryId) then
                TriggerEvent('feather-inventory:ItemRemoved', entry.instanceId, 1, entry.fromInventoryId)
                TriggerEvent('feather-inventory:ItemAdded', entry.instanceId, 1, entry.toInventoryId)
            end
        end
        for _, entry in ipairs(handle.metadataChanged or {}) do
            GuardsAPI.EmitItemMetadataChanged(entry.instanceId, entry.revision, context)
        end
        for _, entry in ipairs(handle.destroyed or {}) do
            GuardsAPI.EmitItemDestroyed(entry.instanceId, entry.definitionId, entry.inventoryId, context)
            TriggerEvent('feather-inventory:ItemRemoved', entry.instanceId, 1, entry.inventoryId)
        end
        GuardsAPI.EmitTransactionCommitted(context, {
            created = #(handle.created or {}),
            moved = #(handle.moved or {}),
            destroyed = #(handle.destroyed or {}),
        })
    end

    local result = Result.Ok(bodyResult, context.correlationId)
    IdempotencyPut(context.idempotencyKey, result)
    return result
end

InventoryAPI = InventoryAPI or {}
InventoryAPI.Transaction = TransactionAPI.Transaction
