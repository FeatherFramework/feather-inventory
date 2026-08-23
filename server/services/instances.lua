-- (INV-W1) Item-instance contract layer: the foundation feather-weapons
-- builds on, per DEPENDENCY_SUPPORT_PLAN §4.4.
--
-- Three things live here, all of them generic -- nothing in this file knows
-- what a weapon is (MASTER_PLAN §3):
--
--   1. `instance_mode` on item definitions -- whether a definition's units are
--      interchangeable (`stack`) or each unit is its own thing (`unique`).
--   2. A versioned metadata DOCUMENT on each owned row, replacing the flat
--      key/value `item_metadata` table for anything that needs atomic or
--      concurrent-safe state.
--   3. A normalized read model, so a consumer gets one predictable shape
--      instead of the raw joined row whose columns have accreted over time.
--
-- Why the document, when `item_metadata` already exists: that table stores
-- VARCHAR(100) values and is written one key at a time with no transaction
-- and no version, so a two-key update is two independent writes that can
-- interleave with someone else's. For a weapon that is "ammo count" and
-- "chamber state" diverging. A single JSON column with a revision counter
-- makes the whole document one compare-and-set.
--
-- The flat table is NOT dropped -- it stays as a compatibility projection for
-- existing readers (see InstancesAPI.ReadMetadata's fallback), which is the
-- decision DEPENDENCY_SUPPORT_PLAN §4.4 left open.

InstancesAPI = {}

-- Documents are bounded so a caller cannot park unbounded state on a row.
-- Deliberately generous relative to anything weapons is expected to need
-- (ammo, condition, attachments, serial) while still being a real ceiling --
-- INV-W4 lists metadata size limits as hardening, this is the first cut.
local MAX_METADATA_BYTES = 4096

------------------------------------------------------------------
-- Schema
------------------------------------------------------------------

-- Self-migrated at startup, same pattern as slot_index/is_public/max_slots:
-- SHOW COLUMNS + conditional ALTER, never touching feather-recipe's
-- migration.sql. See MASTER_PLAN §5 for why that lineage exists.
local function EnsureInstanceSchema()
    local columns = MySQL.query.await("SHOW COLUMNS FROM `items` LIKE 'instance_mode';")
    if #columns < 1 then
        MySQL.query.await(
            "ALTER TABLE `items` ADD COLUMN `instance_mode` ENUM('stack','unique') NOT NULL DEFAULT 'stack';")
        -- Backfill from the signal that already encodes this: a definition
        -- that can only ever hold one per compartment is, in practice,
        -- already being treated as unique. Done once inside the add branch so
        -- a later deliberate change to a definition is never stomped by a
        -- restart.
        MySQL.query.await("UPDATE `items` SET `instance_mode`='unique' WHERE `max_stack_size` <= 1;")
    end

    columns = MySQL.query.await("SHOW COLUMNS FROM `inventory_items` LIKE 'metadata';")
    if #columns < 1 then
        MySQL.query.await([[
            ALTER TABLE `inventory_items`
            ADD COLUMN `metadata` JSON NULL,
            ADD COLUMN `metadata_revision` INT UNSIGNED NOT NULL DEFAULT 0;
        ]])
    end
end

CreateThread(function()
    EnsureInstanceSchema()
end)

------------------------------------------------------------------
-- Definitions
------------------------------------------------------------------

---
-- Is Unique Definition
--
-- @param itemId items.id
-- @return true when each unit of this definition is its own instance
--
function InstancesAPI.IsUniqueDefinition(itemId)
    local row = MySQL.query.await('SELECT `instance_mode` FROM `items` WHERE `id`=? LIMIT 1;', { itemId })[1]
    return row ~= nil and row.instance_mode == 'unique'
end

---
-- Set Instance Mode
--
-- Changing a definition to `unique` does not retroactively split stacks that
-- already exist -- it only governs future placement. Splitting existing
-- stacks would rewrite ownership rows as a side effect of an admin edit,
-- which is exactly the kind of surprise the parked item-definition editor
-- decision needs to think about before it ships.
--
-- @param itemId items.id
-- @param mode 'stack' | 'unique'
-- @return Result envelope
--
function InstancesAPI.SetInstanceMode(itemId, mode)
    if mode ~= 'stack' and mode ~= 'unique' then
        return Result.Err(Result.Codes.INVALID_INPUT, "instance_mode must be 'stack' or 'unique'.")
    end
    local numericId = tonumber(itemId)
    if not numericId then
        return Result.Err(Result.Codes.INVALID_INPUT, 'Invalid item definition id.')
    end

    local exists = MySQL.query.await('SELECT `id` FROM `items` WHERE `id`=? LIMIT 1;', { numericId })[1]
    if not exists then
        return Result.Err(Result.Codes.NOT_FOUND, 'Item definition does not exist.')
    end

    MySQL.query.await('UPDATE `items` SET `instance_mode`=? WHERE `id`=?;', { mode, numericId })
    return Result.Ok({ itemId = numericId, instanceMode = mode })
end

------------------------------------------------------------------
-- Metadata document (versioned, compare-and-set)
------------------------------------------------------------------

---
-- Read Metadata
--
-- Returns the document plus its revision. Falls back to projecting the legacy
-- flat `item_metadata` rows into a document when the column is still null,
-- so an instance written before this migration reads identically to one
-- written after -- that projection is what lets the flat table stay as a
-- compatibility layer rather than requiring a data migration.
--
-- @param instanceId inventory_items.id
-- @return Result envelope wrapping { document, revision }
--
function InstancesAPI.ReadMetadata(instanceId)
    local numericId = tonumber(instanceId)
    if not numericId then
        return Result.Err(Result.Codes.INVALID_INPUT, 'Invalid instance id.')
    end

    local row = MySQL.query.await(
        'SELECT `metadata`, `metadata_revision` FROM `inventory_items` WHERE `id`=? LIMIT 1;', { numericId })[1]
    if not row then
        return Result.Err(Result.Codes.NOT_FOUND, 'Item instance does not exist.')
    end

    local document
    if row.metadata ~= nil and row.metadata ~= '' then
        local decoded, err = pcall(json.decode, row.metadata)
        if decoded and type(err) == 'table' then
            document = err
        else
            -- A row whose JSON will not parse is a real problem, but refusing
            -- to read it would strand the instance entirely. Report it and
            -- hand back an empty document so the item stays usable -- the
            -- "malformed future metadata / quarantine" row of
            -- DEPENDENCY_SUPPORT_PLAN §15's test matrix.
            warn(('Instance %s has unparseable metadata; treating as empty.'):format(tostring(numericId)))
            document = {}
        end
    else
        document = {}
        for _, pair in pairs(InventoryControllers.GetMetadata(numericId) or {}) do
            document[pair.key] = pair.value
        end
    end

    return Result.Ok({ document = document, revision = tonumber(row.metadata_revision) or 0 })
end

---
-- Write Metadata
--
-- Replaces the whole document in one statement and bumps the revision.
--
-- Optimistic concurrency: pass `expectedRevision` and the write only lands if
-- the stored revision still matches, reported as CONFLICT otherwise. That is
-- the guarantee INV-W2's transaction API is built on, and the reason it is
-- here in W1 -- without a version there is nothing for a transaction to
-- compare against. Omitting `expectedRevision` is a deliberate
-- last-writer-wins for callers that genuinely do not care.
--
-- @param instanceId inventory_items.id
-- @param document Table to store (replaces, does not merge)
-- @param expectedRevision Optional revision the caller believes is current
-- @param correlationId Optional, threaded into the envelope
-- @return Result envelope wrapping { revision }
--
function InstancesAPI.WriteMetadata(instanceId, document, expectedRevision, correlationId)
    local numericId = tonumber(instanceId)
    if not numericId then
        return Result.Err(Result.Codes.INVALID_INPUT, 'Invalid instance id.', nil, correlationId)
    end
    if type(document) ~= 'table' then
        return Result.Err(Result.Codes.INVALID_INPUT, 'Metadata document must be a table.', nil, correlationId)
    end

    local encoded = json.encode(document)
    if #encoded > MAX_METADATA_BYTES then
        return Result.Err(Result.Codes.LIMIT_EXCEEDED,
            ('Metadata document exceeds %d bytes.'):format(MAX_METADATA_BYTES),
            { size = #encoded, limit = MAX_METADATA_BYTES }, correlationId)
    end

    local affected
    if expectedRevision ~= nil then
        affected = MySQL.update.await(
            'UPDATE `inventory_items` SET `metadata`=?, `metadata_revision`=`metadata_revision`+1 WHERE `id`=? AND `metadata_revision`=?;',
            { encoded, numericId, tonumber(expectedRevision) })
    else
        affected = MySQL.update.await(
            'UPDATE `inventory_items` SET `metadata`=?, `metadata_revision`=`metadata_revision`+1 WHERE `id`=?;',
            { encoded, numericId })
    end

    if not affected or affected < 1 then
        -- Zero affected rows is ambiguous on its own -- the row may not exist,
        -- or the revision may have moved. Distinguish them, because a caller
        -- retries a CONFLICT and gives up on a NOT_FOUND.
        local exists = MySQL.query.await('SELECT `metadata_revision` FROM `inventory_items` WHERE `id`=? LIMIT 1;',
            { numericId })[1]
        if not exists then
            return Result.Err(Result.Codes.NOT_FOUND, 'Item instance does not exist.', nil, correlationId)
        end
        return Result.Err(Result.Codes.CONFLICT, 'Metadata revision has moved since it was read.',
            { expected = tonumber(expectedRevision), actual = tonumber(exists.metadata_revision) }, correlationId)
    end

    local updated = MySQL.query.await('SELECT `metadata_revision` FROM `inventory_items` WHERE `id`=? LIMIT 1;',
        { numericId })[1]
    return Result.Ok({ revision = updated and tonumber(updated.metadata_revision) or nil }, correlationId)
end

---
-- Merge Metadata
--
-- Read-modify-write of a subset of keys, retrying once on a revision
-- conflict. The convenience form for the common "change one field" case,
-- which would otherwise make every caller hand-roll the same read/merge/CAS
-- dance. A nil value removes a key.
--
-- Retries exactly once: a second conflict means genuine contention on this
-- instance, and silently looping would hide it from the caller.
--
function InstancesAPI.MergeMetadata(instanceId, patch, correlationId)
    if type(patch) ~= 'table' then
        return Result.Err(Result.Codes.INVALID_INPUT, 'Metadata patch must be a table.', nil, correlationId)
    end

    for _ = 1, 2 do
        local current = InstancesAPI.ReadMetadata(instanceId)
        if not Result.IsOk(current) then
            return current
        end

        local document = current.value.document
        for key, value in pairs(patch) do
            document[key] = value
        end

        local written = InstancesAPI.WriteMetadata(instanceId, document, current.value.revision, correlationId)
        if Result.IsOk(written) or written.error.code ~= Result.Codes.CONFLICT then
            return written
        end
    end

    return Result.Err(Result.Codes.CONFLICT, 'Metadata contended; retry limit reached.', nil, correlationId)
end

------------------------------------------------------------------
-- Normalized instance read model
------------------------------------------------------------------

---
-- Get Instance
--
-- One predictable shape for an owned item, rather than the raw joined row
-- whose column set has grown organically. Preserves instance identity across
-- movement: `id` is the `inventory_items` row, which MoveSlotItems/
-- MoveInventoryItems update in place rather than delete-and-recreate, so a
-- weapon keeps its identity and metadata when it changes inventories.
--
-- @param instanceId inventory_items.id
-- @return Result envelope wrapping the normalized instance
--
function InstancesAPI.GetInstance(instanceId)
    local numericId = tonumber(instanceId)
    if not numericId then
        return Result.Err(Result.Codes.INVALID_INPUT, 'Invalid instance id.')
    end

    local row = MySQL.query.await([[
        SELECT ii.`id`, ii.`inventory_id`, ii.`slot_index`, ii.`metadata_revision`,
               i.`id` AS `definition_id`, i.`name`, i.`display_name`, i.`description`,
               i.`weight`, i.`usable`, i.`type`, i.`category_id`,
               i.`max_quantity`, i.`max_stack_size`, i.`instance_mode`
        FROM `inventory_items` ii
        INNER JOIN `items` i ON i.`id` = ii.`item_id`
        WHERE ii.`id` = ? LIMIT 1;
    ]], { numericId })[1]

    if not row then
        return Result.Err(Result.Codes.NOT_FOUND, 'Item instance does not exist.')
    end

    local metadata = InstancesAPI.ReadMetadata(numericId)
    if not Result.IsOk(metadata) then
        return metadata
    end

    return Result.Ok({
        id = tonumber(row.id),
        inventoryId = tonumber(row.inventory_id),
        slot = row.slot_index ~= nil and tonumber(row.slot_index) or nil,
        metadata = metadata.value.document,
        metadataRevision = metadata.value.revision,
        definition = {
            id = tonumber(row.definition_id),
            name = row.name,
            displayName = row.display_name,
            description = row.description,
            weight = tonumber(row.weight),
            usable = Boolean[row.usable] == true,
            type = row.type,
            categoryId = tonumber(row.category_id),
            maxQuantity = tonumber(row.max_quantity),
            maxStackSize = tonumber(row.max_stack_size),
            instanceMode = row.instance_mode or 'stack',
        }
    })
end

---
-- Find Instances
--
-- Instances of a definition within one inventory. Scoped to a single
-- inventory on purpose -- a global "find every instance of this definition"
-- would leak the contents of inventories the caller has no access to, which
-- DEPENDENCY_SUPPORT_PLAN §4.4 explicitly warns against.
--
-- @param inventoryId Raw inventory.id
-- @param definitionName items.name
-- @return Result envelope wrapping an array of instance ids
--
function InstancesAPI.FindInstances(inventoryId, definitionName)
    if not inventoryId or type(definitionName) ~= 'string' then
        return Result.Err(Result.Codes.INVALID_INPUT, 'Inventory id and definition name are required.')
    end

    local rows = MySQL.query.await([[
        SELECT ii.`id` FROM `inventory_items` ii
        INNER JOIN `items` i ON i.`id` = ii.`item_id`
        WHERE ii.`inventory_id` = ? AND i.`name` = ?;
    ]], { inventoryId, definitionName })

    local ids = {}
    for _, row in pairs(rows or {}) do
        ids[#ids + 1] = tonumber(row.id)
    end
    return Result.Ok(ids)
end

------------------------------------------------------------------
-- Readiness / capability query
------------------------------------------------------------------

-- Lets a dependent resource fail loudly at startup with a precise missing
-- capability, rather than discovering mid-operation that a contract it
-- assumed is absent (DEPENDENCY_SUPPORT_PLAN §3.4). Flags are declared
-- false until the phase that implements them lands, so this file is also the
-- honest running status of the INV-W track.
function InstancesAPI.GetCapabilities()
    return {
        version = '1.0.0',
        features = {
            instanceMode = true,        -- INV-W1: stack/unique on definitions
            metadataDocument = true,    -- INV-W1: versioned JSON document
            metadataRevision = true,    -- INV-W1: compare-and-set
            instanceReadModel = true,   -- INV-W1: normalized reads
            resultEnvelope = true,      -- INV-W1: shared { ok, value|error }
            transactions = false,       -- INV-W2
            movementGuards = false,     -- INV-W3
            postCommitEvents = false,   -- INV-W3
        }
    }
end
