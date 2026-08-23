-- (INV-W2) Transaction and concurrency layer, per DEPENDENCY_SUPPORT_PLAN §4.4.
--
-- READ THIS BEFORE CHANGING ANYTHING HERE -- the design is shaped by a hard
-- constraint in the database layer, not by preference.
--
-- oxmysql exposes `MySQL.transaction.await(queries) -> boolean`: an ARRAY of
-- statements, atomic, returning only success/failure. It does NOT expose an
-- interactive transaction -- there is no way to hold one connection open to
-- `SELECT ... FOR UPDATE`, run Lua logic against what came back, then write
-- inside that same transaction. So the plan's literal "deterministic
-- multi-item row locking" is not achievable with this dependency, and
-- pretending otherwise would ship a lock that does not lock.
--
-- What replaces it is optimistic concurrency, which is strictly why INV-W1
-- put a revision counter on every row:
--
--   1. READ phase, outside the transaction -- gather instances and note the
--      `metadata_revision` each one was read at.
--   2. VALIDATE phase -- pure Lua, no database access, no side effects.
--   3. COMMIT phase -- one atomic batch consisting of a GUARD statement
--      followed by the queued writes.
--
-- The guard is the load-bearing piece. A CAS-style `UPDATE ... WHERE
-- revision = ?` that matches nothing does NOT raise an error, it simply
-- affects zero rows -- and since the batch API reports no per-statement
-- affected counts, a stale write would commit silently alongside its
-- siblings and leave partial state. The guard instead re-checks every
-- recorded revision in a single statement and deliberately provokes
-- ER_SUBQUERY_NO_1_ROW (`SELECT 1 UNION SELECT 2` used as a scalar) when any
-- has moved. That error aborts the batch, so the whole transaction rolls
-- back. Verified against MariaDB 12.3: matching revisions return cleanly,
-- a stale one errors and rolls the transaction back.
--
-- Consequence worth stating plainly: this is optimistic, not pessimistic.
-- Two transactions touching the same rows do not queue -- one commits and
-- the other is told CONFLICT and retries. That is the behaviour the exit
-- gate asks for ("one commit and one explicit conflict"), and it is safe,
-- but it is not a lock and should not be described as one.

TransactionAPI = {}

local MAX_ATTEMPTS = 3

------------------------------------------------------------------
-- Idempotency
------------------------------------------------------------------
--
-- Bounded in-memory cache, not a table: an idempotency record only has to
-- outlive the retry window of the request that created it, and persisting it
-- would mean a schema plus a cleanup job for something that is worthless
-- after a restart anyway (a client that retries across a server restart has
-- much larger problems than a duplicated grant).
--
-- Bounded on purpose -- an unbounded cache keyed by caller-supplied strings
-- is a memory-exhaustion vector.
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
        -- Evict oldest-first once over the cap.
        while #IdempotencyOrder > MAX_IDEMPOTENCY_ENTRIES do
            local oldest = table.remove(IdempotencyOrder, 1)
            IdempotencyCache[oldest] = nil
        end
    end

    IdempotencyCache[key] = {
        result = result,
        expiresAt = GetGameTimer() + IDEMPOTENCY_TTL_MS
    }
end

------------------------------------------------------------------
-- Transaction handle
------------------------------------------------------------------

local Tx = {}
Tx.__index = Tx

local function NewTx(context)
    return setmetatable({
        context = context or {},
        reads = {},   -- [instanceId] = revision observed during the read phase
        writes = {},  -- ordered queue of { query, values }
        touched = {}, -- set of instance ids, for deterministic ordering
    }, Tx)
end

---
-- Get Instance (read phase)
--
-- Reads an instance and RECORDS the revision it was read at. Every id passed
-- through here is re-verified by the commit guard, so a caller that reads an
-- item, reasons about it, and writes something derived from it is protected
-- even if the write does not touch that item directly -- which is the
-- reload case: ammo count is read, the weapon's metadata is what changes.
--
function Tx:GetInstance(instanceId)
    local id = tonumber(instanceId)
    if not id then
        return Result.Err(Result.Codes.INVALID_INPUT, 'Invalid instance id.')
    end

    local instance = InstancesAPI.GetInstance(id)
    if not Result.IsOk(instance) then
        return instance
    end

    self.reads[id] = instance.value.metadataRevision
    self.touched[id] = true
    return instance
end

---
-- Set Metadata (write phase, queued)
--
-- Queued rather than executed. Nothing this handle records reaches the
-- database until Commit runs the whole batch, which is what makes the
-- validate phase side-effect free and safely re-runnable on conflict.
--
function Tx:SetMetadata(instanceId, document)
    local id = tonumber(instanceId)
    if not id or type(document) ~= 'table' then
        return Result.Err(Result.Codes.INVALID_INPUT, 'Invalid instance id or document.')
    end

    local encoded = json.encode(document)
    self.touched[id] = true
    self.writes[#self.writes + 1] = {
        id = id,
        query = 'UPDATE `inventory_items` SET `metadata`=?, `metadata_revision`=`metadata_revision`+1 WHERE `id`=?;',
        values = { encoded, id }
    }
    return Result.Ok(true)
end

---
-- Move Instance (write phase, queued)
--
-- Preserves instance identity -- the row moves, it is not deleted and
-- recreated -- so metadata, revision and id all survive the move. That is
-- what DEPENDENCY_SUPPORT_PLAN §4.4 means by "preserve instance identity
-- during movement", and it is why a transferred weapon keeps its state.
--
function Tx:MoveInstance(instanceId, toInventory, toSlot)
    local id = tonumber(instanceId)
    if not id or not toInventory then
        return Result.Err(Result.Codes.INVALID_INPUT, 'Invalid move parameters.')
    end

    self.touched[id] = true
    self.writes[#self.writes + 1] = {
        id = id,
        query = 'UPDATE `inventory_items` SET `inventory_id`=?, `slot_index`=? WHERE `id`=?;',
        values = { toInventory, toSlot, id }
    }
    return Result.Ok(true)
