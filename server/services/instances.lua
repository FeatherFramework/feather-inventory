-- (INV-W1) Item-instance contract layer: the foundation feather-weapons
-- builds on, per DEPENDENCY_SUPPORT_PLAN §4.4.
--
-- Three things live here, all of them generic -- nothing in this file knows
-- what a weapon is (MASTER_PLAN §3):
--
--   1. `instance_mode` on item definitions -- whether a definition's units are
--      interchangeable (`stack`) or each unit is its own thing (`unique`).
--   2. A versioned metadata DOCUMENT on each owned row -- one JSON column
--      plus `row_revision`, so the whole document is one compare-and-set
--      rather than a series of independent per-key writes that can interleave
--      with someone else's. For a weapon that is the difference between
--      "ammo count" and "chamber state" agreeing and diverging.
--   3. A normalized read model, so a consumer gets one predictable shape
--      instead of the raw joined row whose columns have accreted over time.
--
-- DEPENDENCY_SUPPORT_PLAN §4.4 left open whether the old flat key/value table
-- survives as a compatibility projection. It does not: nothing consumed it,
-- and this resource no longer references it in any form.
--
-- The table is stopped at its source -- `feather-recipe` no longer creates it
-- -- rather than dropped from here. Nothing in this file drops a table it
-- did not create: the columns added below are this resource's own to add and
-- to remove, but the base schema belongs to the migration that defines it.

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
        MySQL.query.await("ALTER TABLE `inventory_items` ADD COLUMN `metadata` JSON NULL;")
    end

    -- `row_revision` is THE instance revision, bumped by any change to the
    -- row -- metadata writes, moves, slot changes.
    --
    -- A metadata-only revision was insufficient: a caller could read
    -- ammunition, another request could MOVE that ammunition to a different
    -- inventory without touching metadata, and the first caller's
    -- compare-and-set would still pass -- then delete the ammo from its new
    -- owner. Movement is a state change the revision has to see.
    columns = MySQL.query.await("SHOW COLUMNS FROM `inventory_items` LIKE 'row_revision';")
    if #columns < 1 then
        MySQL.query.await(
            "ALTER TABLE `inventory_items` ADD COLUMN `row_revision` INT UNSIGNED NOT NULL DEFAULT 0;")
    end

    -- A `metadata_revision` column used to sit alongside this one, so a
    -- consumer that only cared whether the DOCUMENT changed could ask that
    -- narrower question. No consumer ever did, and two counters where one is
    -- authoritative made every new compare-and-set a coin flip about which to
    -- compare. It is simply no longer created -- there is deliberately no
    -- migration to remove it from a database that already has one, because
    -- this is an alpha framework whose servers are rebuilt rather than
    -- upgraded in place. On such a database the column is left behind, unread
    -- and unwritten, defaulting to 0 on insert; a rebuild clears it.

    -- Weight as exact fixed-point rather than a whole number, so an item can
    -- weigh less than a pound (an apple at 0.25). DECIMAL and not FLOAT
    -- deliberately: weights are SUMmed across an inventory and compared
    -- against a limit, and binary floating point accumulates error that makes
    -- that comparison unreliable exactly at the boundary. Same reasoning the
    -- schema already applies to money and coordinates.
    --
    -- Widening INT -> DECIMAL is lossless (1 becomes 1.00), so this needs no
    -- data migration. Guarded on the current type so it runs once.
    local weightType = MySQL.query.await("SHOW COLUMNS FROM `items` LIKE 'weight';")[1]
    if weightType and tostring(weightType.Type or ''):find('int') then
        MySQL.query.await("ALTER TABLE `items` MODIFY COLUMN `weight` DECIMAL(6,2) NOT NULL DEFAULT 0;")
    end

    local limitType = MySQL.query.await("SHOW COLUMNS FROM `inventory` LIKE 'max_weight';")[1]
    if limitType and tostring(limitType.Type or ''):find('int') then
        MySQL.query.await("ALTER TABLE `inventory` MODIFY COLUMN `max_weight` DECIMAL(8,2) NULL;")
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
-- Returns the document plus its revision. An instance with no document yet
-- reads as an empty table, not nil, so callers never branch on absence.
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
        'SELECT `metadata`, `row_revision` FROM `inventory_items` WHERE `id`=? LIMIT 1;', { numericId })[1]
    if not row then
        return Result.Err(Result.Codes.NOT_FOUND, 'Item instance does not exist.')
    end

    local document
    if row.metadata ~= nil and row.metadata ~= '' then
        local parsed, decoded = pcall(json.decode, row.metadata)
        if parsed and type(decoded) == 'table' then
            document = decoded
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
    end

    return Result.Ok({ document = document, revision = tonumber(row.row_revision) or 0 })
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
            'UPDATE `inventory_items` SET `metadata`=?, `row_revision`=`row_revision`+1 WHERE `id`=? AND `row_revision`=?;',
            { encoded, numericId, tonumber(expectedRevision) })
    else
        affected = MySQL.update.await(
            'UPDATE `inventory_items` SET `metadata`=?, `row_revision`=`row_revision`+1 WHERE `id`=?;',
            { encoded, numericId })
    end

    if not affected or affected < 1 then
        -- Zero affected rows is ambiguous on its own -- the row may not exist,
        -- or the revision may have moved. Distinguish them, because a caller
        -- retries a CONFLICT and gives up on a NOT_FOUND.
        local exists = MySQL.query.await('SELECT `row_revision` FROM `inventory_items` WHERE `id`=? LIMIT 1;',
            { numericId })[1]
        if not exists then
            return Result.Err(Result.Codes.NOT_FOUND, 'Item instance does not exist.', nil, correlationId)
        end
        return Result.Err(Result.Codes.CONFLICT, 'Instance revision has moved since it was read.',
            { expected = tonumber(expectedRevision), actual = tonumber(exists.row_revision) }, correlationId)
    end

    local updated = MySQL.query.await('SELECT `row_revision` FROM `inventory_items` WHERE `id`=? LIMIT 1;',
        { numericId })[1]
    return Result.Ok({ revision = updated and tonumber(updated.row_revision) or nil }, correlationId)
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
        SELECT ii.`id`, ii.`inventory_id`, ii.`slot_index`, ii.`row_revision`,
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
        revision = tonumber(row.row_revision) or 0,
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

