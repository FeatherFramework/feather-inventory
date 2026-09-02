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
-- Bounded in-memory cache, with a limitation worth stating rather than
-- discovering:
--
-- IN-MEMORY IDEMPOTENCY DOES NOT SURVIVE A RESTART. A request retried across
-- a resource or server restart will find no record and WILL execute again.
-- For a reload or a repair that is acceptable -- the operation is cheap to
-- repeat and the state is re-derived anyway. For anything ECONOMIC (a
-- purchase, a payout, anything a player is charged for) it is not, and such a
-- caller needs a persisted idempotency record it owns, keyed on its own
-- domain, rather than relying on this cache.
--
-- Bounded because an unbounded cache keyed by caller-supplied strings is a
-- memory-exhaustion vector.
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

    -- (Weapons review #1) pcall returns (executed, value). Reading only the
    -- first is how a transaction that returned false WITHOUT raising gets
    -- treated as success -- post-commit events emitted for a rollback. Both
    -- are captured, and `executed` is checked before `committed` is trusted.
    local executed, committed = pcall(MySQL.startTransaction, function(query)
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

    if not executed then
        -- startTransaction itself failed (connection lost, upstream change in
        -- the experimental API). Nothing committed.
        return false, nil, tostring(committed)
    end

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
-- Require Access
--
-- (Weapons review) When the context names an `actorSource`, every mutating
-- operation asserts that actor's live access to the inventory it touches --
-- rather than trusting that whoever built the transaction checked beforehand.
-- A context with no actorSource is a trusted server-side operation (a
-- scripted payout, an admin grant) and is not gated.
--
-- Asserted per operation rather than once per transaction, because a
-- transaction can touch several inventories and access to one is not access
-- to another.
--
function Tx:RequireAccess(inventoryId, action)
    local src = self.context.actorSource
    if not src then
        return nil
    end

    local decision = InventoryAPI.CanAccessInventory(src, inventoryId, action, self.context)
    if not Result.IsOk(decision) then
        return decision
    end
    return nil
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
               ii.`metadata`, ii.`row_revision`,
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
        -- The instance revision, and the one a compare-and-set carries: it
        -- moves for metadata writes AND for moves.
        revision = tonumber(row.row_revision) or 0,
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

    local denied = self:RequireAccess(inventoryId, InventoryAPI.AccessModes.REMOVE)
    if denied then return denied end

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
        local locked = self:GetItemForUpdate(id)
        if not Result.IsOk(locked) then return locked end
        local allowed, reason = GuardsAPI.CanDestroyInstanceSnapshot(locked.value, self.context)
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
-- Remove Named Instances
--
-- Atomically removes caller-selected rows after verifying their inventory and
-- definition. This lets cross-resource callers commit the exact instances
-- used in their preflight calculation instead of repeating a name lookup.
--
function Tx:RemoveInstances(inventoryId, definitionId, instanceIds)
    if type(instanceIds) ~= 'table' or #instanceIds < 1 then
        return Result.Err(Result.Codes.INVALID_INPUT, 'At least one item instance is required.')
    end

    local denied = self:RequireAccess(inventoryId, InventoryAPI.AccessModes.REMOVE)
    if denied then return denied end

    local removed = {}
    for _, instanceId in ipairs(instanceIds) do
        local id = tonumber(instanceId)
        if not id then return Result.Err(Result.Codes.INVALID_INPUT, 'Invalid item instance id.') end
        local locked = self:GetItemForUpdate(id)
        if not Result.IsOk(locked) then return locked end
        if locked.value.inventoryId ~= tonumber(inventoryId)
            or locked.value.definition.id ~= tonumber(definitionId) then
            return Result.Err(Result.Codes.CONFLICT, 'Selected item instance is no longer available.', {
                instanceId = id, inventoryId = inventoryId, definitionId = definitionId })
        end
        local allowed, reason = GuardsAPI.CanDestroyInstanceSnapshot(locked.value, self.context)
        if not allowed then
            return Result.Err(Result.Codes.DENIED, reason or 'Removal blocked by a guard.', { instanceId = id })
        end

        -- DELETE is the locking operation. Scoping it by instance, inventory,
        -- and definition makes the affected-row count the ownership assertion;
        -- a concurrent move/delete produces zero and rolls back this transaction.
        local deleted = self.query(
            'DELETE FROM `inventory_items` WHERE `id`=? AND `inventory_id`=? AND `item_id`=?;',
            { id, inventoryId, definitionId })
        local affected = tonumber(deleted and (deleted.affectedRows or deleted.affected_rows)) or 0
        if affected ~= 1 then
            return Result.Err(Result.Codes.CONFLICT, 'Selected item instance is no longer available.', {
                instanceId = id,
                inventoryId = inventoryId,
                definitionId = definitionId,
                affectedRows = affected
            })
        end
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

    local denied = self:RequireAccess(inventoryId, InventoryAPI.AccessModes.INSERT)
    if denied then return denied end

    local defRows = self.query(
        'SELECT `name`, `max_stack_size`, `instance_mode`, `archived_at` FROM `items` WHERE `id`=? LIMIT 1 FOR UPDATE;', { definitionId })
    local def = defRows and defRows[1]
    if not def then
        return Result.Err(Result.Codes.NOT_FOUND, 'Item definition does not exist.')
    end
    if def.archived_at ~= nil then
        return Result.Err(Result.Codes.DENIED, 'Item definition is archived and cannot create new instances.',
            { definitionId = definitionId, itemName = def.name })
    end

    local stackSize = math.max(tonumber(def.max_stack_size) or 1, 1)
    local unique = def.instance_mode == 'unique'

    -- Weight, per-item quantity cap, blacklist and slot capacity, evaluated
    -- against locked rows inside this transaction.
    --
    -- This path previously enforced slot capacity alone. That was survivable
    -- while GrantItem was the ordinary way to create items, but once GrantItem
    -- refuses `unique` definitions (see ItemsAPI.GrantItem) every issuer --
    -- feather-weapons' Issuance among them -- reaches instances through
    -- CreateInstance, which lands here. A weaker gate on the only remaining
    -- path is a bypass around the very rule the refusal exists to enforce.
    --
    -- Deliberately NOT folded into the access check above: a trusted issuer
    -- runs with `actorSource = nil` and is exempt from RequireAccess by
    -- design, but nothing exempts it from what an inventory can physically
    -- hold.
    local accepted, code, message = InventoryControllers.AcceptanceInTransaction(
        self.query, inventoryId, { { item = def.name, quantity = wanted } })
    if not accepted then
        return Result.Err(code or Result.Codes.LIMIT_EXCEEDED,
            message or 'Inventory cannot accept these items.',
            { inventoryId = inventoryId, definitionId = definitionId, quantity = wanted })
    end

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
        SELECT `slot_index`, `item_id`, `metadata`
        FROM `inventory_items`
        WHERE `inventory_id`=? AND `slot_index` IS NOT NULL
        ORDER BY `slot_index`, `id` FOR UPDATE;
    ]], { inventoryId })

    local occupied, joinSlot, joinCount = {}, nil, 0
    local slots = {}
    for _, row in ipairs(occupiedRows or {}) do
        local slot = tonumber(row.slot_index)
        occupied[slot] = true
        slots[slot] = slots[slot] or {}
        slots[slot][#slots[slot] + 1] = row
    end
    local desiredMetadata = metadata or {}
    for slot, rows in pairs(slots) do
        if not unique and joinSlot == nil and tostring(rows[1].item_id) == tostring(definitionId)
            and #rows < stackSize and InventoryMetadata.RowsCompatible(rows)
            and InventoryMetadata.DocumentsEqual(
                InventoryMetadata.Decode(rows[1].metadata) or {}, desiredMetadata) then
            joinSlot, joinCount = slot, #rows
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
-- Create Instance
--
-- (Weapons review) Atomic creation of ONE unique instance with its complete
-- initial metadata -- the production equivalent of a `CreateInstance` the
-- review found missing. Returns the new instance id and its revision, so the
-- caller can immediately compare-and-set against it without a second read.
--
-- Refuses a `stack` definition on purpose: creating a single identified
-- instance is a unique-item operation, and silently creating one unit of a
-- stackable definition would produce something whose identity the caller
-- cannot rely on. Use AddQuantity for stackables.
--
function Tx:CreateInstance(inventoryId, definitionId, metadata)
    local defRows = self.query(
        'SELECT `instance_mode` FROM `items` WHERE `id`=? LIMIT 1;', { definitionId })
    local def = defRows and defRows[1]
    if not def then
        return Result.Err(Result.Codes.NOT_FOUND, 'Item definition does not exist.')
    end
    if def.instance_mode ~= 'unique' then
        return Result.Err(Result.Codes.UNSUPPORTED,
            'CreateInstance is for unique definitions; use AddQuantity for stackables.',
            { instanceMode = def.instance_mode })
    end

    local added = self:AddQuantity(inventoryId, definitionId, 1, metadata)
    if not Result.IsOk(added) then
        return added
    end

    local instanceId = added.value[1]
    local rows = self.query(
        'SELECT `row_revision` FROM `inventory_items` WHERE `id`=? LIMIT 1;', { instanceId })

    return Result.Ok({
        instanceId = instanceId,
        revision = tonumber(rows and rows[1] and rows[1].row_revision) or 0,
    })
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

    -- Locate first, then lock the complete compartment in one ordered query.
    -- Locking the target and its peers separately would let two callers take
    -- opposite row locks and deadlock while updating different units in the
    -- same stack. If the row moves between these reads it will be absent from
    -- the locked snapshot and the operation fails safely as a conflict.
    local located = self.query([[
        SELECT `inventory_id`, `slot_index`
        FROM `inventory_items`
        WHERE `id`=? LIMIT 1;
    ]], { id })
    local location = located and located[1]
    if not location then
        return Result.Err(Result.Codes.NOT_FOUND, 'Item instance does not exist.')
    end

    local locked
    if location.slot_index == nil then
        locked = self.query([[
            SELECT `id`, `inventory_id`, `item_id`, `slot_index`, `row_revision`, `metadata`
            FROM `inventory_items`
            WHERE `id`=? FOR UPDATE;
        ]], { id })
    else
        locked = self.query([[
            SELECT `id`, `inventory_id`, `item_id`, `slot_index`, `row_revision`, `metadata`
            FROM `inventory_items`
            WHERE `inventory_id`=? AND `slot_index`=?
            ORDER BY `id` FOR UPDATE;
        ]], { location.inventory_id, location.slot_index })
    end

    local row
    for _, candidate in ipairs(locked or {}) do
        if tonumber(candidate.id) == id then row = candidate break end
    end
    if not row then
        return Result.Err(Result.Codes.CONFLICT, 'Instance moved while metadata was being written.')
    end
    local actual = row and tonumber(row.row_revision)

    -- Compared against row_revision: the caller is asserting "nothing about
    -- this instance has changed since I read it", and a MOVE is such a change
    -- even though it leaves the document untouched.
    if expectedRevision ~= nil and actual ~= tonumber(expectedRevision) then
        return Result.Err(Result.Codes.CONFLICT, 'Instance revision has moved since it was read.',
            { expected = tonumber(expectedRevision), actual = actual })
    end

    if row.slot_index ~= nil and #(locked or {}) > 1 then
        for _, peer in ipairs(locked) do
                if tonumber(peer.id) ~= id then
                    local peerDocument = InventoryMetadata.Decode(peer.metadata)
                    if not peerDocument or not InventoryMetadata.DocumentsEqual(peerDocument, document) then
                        return Result.Err(Result.Codes.CONFLICT,
                            'Metadata cannot diverge within an existing stack.', {
                                inventoryId = tonumber(row.inventory_id),
                                slot = tonumber(row.slot_index),
                                instanceId = id,
                                peerInstanceId = tonumber(peer.id),
                            })
                    end
                end
        end
    end

    self.query([[
        UPDATE `inventory_items`
        SET `metadata`=?, `row_revision`=`row_revision`+1
        WHERE `id`=?;
    ]], { encoded, id })

    local updated = self.query(
        'SELECT `row_revision` FROM `inventory_items` WHERE `id`=? LIMIT 1;', { id })
    local revision = updated and updated[1] and tonumber(updated[1].row_revision)

    self.metadataChanged = self.metadataChanged or {}
    self.metadataChanged[#self.metadataChanged + 1] = {
        instanceId = id,
        definitionId = tonumber(row.item_id),
        inventoryId = tonumber(row.inventory_id),
        slot = tonumber(row.slot_index),
        revision = revision,
    }

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

    local rows = self.query(
        'SELECT `inventory_id`, `item_id`, `slot_index`, `row_revision` FROM `inventory_items` WHERE `id`=? FOR UPDATE;', { id })
    local row = rows and rows[1]
    if not row then
        return Result.Err(Result.Codes.NOT_FOUND, 'Item instance does not exist.')
    end
    local from = tonumber(row.inventory_id)

    -- (Weapons review #3) A move bumps row_revision, so a concurrent
    -- compare-and-set holding a pre-move revision correctly conflicts.
    self.query([[
        UPDATE `inventory_items`
        SET `inventory_id`=?, `slot_index`=?, `row_revision`=`row_revision`+1
        WHERE `id`=?;
    ]], { toInventoryId, toSlot, id })

    -- Equipment and movement lock the instance row first, so they serialize.
    -- If equip wins, a move out of its inventory must clear the binding in
    -- this same transaction; if move wins, the later equip re-derives
    -- ownership and is denied. Moving between compartments in the same
    -- inventory does not unequip the item.
    if from ~= tonumber(toInventoryId) then
        self.query(
            'DELETE FROM `character_equipment` WHERE `inventory_items_id`=?;', { id })
    end

    self.moved = self.moved or {}
    self.moved[#self.moved + 1] = {
        instanceId = id,
        fromInventoryId = from,
        toInventoryId = toInventoryId,
        definitionId = tonumber(row.item_id),
        fromSlot = tonumber(row.slot_index),
        toSlot = tonumber(toSlot),
        revision = (tonumber(row.row_revision) or 0) + 1,
    }

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
        end
        for _, entry in ipairs(handle.moved or {}) do
            GuardsAPI.EmitItemMoved(entry.instanceId, entry.fromInventoryId, entry.toInventoryId, context,
                { definitionId = entry.definitionId, revision = entry.revision })
        end
        for _, entry in ipairs(handle.metadataChanged or {}) do
            GuardsAPI.EmitItemMetadataChanged(entry.instanceId, entry.revision, context, entry)
        end
        for _, entry in ipairs(handle.destroyed or {}) do
            GuardsAPI.EmitItemDestroyed(entry.instanceId, entry.definitionId, entry.inventoryId, context)
        end
        GuardsAPI.EmitTransactionCommitted(context, {
            created = #(handle.created or {}),
            moved = #(handle.moved or {}),
            destroyed = #(handle.destroyed or {}),
        })
    end

    -- The body may return either a bare value or a Result, and the docs on
    -- this function say so. A success envelope must therefore pass THROUGH
    -- rather than be wrapped again: returning Result.Ok(value) from a body
    -- otherwise produced Result.Ok(Result.Ok(value)), so a caller reading
    -- result.value got an envelope where it expected its payload.
    --
    -- The failure case was already handled above -- a body returning ok=false
    -- rolls back and is returned as-is -- which is exactly why the asymmetry
    -- went unnoticed: only the success path double-wrapped.
    local result
    if type(bodyResult) == 'table' and bodyResult.ok == true then
        result = bodyResult
        if result.correlationId == nil then
            result.correlationId = context.correlationId
        end
    else
        result = Result.Ok(bodyResult, context.correlationId)
    end

    IdempotencyPut(context.idempotencyKey, result)
    return result
end

---
-- Mutate Item
--
-- Cross-resource safe transaction boundary. Function references can cross a
-- Cfx export, but a Lua transaction handle containing methods cannot. This
-- accepts data only, then performs the locked mutation entirely inside the
-- inventory resource.
--
function TransactionAPI.MutateItem(context, spec)
    if type(spec) ~= 'table' or not tonumber(spec.itemInstanceId) then
        return Result.Err(Result.Codes.INVALID_INPUT, 'A valid item mutation specification is required.')
    end

    return TransactionAPI.Transaction(context, function(tx)
        local locked = tx:GetItemForUpdate(spec.itemInstanceId)
        if not Result.IsOk(locked) then return locked end
        local item = locked.value

        if spec.expectedRevision ~= nil and tonumber(spec.expectedRevision) ~= tonumber(item.revision) then
            return Result.Err(Result.Codes.CONFLICT, 'Instance revision has moved since it was read.', {
                expected = tonumber(spec.expectedRevision), actual = tonumber(item.revision)
            })
        end

        for _, removal in ipairs(spec.removals or {}) do
            local removed
            if type(removal.instanceIds) == 'table' and #removal.instanceIds > 0 then
                removed = tx:RemoveInstances(item.inventoryId, removal.definitionId, removal.instanceIds)
            else
                removed = tx:RemoveQuantity(item.inventoryId, removal.definitionId, removal.quantity)
            end
            if not Result.IsOk(removed) then return removed end
        end

        for _, addition in ipairs(spec.additions or {}) do
            local added = tx:AddQuantity(item.inventoryId, addition.definitionId, addition.quantity, addition.metadata)
            if not Result.IsOk(added) then return added end
        end

        local revision = item.revision
        if spec.metadata ~= nil then
            local written = tx:SetMetadata(item.id, spec.metadata, item.revision)
            if not Result.IsOk(written) then return written end
            revision = written.value.revision
        end

        return { itemInstanceId = item.id, inventoryId = item.inventoryId, revision = revision }
    end)
end

---
-- Mutate Items
--
-- Cross-resource safe atomic metadata update for a small set of unique item
-- instances. IDs are locked in numeric order so callers updating the same pair
-- in opposite logical order cannot create an avoidable deadlock.
--
function TransactionAPI.MutateItems(context, spec)
    local requested = type(spec) == 'table' and spec.items or nil
    if type(requested) ~= 'table' or #requested < 1 or #requested > 8 then
        return Result.Err(Result.Codes.INVALID_INPUT,
            'Between one and eight item mutations are required.')
    end

    local items = {}
    local seen = {}
    for _, mutation in ipairs(requested) do
        local id = type(mutation) == 'table' and tonumber(mutation.itemInstanceId) or nil
        if not id or type(mutation.metadata) ~= 'table' or seen[id] then
            return Result.Err(Result.Codes.INVALID_INPUT,
                'Each item mutation requires a unique instance id and metadata document.')
        end
        seen[id] = true
        items[#items + 1] = mutation
    end
    table.sort(items, function(left, right)
        return tonumber(left.itemInstanceId) < tonumber(right.itemInstanceId)
    end)

    return TransactionAPI.Transaction(context, function(tx)
        local locked = {}
        for _, mutation in ipairs(items) do
            local result = tx:GetItemForUpdate(mutation.itemInstanceId)
            if not Result.IsOk(result) then return result end
            local item = result.value
            if mutation.expectedRevision ~= nil
                and tonumber(mutation.expectedRevision) ~= tonumber(item.revision) then
                return Result.Err(Result.Codes.CONFLICT,
                    'Instance revision has moved since it was read.', {
                        itemInstanceId = item.id,
                        expected = tonumber(mutation.expectedRevision),
                        actual = tonumber(item.revision)
                    })
            end
            locked[#locked + 1] = { mutation = mutation, item = item }
        end

        local committed = {}
        for _, entry in ipairs(locked) do
            local written = tx:SetMetadata(entry.item.id,
                entry.mutation.metadata, entry.item.revision)
            if not Result.IsOk(written) then return written end
            committed[#committed + 1] = {
                itemInstanceId = entry.item.id,
                inventoryId = entry.item.inventoryId,
                revision = written.value.revision
            }
        end
        return { items = committed }
    end)
end

--- Explicit destructive operation for trusted consumers and administration.
-- Exact instance ids, expected container/domain and a human-readable reason
-- are mandatory so destruction cannot degrade into an ambiguous quantity
-- adjustment. The normal destroy guards and post-commit facts still apply.
function TransactionAPI.DestroyInstances(context, spec)
    context = context or {}
    if type(spec) ~= 'table' or not tonumber(spec.inventoryId)
        or type(spec.instanceIds) ~= 'table' or #spec.instanceIds < 1
        or type(spec.expectedLocation) ~= 'string' or spec.expectedLocation == ''
        or type(context.reason) ~= 'string' or context.reason:match('^%s*$') then
        return Result.Err(Result.Codes.INVALID_INPUT,
            'Inventory, exact instance ids, expected owner domain, and destruction reason are required.')
    end

    local inventoryId = tonumber(spec.inventoryId)
    local instanceIds, seen = {}, {}
    for _, value in ipairs(spec.instanceIds) do
        local id = tonumber(value)
        if not id or seen[id] then
            return Result.Err(Result.Codes.INVALID_INPUT,
                'Destruction instance ids must be valid and unique.')
        end
        seen[id] = true
        instanceIds[#instanceIds + 1] = id
    end
    table.sort(instanceIds)

    return TransactionAPI.Transaction(context, function(tx)
        local containers = tx.query(
            'SELECT `location` FROM `inventory` WHERE `id`=? FOR UPDATE;', { inventoryId })
        local container = containers and containers[1]
        if not container then return Result.Err(Result.Codes.NOT_FOUND, 'Inventory does not exist.') end
        if container.location ~= spec.expectedLocation then
            return Result.Err(Result.Codes.DENIED, 'Inventory owner domain does not match.', {
                expected = spec.expectedLocation, actual = container.location })
        end

        local byDefinition = {}
        for _, value in ipairs(instanceIds) do
            local locked = tx:GetItemForUpdate(value)
            if not Result.IsOk(locked) then return locked end
            if locked.value.inventoryId ~= inventoryId then
                return Result.Err(Result.Codes.CONFLICT, 'Selected item is no longer in the expected inventory.', {
                    instanceId = tonumber(value), inventoryId = inventoryId })
            end
            local definitionId = locked.value.definition.id
            byDefinition[definitionId] = byDefinition[definitionId] or {}
            byDefinition[definitionId][#byDefinition[definitionId] + 1] = locked.value.id
        end

        local destroyed = {}
        for definitionId, ids in pairs(byDefinition) do
            local removed = tx:RemoveInstances(inventoryId, definitionId, ids)
            if not Result.IsOk(removed) then return removed end
            for _, id in ipairs(removed.value) do destroyed[#destroyed + 1] = id end
        end
        return Result.Ok({ inventoryId = inventoryId, destroyedInstanceIds = destroyed,
            quantity = #destroyed })
    end)
end

--- Apply a registered, data-only use action atomically to the clicked row.
-- Arbitrary gameplay code intentionally does not run while the DB transaction
-- is open; consumers receive the committed result afterward.
function TransactionAPI.UseItemAction(context, spec)
    if type(spec) ~= 'table' or not tonumber(spec.instanceId)
        or (spec.consume ~= true and type(spec.metadata) ~= 'table')
        or (spec.consume == true and spec.metadata ~= nil) then
        return Result.Err(Result.Codes.INVALID_INPUT,
            'A use action must consume the instance or replace its metadata.')
    end

    return TransactionAPI.Transaction(context, function(tx)
        local locked = tx:GetItemForUpdate(spec.instanceId)
        if not Result.IsOk(locked) then return locked end
        local item = locked.value
        local denied = tx:RequireAccess(item.inventoryId, InventoryAPI.AccessModes.REMOVE)
        if denied then return denied end
        if tonumber(spec.definitionId) and tonumber(spec.definitionId) ~= item.definition.id then
            return Result.Err(Result.Codes.CONFLICT, 'The item definition changed before use.')
        end
        if spec.expectedRevision ~= nil and tonumber(spec.expectedRevision) ~= item.revision then
            return Result.Err(Result.Codes.CONFLICT, 'Instance revision has moved since it was read.', {
                expected = tonumber(spec.expectedRevision), actual = item.revision })
        end

        if spec.consume == true then
            local removed = tx:RemoveInstances(item.inventoryId, item.definition.id, { item.id })
            if not Result.IsOk(removed) then return removed end
            return Result.Ok({ consumed = true, instanceId = item.id,
                definitionId = item.definition.id, inventoryId = item.inventoryId })
        end

        local written = tx:SetMetadata(item.id, spec.metadata, item.revision)
        if not Result.IsOk(written) then return written end
        return Result.Ok({ consumed = false, instanceId = item.id,
            definitionId = item.definition.id, inventoryId = item.inventoryId,
            revision = written.value.revision })
    end)
end
---
-- Create Instance For Character
--
-- Cross-resource-safe unique-instance creation. Resolves the character's
-- inventory inside feather-inventory and creates the row with its complete
-- metadata document in the same database transaction.
--
function TransactionAPI.CreateInstance(context, spec)
    local characterId = type(spec) == 'table'
        and InventoryIdentity.NormalizeCharacterId(spec.characterId) or nil
    if type(spec) ~= 'table' or not characterId
        or not tonumber(spec.definitionId) or type(spec.metadata) ~= 'table' then
        return Result.Err(Result.Codes.INVALID_INPUT, 'A valid unique-instance creation specification is required.')
    end

    local inventoryId = InventoryControllers.GetInventoryByCharacter(characterId)
    if not inventoryId then
        return Result.Err(Result.Codes.NOT_FOUND, 'The target character inventory does not exist.', {
            characterId = characterId
        }, context and context.correlationId)
    end

    return TransactionAPI.Transaction(context, function(tx)
        local created = tx:CreateInstance(inventoryId, tonumber(spec.definitionId), spec.metadata)
        if not Result.IsOk(created) then return created end
        return {
            instanceId = created.value.instanceId,
            revision = created.value.revision,
            inventoryId = inventoryId,
            characterId = characterId
        }
    end)
end

InventoryAPI = InventoryAPI or {}
InventoryAPI.Transaction = TransactionAPI.Transaction