end

---
-- Destroy Instance (write phase, queued)
--
function Tx:DestroyInstance(instanceId)
    local id = tonumber(instanceId)
    if not id then
        return Result.Err(Result.Codes.INVALID_INPUT, 'Invalid instance id.')
    end

    self.touched[id] = true
    self.writes[#self.writes + 1] = {
        id = id,
        query = 'DELETE FROM `inventory_items` WHERE `id`=?;',
        values = { id }
    }
    return Result.Ok(true)
end

---
-- Build Guard
--
-- One statement that re-checks every revision recorded during the read
-- phase, and errors if any has moved. See the file header for why an error
-- rather than a predicate: the batch API cannot report per-statement
-- affected rows, so a silently-skipped CAS would leave partial state.
--
-- Returns nil when nothing was read -- a write-only transaction has no
-- revision to conflict against and needs no guard.
--
local function BuildGuard(reads)
    local clauses, values = {}, {}
    for id, revision in pairs(reads) do
        clauses[#clauses + 1] = '(`id`=? AND `metadata_revision`<>?)'
        values[#values + 1] = id
        values[#values + 1] = revision
    end

    if #clauses == 0 then
        return nil
    end

    return {
        query = ('SELECT CASE WHEN (SELECT COUNT(*) FROM `inventory_items` WHERE %s) = 0 '
            .. 'THEN 1 ELSE (SELECT 1 UNION SELECT 2) END;'):format(table.concat(clauses, ' OR ')),
        values = values
    }
end

------------------------------------------------------------------
-- Transaction runner
------------------------------------------------------------------

---
-- Transaction
--
-- Runs `fn(tx)` and commits everything it queued as one atomic batch.
--
-- @param context { actorSource, actorCharacterId, reason, correlationId, idempotencyKey, resource }
--        Per DEPENDENCY_SUPPORT_PLAN §3.2, context improves auditability and
--        NEVER grants authority -- nothing here trusts actorCharacterId to
--        decide access; callers still re-derive that from `source` as every
--        other path in this resource does.
-- @param fn function(tx) -> value | Result
-- @return Result envelope
--
function TransactionAPI.Transaction(context, fn)
    context = context or {}
    if type(fn) ~= 'function' then
        return Result.Err(Result.Codes.INVALID_INPUT, 'Transaction body must be a function.')
    end

    local cached = IdempotencyGet(context.idempotencyKey)
    if cached then
        return cached
    end

    local lastConflict
    for attempt = 1, MAX_ATTEMPTS do
        local tx = NewTx(context)

        -- Validate phase. pcall so a bug in the caller's closure surfaces as
        -- a clean envelope instead of taking the RPC handler down with it --
        -- and, critically, so it aborts BEFORE anything was written, since
        -- nothing reaches the database until commit.
        local succeeded, outcome = pcall(fn, tx)
        if not succeeded then
            return Result.Err(Result.Codes.INTERNAL, 'Transaction body errored: ' .. tostring(outcome),
                nil, context.correlationId)
        end

        -- A body may bail out early by returning a failure envelope; that is
        -- a rejection, not a conflict, so it is returned as-is without
        -- committing or retrying.
        if type(outcome) == 'table' and outcome.ok == false then
            return outcome
        end

        if #tx.writes == 0 then
            local readOnly = Result.Ok(outcome, context.correlationId)
            IdempotencyPut(context.idempotencyKey, readOnly)
            return readOnly
        end

        -- Deterministic ordering. Two transactions touching the same rows
        -- queue their writes in the same sequence, so they contend in a
        -- predictable order rather than deadlocking against each other.
        -- Sorted by the instance id each write targets, recorded explicitly
        -- rather than inferred from argument position -- which would silently
        -- reorder wrongly the moment a statement's parameter order changed.
        table.sort(tx.writes, function(a, b)
            return (a.id or 0) < (b.id or 0)
        end)

        local batch = {}
        local guard = BuildGuard(tx.reads)
        if guard then
            batch[#batch + 1] = guard
        end
        for _, write in ipairs(tx.writes) do
            -- Only query/values go to oxmysql; `id` is bookkeeping for the
            -- ordering above and is not part of the statement.
            batch[#batch + 1] = { query = write.query, values = write.values }
        end

        local committed = pcall(MySQL.transaction.await, batch)
        if committed then
            local result = Result.Ok(outcome, context.correlationId)
            IdempotencyPut(context.idempotencyKey, result)
            return result
        end

        -- Failure here is overwhelmingly the guard firing, i.e. someone else
        -- committed against a row we had read. Retry the WHOLE closure --
        -- re-reading is the point, since the caller's decision was made
        -- against state that has since changed.
        lastConflict = attempt
    end

    return Result.Err(Result.Codes.CONFLICT,
        ('Transaction contended and was retried %d times without committing.'):format(MAX_ATTEMPTS),
        { attempts = lastConflict }, context.correlationId)
end

-- Surfaced on InventoryAPI too, since DEPENDENCY_SUPPORT_PLAN §4.4 writes
-- the candidate interface as `Inventory.Transaction(context, fn)`.
InventoryAPI = InventoryAPI or {}
InventoryAPI.Transaction = TransactionAPI.Transaction