---
-- Get Item For Character
--
-- (Weapons review #10) An instance read scoped to a character -- returns
-- NOT_FOUND rather than the row if that character does not actually hold it.
--
-- Deliberately not a thin alias for GetInstance: the ownership assertion is
-- the point. A consumer asking "give me this character's weapon" should not
-- silently receive someone else's by passing the wrong id.
--
-- @param characterId
-- @param instanceId inventory_items.id
-- @return Result wrapping the normalized instance
--
function InstancesAPI.GetItemForCharacter(characterId, instanceId)
    local charId = tonumber(characterId)
    local id = tonumber(instanceId)
    if not charId or not id then
        return Result.Err(Result.Codes.INVALID_INPUT, 'Character id and instance id are required.')
    end

    local owned = MySQL.query.await([[
        SELECT ii.`id` FROM `inventory_items` ii
        INNER JOIN `inventory` inv ON inv.`id` = ii.`inventory_id`
        WHERE ii.`id` = ? AND inv.`character_id` = ? LIMIT 1;
    ]], { id, charId })[1]

    if not owned then
        return Result.Err(Result.Codes.NOT_FOUND, 'That character does not hold this item.',
            { instanceId = id, characterId = charId })
    end

    return InstancesAPI.GetInstance(id)
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
        -- Human-readable, for logs and operators.
        version = '2.0.0',
        -- Machine-comparable, for a consumer's startup gate. Deliberately a
        -- plain integer and NOT the semver string: a consumer compares it
        -- numerically, and `tonumber('2.0.0')` is nil, which would silently
        -- collapse to 0 and fail every check.
        --
        -- Bumped to 2 for the result-envelope migration. A key-existence
        -- check cannot detect a changed return shape, so this is the only
        -- thing standing between a consumer built for contract 1 and a
        -- resource that now answers in envelopes.
        contractVersion = 2,
        features = {
            instanceMode = true,        -- INV-W1: stack/unique on definitions
            metadataDocument = true,    -- INV-W1: versioned JSON document
            instanceRevision = true,    -- INV-W1: compare-and-set on row_revision
            instanceReadModel = true,   -- INV-W1: normalized reads
            resultEnvelope = true,      -- INV-W1: shared { ok, value|error }
            transactions = true,        -- INV-W2: optimistic, revision-guarded
            movementGuards = true,      -- INV-W3: pre-move/destroy veto registry
            postCommitEvents = true,    -- INV-W3: structured, internal, post-commit
            accessModes = true,         -- INV-W4: read/insert/remove/manage
            metadataSizeLimit = true,   -- INV-W4: bounded documents
            transactionMetrics = true,  -- INV-W4: contention counters
            rowLocking = true,          -- real SELECT ... FOR UPDATE via startTransaction
            equippedState = true,       -- persisted character equipment slots
            atomicCreation = true,      -- instance + metadata in one statement
        }
    }
end
