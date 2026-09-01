-- (INV-05) Gated on Config.DevMode (default false) AND registered as
-- ACE-restricted ("true" below, was "false") -- so a server that flips
-- DevMode back on for testing doesn't hand free-item commands to every
-- player, only to principals explicitly granted `command.<name>`.
if Config.DevMode then
    local LifecycleSmokeRunning = false
    local LifecycleSmokeEvents = nil

    -- Use the public event names directly here. services/*.lua loads this
    -- file before guards.lua, so dereferencing GuardsAPI during file load
    -- prevents every DevMode command below from registering.
    AddEventHandler('Feather:Inventory:ItemDestroyed', function(fact)
        if LifecycleSmokeEvents and fact
            and fact.correlationId == LifecycleSmokeEvents.correlationId then
            LifecycleSmokeEvents.destroyed[#LifecycleSmokeEvents.destroyed + 1] = fact
        end
    end)

    AddEventHandler('Feather:Inventory:DefinitionMigrated', function(fact)
        if LifecycleSmokeEvents and fact
            and fact.reason == LifecycleSmokeEvents.migrationReason then
            LifecycleSmokeEvents.migrated[#LifecycleSmokeEvents.migrated + 1] = fact
        end
    end)

    RegisterCommand('AddItems', function(source, args)
        local result = ItemsAPI.AddItem(args[1], tonumber(args[2]), args[3] or nil, source)

        if not Result.IsOk(result) then
            Feather.Notify.RightNotify(source, TranslateResult(source, result, 'err_move_failed'), 3000)
        else
            Feather.Notify.RightNotify(source, Translate(source, 'msg_item_added', 'Item added.'), 3000)
        end
    end, true)

    RegisterCommand('AddApples', function(source, args)
        local result = ItemsAPI.AddItem('consumable_apple', 5, {
            display = '4 bites left',
            current = 4,
            left = 10
        }, source)

        if not Result.IsOk(result) then
            Feather.Notify.RightNotify(source, TranslateResult(source, result, 'err_move_failed'), 3000)
        else
            Feather.Notify.RightNotify(source, Translate(source, 'msg_item_added', 'Item added.'), 3000)
        end
    end, true)

    -- (Weapons review) End-to-end check of the real transaction path.
    -- startTransaction is flagged EXPERIMENTAL upstream and its Lua calling
    -- convention (awaiting across the JS boundary) cannot be verified from
    -- outside a running server -- so this exercises it for real rather than
    -- leaving the assumption untested. Run it once after any oxmysql upgrade.
    RegisterCommand('InvTxSmokeTest', function(source)
        local player = InventoryIdentity.GetCharacter(source)
        local character = player and player.char
        if not character then return end
        local inventory = InventoryControllers.GetInventoryByCharacter(character.id)
        if not inventory then return end

        local definition = ItemControllers.GetItemDefinitionByName('consumable_apple')
        if not definition then
            print('[InvTxSmokeTest] seed item consumable_apple missing; aborting')
            return
        end

        local function report(label, ok, detail)
            print(('[InvTxSmokeTest] %-34s %s%s'):format(
                label, ok and 'PASS' or 'FAIL', detail and ('  -- ' .. detail) or ''))
        end

        -- 1. Create + metadata in one transaction, and read it back inside.
        local created
        local one = InventoryAPI.Transaction({ reason = 'smoketest_create' }, function(tx)
            local added = tx:AddQuantity(inventory, definition.id, 1, { smoketest = true, ammo = 6 })
            if not Result.IsOk(added) then return added end
            created = added.value[1]
            local read = tx:GetItemForUpdate(created)
            if not Result.IsOk(read) then return read end
            return read.value.metadata.ammo
        end)
        report('create + metadata + locked read', Result.IsOk(one) and one.value == 6,
            Result.IsOk(one) and ('ammo=' .. tostring(one.value)) or (one.error and one.error.message))

        -- 2. Rollback must leave nothing behind.
        local before = InventoryControllers.InventoryItemCount(inventory, definition.id)
        InventoryAPI.Transaction({ reason = 'smoketest_rollback' }, function(tx)
            tx:AddQuantity(inventory, definition.id, 1)
            return Result.Err(Result.Codes.DENIED, 'deliberate rollback')
        end)
        local after = InventoryControllers.InventoryItemCount(inventory, definition.id)
        report('rollback discards writes', before == after, ('before=%s after=%s'):format(before, after))

        -- 3. Stale revision must be refused.
        local stale = InventoryAPI.Transaction({ reason = 'smoketest_cas' }, function(tx)
            return tx:SetMetadata(created, { ammo = 0 }, 999)
        end)
        report('stale revision rejected',
            not Result.IsOk(stale) and stale.error.code == Result.Codes.CONFLICT,
            stale.error and stale.error.code)

        -- 4. Ammo DELETED mid-flight must conflict, not silently succeed.
        --    (Review #2) Simulated by deleting the row, then attempting a CAS
        --    against the revision read before it vanished.
        local ghost
        InventoryAPI.Transaction({ reason = 'smoketest_seed_ghost' }, function(tx)
            local added = tx:AddQuantity(inventory, definition.id, 1)
            if Result.IsOk(added) then ghost = added.value[1] end
            return true
        end)
        -- DevMode fixture: deliberately removes a row outside the transaction
        -- to prove a stale transaction fails safely when its target vanishes.
        MySQL.query.await('DELETE FROM `inventory_items` WHERE `id`=?;', { ghost })
        local deleted = InventoryAPI.Transaction({ reason = 'smoketest_deleted' }, function(tx)
            return tx:SetMetadata(ghost, { ammo = 1 }, 0)
        end)
        report('deleted row conflicts',
            not Result.IsOk(deleted) and deleted.error.code == Result.Codes.NOT_FOUND,
            deleted.error and deleted.error.code)

        -- 5. Ammo MOVED mid-flight must conflict. (Review #3) row_revision has
        --    to move for a move, or a stale CAS would still pass and consume
        --    ammunition from its new owner.
        local mover
        InventoryAPI.Transaction({ reason = 'smoketest_seed_move' }, function(tx)
            local added = tx:AddQuantity(inventory, definition.id, 1)
            if Result.IsOk(added) then mover = added.value[1] end
            return true
        end)
        local beforeMove = InstancesAPI.GetInstance(mover)
        local staleRevision = Result.IsOk(beforeMove) and beforeMove.value.revision or 0
        InventoryAPI.Transaction({ reason = 'smoketest_do_move' }, function(tx)
            return tx:MoveInstance(mover, inventory, 24)
        end)
        local movedConflict = InventoryAPI.Transaction({ reason = 'smoketest_moved' }, function(tx)
            return tx:SetMetadata(mover, { ammo = 0 }, staleRevision)
        end)
        report('moved row conflicts (row_revision)',
            not Result.IsOk(movedConflict) and movedConflict.error.code == Result.Codes.CONFLICT,
            movedConflict.error and movedConflict.error.code)

        -- 6. Legacy removal must respect a destroy guard. (Review #4)
        GuardsAPI.RegisterDestroyGuard('smoketest_veto', function()
            return false, 'smoketest veto'
        end)
        local vetoed = ItemsAPI.RemoveItemById(mover)
        GuardsAPI.UnregisterDestroyGuard('smoketest_veto')
        report('legacy removal respects guard', not Result.IsOk(vetoed), vetoed.error and vetoed.error.message)

        ------------------------------------------------------------------
        -- Acceptance gates on the transactional add path.
        --
        -- These matter more than their size suggests. GrantItem refuses
        -- `unique` definitions, so every issuer reaches instances through
        -- CreateInstance -> Tx:AddQuantity. If that path enforced only slot
        -- capacity -- which it did until contract 2 -- it would be a
        -- lower-level bypass around the very gates the refusal exists to
        -- protect. Each case asserts a REJECTION, so a silently-restored
        -- bypass fails the suite rather than passing it quietly.
        ------------------------------------------------------------------

        local function expectRejection(label, expectedCode, spec)
            local outcome = InventoryAPI.Transaction({ reason = 'smoketest_gate' }, function(tx)
                return tx:AddQuantity(spec.inventory, spec.definitionId, spec.quantity)
            end)
            local code = (not Result.IsOk(outcome)) and outcome.error.code or nil
            report(label, code == expectedCode,
                ('expected=%s actual=%s'):format(expectedCode, tostring(code)))
            return outcome
        end

        local uniqueRow = MySQL.query.await(
            "SELECT `id`, `name` FROM `items` WHERE `instance_mode`='unique' LIMIT 1;")[1]

        -- 7. Weight. Temporarily lower this inventory's limit below the
        --    weight of one additional unit and bypass only the quantity cap,
        --    so weight is the first gate capable of rejecting the request.
        local restoredWeight = MySQL.query.await(
            'SELECT `max_weight`, `ignore_item_limit` FROM `inventory` WHERE `id`=? LIMIT 1;',
            { inventory })[1]
        local currentWeightRow = MySQL.query.await([[
            SELECT COALESCE(SUM(i.`weight`), 0) AS `weight`
            FROM `inventory_items` ii INNER JOIN `items` i ON i.`id`=ii.`item_id`
            WHERE ii.`inventory_id`=?;
        ]], { inventory })[1]
        local itemWeight = tonumber(definition.weight) or 0
        if itemWeight <= 0 then
            report('tx add rejected by weight', false, 'consumable_apple has no positive weight')
        else
            local currentWeight = tonumber(currentWeightRow and currentWeightRow.weight) or 0
            local testLimit = math.max(0.01, currentWeight + (itemWeight / 2))
            MySQL.query.await(
                'UPDATE `inventory` SET `max_weight`=?, `ignore_item_limit`=1 WHERE `id`=?;',
                { testLimit, inventory })
            expectRejection('tx add rejected by weight', 'weight_limit', {
                inventory = inventory, definitionId = definition.id, quantity = 1
            })
            MySQL.query.await(
                'UPDATE `inventory` SET `max_weight`=?, `ignore_item_limit`=? WHERE `id`=?;',
                { restoredWeight and restoredWeight.max_weight or nil,
                  restoredWeight and restoredWeight.ignore_item_limit or 0, inventory })
        end

        -- 8. Maximum quantity. Exceeds the definition's own max_quantity
        --    while staying under any weight limit.
        local maxQuantity = tonumber(definition.max_quantity) or 0
        expectRejection('tx add rejected by max quantity', 'item_limit', {
            inventory = inventory, definitionId = definition.id, quantity = maxQuantity + 1
        })

        -- 9. Blacklist. Restrict the definition for this inventory, attempt a
        --    single unit, then restore whatever was restricted before.
        local restoredBlacklist = MySQL.query.await(
            'SELECT `item_id` FROM `inventory_blacklist` WHERE `inventory_id`=?;', { inventory })
        MySQL.query.await('INSERT IGNORE INTO `inventory_blacklist` (`inventory_id`, `item_id`) VALUES (?, ?);',
            { inventory, definition.id })
        expectRejection('tx add rejected by blacklist', 'item_restricted', {
            inventory = inventory, definitionId = definition.id, quantity = 1
        })
        MySQL.query.await('DELETE FROM `inventory_blacklist` WHERE `inventory_id`=? AND `item_id`=?;',
            { inventory, definition.id })
        for _, row in pairs(restoredBlacklist or {}) do
            MySQL.query.await('INSERT IGNORE INTO `inventory_blacklist` (`inventory_id`, `item_id`) VALUES (?, ?);',
                { inventory, row.item_id })
        end

        -- 10. Slot capacity. Temporarily shrink the book to zero compartments
        --     so nothing can be placed, whatever its weight or quantity.
        local restoredSlots = MySQL.query.await(
            'SELECT `max_slots`, `ignore_item_limit` FROM `inventory` WHERE `id`=? LIMIT 1;',
            { inventory })[1]
        if not uniqueRow then
            report('tx add rejected by slot capacity', false, 'no unique definition seeded; cannot test')
        else
            local restoredUniqueBlacklist = MySQL.query.await(
                'SELECT `item_id` FROM `inventory_blacklist` WHERE `inventory_id`=? AND `item_id`=? LIMIT 1;',
                { inventory, uniqueRow.id })[1]
            MySQL.query.await(
                'DELETE FROM `inventory_blacklist` WHERE `inventory_id`=? AND `item_id`=?;',
                { inventory, uniqueRow.id })
            MySQL.query.await(
                'UPDATE `inventory` SET `max_slots`=0, `ignore_item_limit`=1 WHERE `id`=?;',
                { inventory })
            expectRejection('tx add rejected by slot capacity', 'inventory_full', {
                inventory = inventory, definitionId = tonumber(uniqueRow.id), quantity = 1
            })
            MySQL.query.await(
                'UPDATE `inventory` SET `max_slots`=?, `ignore_item_limit`=? WHERE `id`=?;',
                { restoredSlots and restoredSlots.max_slots or nil,
                  restoredSlots and restoredSlots.ignore_item_limit or 0, inventory })
            if restoredUniqueBlacklist then
                MySQL.query.await(
                    'INSERT IGNORE INTO `inventory_blacklist` (`inventory_id`, `item_id`) VALUES (?, ?);',
                    { inventory, uniqueRow.id })
            end
        end

        ------------------------------------------------------------------
        -- Unique-instance issuance
        ------------------------------------------------------------------

        -- 11. GrantItem must refuse a unique definition outright.
        if not uniqueRow then
            report('unique GrantItem rejected', false, 'no unique definition seeded; cannot test')
        else
            local refused = ItemsAPI.GrantItem(uniqueRow.name, 1, inventory)
            report('unique GrantItem rejected',
                not Result.IsOk(refused) and refused.error.code == 'unique_requires_issuer',
                refused.error and refused.error.code)

            -- 12. CreateInstance succeeds with metadata once every gate is met.
            local issued = TransactionAPI.CreateInstance(
                { reason = 'smoketest_issue', correlationId = 'smoketest' },
                { characterId = character.id, definitionId = tonumber(uniqueRow.id),
                  metadata = { smoketest = true, serial = 'SMOKE-1' } })
            report('CreateInstance issues unique with metadata', Result.IsOk(issued),
                Result.IsOk(issued) and ('instance=' .. tostring(issued.value.instanceId))
                    or (issued.error and issued.error.message))

            if Result.IsOk(issued) then
                local stored = InstancesAPI.GetInstance(issued.value.instanceId)
                report('issued instance carries its document',
                    Result.IsOk(stored) and stored.value.metadata.serial == 'SMOKE-1',
                    Result.IsOk(stored) and tostring(stored.value.metadata.serial) or 'unreadable')
                -- DevMode fixture cleanup; production deletion uses Tx:RemoveInstances.
                MySQL.query.await('DELETE FROM `inventory_items` WHERE `id`=?;', { issued.value.instanceId })
            end

            -- 13. CreateInstance must roll back when a gate fails. Zero
            --     compartments, so placement cannot succeed -- and nothing may
            --     be left behind by the attempt.
            local beforeIssue = InventoryControllers.InventoryItemCount(inventory, tonumber(uniqueRow.id))
            MySQL.query.await('UPDATE `inventory` SET `max_slots`=0 WHERE `id`=?;', { inventory })
            local blocked = TransactionAPI.CreateInstance(
                { reason = 'smoketest_issue_blocked' },
                { characterId = character.id, definitionId = tonumber(uniqueRow.id),
                  metadata = { smoketest = true } })
            MySQL.query.await('UPDATE `inventory` SET `max_slots`=? WHERE `id`=?;',
                { restoredSlots and restoredSlots.max_slots or nil, inventory })
            local afterIssue = InventoryControllers.InventoryItemCount(inventory, tonumber(uniqueRow.id))
            report('CreateInstance rolls back on a failed gate',
                not Result.IsOk(blocked) and beforeIssue == afterIssue,
                ('before=%s after=%s code=%s'):format(beforeIssue, afterIssue,
                    blocked.error and blocked.error.code or 'committed'))
        end

        -- Clean up everything this test created.
        local cleanup = InventoryAPI.Transaction({ reason = 'smoketest_cleanup' }, function(tx)
            return tx:RemoveInstances(inventory, definition.id, { created, mover })
        end)
        report('exact instance removal', Result.IsOk(cleanup),
            Result.IsOk(cleanup) and 'removed=2' or (cleanup.error and cleanup.error.message))
        print('[InvTxSmokeTest] done')
    end, true)

    -- Trusted disposable lifecycle/API harness. Definition fixture setup and
    -- assertions use SQL because catalog creation is intentionally not a
    -- public Inventory mutation. Owned-instance mutations themselves go
    -- through the supported transactional API. The fixed fixture names make
    -- an interrupted run safe to clean up and rerun without touching real
    -- catalog definitions.
    RegisterCommand('InvLifecycleSmokeTest', function(source)
        if LifecycleSmokeRunning then
            print('[InvLifecycleSmokeTest] already running')
            return
        end
        LifecycleSmokeRunning = true

        local function report(label, ok, detail)
            print(('[InvLifecycleSmokeTest] %-45s %s%s'):format(
                label, ok and 'PASS' or 'FAIL', detail and ('  -- ' .. detail) or ''))
        end

        local player = InventoryIdentity.GetCharacter(source)
        local character = player and player.char
        local inventoryId = character and InventoryControllers.GetInventoryByCharacter(character.id)
        local seed = ItemControllers.GetItemDefinitionByName('consumable_apple')
        if not inventoryId or not seed then
            print('[InvLifecycleSmokeTest] connected character inventory or consumable_apple is unavailable')
            LifecycleSmokeRunning = false
            return
        end

        local names = {
            source = 'inv_smoke_migrate_source',
            target = 'inv_smoke_migrate_target',
            incompatible = 'inv_smoke_migrate_incompatible',
        }
        local function cleanupDefinitions()
            MySQL.query.await('DELETE FROM `items` WHERE `name` IN (?, ?, ?);',
                { names.source, names.target, names.incompatible })
        end
        cleanupDefinitions()

        local inserted = MySQL.query.await([[
            INSERT INTO `items`
                (`name`, `display_name`, `description`, `max_quantity`, `max_stack_size`,
                 `weight`, `usable`, `category_id`, `type`, `instance_mode`)
            SELECT ?, ?, 'Disposable inventory lifecycle fixture', `max_quantity`,
                   `max_stack_size`, `weight`, 0, `category_id`, `type`, `instance_mode`
            FROM `items` WHERE `id`=?;
        ]], { names.source, 'Inventory Smoke Source', seed.id })
        MySQL.query.await([[
            INSERT INTO `items`
                (`name`, `display_name`, `description`, `max_quantity`, `max_stack_size`,
                 `weight`, `usable`, `category_id`, `type`, `instance_mode`)
            SELECT ?, ?, 'Disposable inventory lifecycle fixture', `max_quantity`,
                   `max_stack_size`, `weight`, 0, `category_id`, `type`, `instance_mode`
            FROM `items` WHERE `id`=?;
        ]], { names.target, 'Inventory Smoke Target', seed.id })
        MySQL.query.await([[
            INSERT INTO `items`
                (`name`, `display_name`, `description`, `max_quantity`, `max_stack_size`,
                 `weight`, `usable`, `category_id`, `type`, `instance_mode`)
            SELECT ?, ?, 'Disposable incompatible lifecycle fixture', `max_quantity`,
                   `max_stack_size`, `weight` + 1.00, 0, `category_id`, `type`, `instance_mode`
            FROM `items` WHERE `id`=?;
        ]], { names.incompatible, 'Inventory Smoke Incompatible', seed.id })

        local rows = MySQL.query.await(
            'SELECT `id`, `name` FROM `items` WHERE `name` IN (?, ?, ?);',
            { names.source, names.target, names.incompatible }) or {}
        local definitions = {}
        for _, row in ipairs(rows) do definitions[row.name] = tonumber(row.id) end
        local sourceId, targetId, incompatibleId = definitions[names.source],
            definitions[names.target], definitions[names.incompatible]
        if not inserted or not sourceId or not targetId or not incompatibleId then
            report('fixture definitions created', false, 'definition insert failed')
            cleanupDefinitions()
            LifecycleSmokeRunning = false
            return
        end
        report('fixture definitions created', true)

        local createdIds = {}
        local created = InventoryAPI.Transaction({
            actorSource = source,
            actorCharacterId = character.id,
            reason = 'lifecycle_smoke_seed',
            resource = GetCurrentResourceName(),
        }, function(tx)
            local added = tx:AddQuantity(inventoryId, sourceId, 3,
                { fixture = 'lifecycle', batch = 'same-document' })
            if not Result.IsOk(added) then return added end
            createdIds = added.value
            return added
        end)
        report('three owned fixture instances created', Result.IsOk(created) and #createdIds == 3,
            Result.IsOk(created) and ('instances=' .. #createdIds)
                or (created.error and created.error.message))

        local before = MySQL.query.await([[
            SELECT `id`, `inventory_id`, `slot_index`, `metadata`, `row_revision`
            FROM `inventory_items` WHERE `item_id`=? ORDER BY `id`;
        ]], { sourceId }) or {}

        local preflight = InstancesAPI.GetDefinitionMigrationPreflight(sourceId, targetId)
        report('compatible preflight returns advisory counts',
            Result.IsOk(preflight)
                and preflight.value.advisory == true
                and preflight.value.storageSemanticsCompatible == true
                and preflight.value.ownedInstances == #before
                and preflight.value.affectedInventories == 1,
            Result.IsOk(preflight) and json.encode(preflight.value)
                or (preflight.error and preflight.error.message))

        local incompatiblePreflight = InstancesAPI.GetDefinitionMigrationPreflight(sourceId, incompatibleId)
        report('incompatible preflight identifies conflict',
            Result.IsOk(incompatiblePreflight)
                and incompatiblePreflight.value.storageSemanticsCompatible == false)
        local incompatible = InstancesAPI.MigrateDefinitionInstances(
            sourceId, incompatibleId, 'lifecycle smoke incompatible')
        local afterRejected = MySQL.query.await(
            'SELECT COUNT(*) AS `count` FROM `inventory_items` WHERE `item_id`=?;', { sourceId })[1]
        report('incompatible migration rolls back unchanged',
            not Result.IsOk(incompatible)
                and incompatible.error.code == Result.Codes.CONFLICT
                and tonumber(afterRejected and afterRejected.count) == #before,
            incompatible.error and incompatible.error.code)

        local migrationReason = 'lifecycle smoke compatible migration'
        LifecycleSmokeEvents = {
            correlationId = 'inv-lifecycle-destroy-' .. tostring(os.time()),
            migrationReason = migrationReason,
            destroyed = {},
            migrated = {},
        }
        local migrated = InstancesAPI.MigrateDefinitionInstances(sourceId, targetId, migrationReason)
        local after = MySQL.query.await([[
            SELECT `id`, `inventory_id`, `slot_index`, `metadata`, `row_revision`
            FROM `inventory_items` WHERE `item_id`=? ORDER BY `id`;
        ]], { targetId }) or {}
        local preserved = Result.IsOk(migrated) and #before == #after
        for index, original in ipairs(before) do
            local replacement = after[index]
            preserved = preserved and replacement
                and tonumber(replacement.id) == tonumber(original.id)
                and tonumber(replacement.inventory_id) == tonumber(original.inventory_id)
                and tonumber(replacement.slot_index) == tonumber(original.slot_index)
                and tostring(replacement.metadata) == tostring(original.metadata)
                and tonumber(replacement.row_revision) == tonumber(original.row_revision) + 1
        end
        local archived = MySQL.query.await(
            'SELECT `archived_at`, `archive_reason` FROM `items` WHERE `id`=?;', { sourceId })[1]
        report('compatible migration preserves identity and bumps revision', preserved)
        report('compatible migration archives source', archived and archived.archived_at ~= nil
            and archived.archive_reason == migrationReason)
        report('DefinitionMigrated emitted once after commit',
            #LifecycleSmokeEvents.migrated == 1
                and LifecycleSmokeEvents.migrated[1].quantity == #before)

        local wrongLocation = TransactionAPI.DestroyInstances({
            actorSource = source,
            actorCharacterId = character.id,
            reason = 'lifecycle smoke wrong domain',
            resource = GetCurrentResourceName(),
            correlationId = LifecycleSmokeEvents.correlationId,
        }, {
            inventoryId = inventoryId,
            expectedLocation = '__wrong_fixture_domain__',
            instanceIds = createdIds,
        })
        local countAfterWrong = MySQL.query.await(
            'SELECT COUNT(*) AS `count` FROM `inventory_items` WHERE `item_id`=?;', { targetId })[1]
        report('destruction rejects wrong owner domain without writes',
            not Result.IsOk(wrongLocation) and wrongLocation.error.code == Result.Codes.DENIED
                and tonumber(countAfterWrong and countAfterWrong.count) == #createdIds)

        local staleIds = {}
        for _, id in ipairs(createdIds) do staleIds[#staleIds + 1] = id end
        local maxInstance = MySQL.query.await(
            'SELECT COALESCE(MAX(`id`), 0) AS `id` FROM `inventory_items`;')[1]
        staleIds[#staleIds + 1] = (tonumber(maxInstance and maxInstance.id) or 0) + 1
        local stale = TransactionAPI.DestroyInstances({
            actorSource = source,
            actorCharacterId = character.id,
            reason = 'lifecycle smoke stale set',
            resource = GetCurrentResourceName(),
            correlationId = LifecycleSmokeEvents.correlationId,
        }, {
            inventoryId = inventoryId,
            expectedLocation = 'character',
            instanceIds = staleIds,
        })
        local countAfterStale = MySQL.query.await(
            'SELECT COUNT(*) AS `count` FROM `inventory_items` WHERE `item_id`=?;', { targetId })[1]
        report('stale destruction set rolls back every removal',
            not Result.IsOk(stale)
                and tonumber(countAfterStale and countAfterStale.count) == #createdIds,
            stale.error and stale.error.code)

        local destroyed = TransactionAPI.DestroyInstances({
            actorSource = source,
            actorCharacterId = character.id,
            reason = 'lifecycle smoke approved destruction',
            resource = GetCurrentResourceName(),
            correlationId = LifecycleSmokeEvents.correlationId,
        }, {
            inventoryId = inventoryId,
            expectedLocation = 'character',
            instanceIds = createdIds,
        })
        report('exact destruction commits all selected instances',
            Result.IsOk(destroyed) and destroyed.value.quantity == #createdIds)
        local factsValid = #LifecycleSmokeEvents.destroyed == #createdIds
        for _, fact in ipairs(LifecycleSmokeEvents.destroyed) do
            factsValid = factsValid
                and fact.outcome == 'committed'
                and fact.reason == 'lifecycle smoke approved destruction'
                and fact.resource == GetCurrentResourceName()
                and tonumber(fact.inventoryId) == inventoryId
        end
        report('ItemDestroyed emitted once per instance with context', factsValid,
            ('events=%s expected=%s'):format(#LifecycleSmokeEvents.destroyed, #createdIds))

        LifecycleSmokeEvents = nil
        cleanupDefinitions()
        LifecycleSmokeRunning = false
        print('[InvLifecycleSmokeTest] done')
    end, true)

    RegisterCommand('InvConcurrencySmokeTest', function(source)
        local function report(label, ok, detail)
            print(('[InvConcurrencySmokeTest] %-48s %s%s'):format(
                label, ok and 'PASS' or 'FAIL', detail and ('  -- ' .. detail) or ''))
        end

        local player = InventoryIdentity.GetCharacter(source)
        local character = player and player.char
        local characterInventory = character
            and InventoryControllers.GetInventoryByCharacter(character.id)
        local stackSeed = ItemControllers.GetItemDefinitionByName('consumable_apple')
        local uniqueSeed = MySQL.query.await(
            "SELECT `id` FROM `items` WHERE `instance_mode`='unique' AND `archived_at` IS NULL LIMIT 1;")[1]
        if not characterInventory or not stackSeed or not uniqueSeed then
            print('[InvConcurrencySmokeTest] loaded Character, apple, and active unique definition are required')
            return
        end

        local definitionName = 'inv_smoke_archive_race'
        local targetUuid = '00000000-0000-4000-8000-000000000091'
        MySQL.query.await('DELETE FROM `items` WHERE `name`=?;', { definitionName })
        MySQL.query.await('DELETE FROM `inventory` WHERE `uuid`=?;', { targetUuid })
        MySQL.query.await([[
            INSERT INTO `items`
                (`name`, `display_name`, `description`, `max_quantity`, `max_stack_size`,
                 `weight`, `usable`, `category_id`, `type`, `instance_mode`)
            SELECT ?, 'Inventory Archive Race', 'Disposable concurrency fixture',
                   `max_quantity`, `max_stack_size`, `weight`, 0, `category_id`, `type`, `instance_mode`
            FROM `items` WHERE `id`=?;
        ]], { definitionName, stackSeed.id })
        local raceDefinition = MySQL.query.await(
            'SELECT `id` FROM `items` WHERE `name`=?;', { definitionName })[1]
        if not raceDefinition then
            report('archive fixture created', false)
            return
        end
        raceDefinition.id = tonumber(raceDefinition.id)

        local ready, done, go = 0, 0, false
        local archiveResult, grantResult
        CreateThread(function()
            ready = ready + 1
            while not go do Wait(0) end
            archiveResult = InstancesAPI.SetDefinitionArchived(
                raceDefinition.id, true, 'concurrency smoke archive')
            done = done + 1
        end)
        CreateThread(function()
            ready = ready + 1
            while not go do Wait(0) end
            grantResult = InventoryAPI.Transaction({
                actorSource = source,
                actorCharacterId = character.id,
                reason = 'concurrency smoke grant',
                resource = GetCurrentResourceName(),
            }, function(tx)
                return tx:AddQuantity(characterInventory, raceDefinition.id, 1,
                    { fixture = 'archive-race' })
            end)
            done = done + 1
        end)
        while ready < 2 do Wait(0) end
        go = true
        local deadline = GetGameTimer() + 15000
        while done < 2 and GetGameTimer() < deadline do Wait(0) end

        local archivedRow = MySQL.query.await(
            'SELECT `archived_at` FROM `items` WHERE `id`=?;', { raceDefinition.id })[1]
        local ownedAfterArchive = MySQL.query.await(
            'SELECT COUNT(*) AS `count` FROM `inventory_items` WHERE `item_id`=?;',
            { raceDefinition.id })[1]
        local grantCode = grantResult and not Result.IsOk(grantResult)
            and grantResult.error.code or nil
        local serialArchive = done == 2 and Result.IsOk(archiveResult)
            and archivedRow and archivedRow.archived_at ~= nil
            and (Result.IsOk(grantResult)
                or grantCode == Result.Codes.DENIED)
            and tonumber(ownedAfterArchive and ownedAfterArchive.count) <= 1
        report('archive and grant produce only a valid serial result', serialArchive,
            ('grant=%s instances=%s'):format(
                Result.IsOk(grantResult) and 'committed' or tostring(grantCode),
                tostring(ownedAfterArchive and ownedAfterArchive.count)))

        MySQL.query.await([[
            INSERT INTO `inventory`
                (`uuid`, `name`, `max_weight`, `location`, `ignore_item_limit`,
                 `is_public`, `max_slots`)
            VALUES (?, 'Inventory Equipment Race Target', 9999, 'concurrency_fixture', 1, 0, 64);
        ]], { targetUuid })
        local targetInventory = MySQL.query.await(
            'SELECT `id` FROM `inventory` WHERE `uuid`=?;', { targetUuid })[1]
        targetInventory = targetInventory and tonumber(targetInventory.id)

        local instanceId
        local seeded = InventoryAPI.Transaction({
            actorSource = source,
            actorCharacterId = character.id,
            reason = 'concurrency smoke equipment seed',
            resource = GetCurrentResourceName(),
        }, function(tx)
            local added = tx:AddQuantity(characterInventory, tonumber(uniqueSeed.id), 1,
                { fixture = 'equipment-race' })
            if not Result.IsOk(added) then return added end
            instanceId = added.value[1]
            return added
        end)

        ready, done, go = 0, 0, false
        local equipResult, moveResult
        if Result.IsOk(seeded) and instanceId and targetInventory then
            CreateThread(function()
                ready = ready + 1
                while not go do Wait(0) end
                equipResult = EquipmentAPI.SetEquippedForCharacter(
                    character.id, 'inventory_concurrency_smoke', instanceId)
                done = done + 1
            end)
            CreateThread(function()
                ready = ready + 1
                while not go do Wait(0) end
                moveResult = InventoryAPI.Transaction({
                    actorSource = source,
                    actorCharacterId = character.id,
                    reason = 'concurrency smoke move',
                    resource = GetCurrentResourceName(),
                }, function(tx)
                    return tx:MoveInstance(instanceId, targetInventory, 1)
                end)
                done = done + 1
            end)
            while ready < 2 do Wait(0) end
            go = true
            deadline = GetGameTimer() + 15000
            while done < 2 and GetGameTimer() < deadline do Wait(0) end
        end

        local finalItem = instanceId and MySQL.query.await([[
            SELECT ii.`inventory_id`, inv.`character_id`, inv.`location`
            FROM `inventory_items` ii INNER JOIN `inventory` inv ON inv.`id`=ii.`inventory_id`
            WHERE ii.`id`=?;
        ]], { instanceId })[1]
        local equipment = instanceId and MySQL.query.await(
            'SELECT `character_id` FROM `character_equipment` WHERE `inventory_items_id`=?;',
            { instanceId })[1]
        local movedAwayCleanly = Result.IsOk(moveResult)
            and finalItem and tonumber(finalItem.inventory_id) == targetInventory
            and equipment == nil
        local equipWonAndMoveWasDenied = not Result.IsOk(moveResult)
            and Result.IsOk(equipResult)
            and finalItem and tostring(finalItem.character_id) == tostring(character.id)
            and equipment and tostring(equipment.character_id) == tostring(character.id)
        local noMismatch = done == 2
            and (movedAwayCleanly or equipWonAndMoveWasDenied)
        report('equipment assignment and move cannot leave mismatch', noMismatch,
            ('equip=%s move=%s equippedRow=%s'):format(
                Result.IsOk(equipResult) and 'committed'
                    or tostring(equipResult and equipResult.error.code),
                Result.IsOk(moveResult) and 'committed'
                    or tostring(moveResult and moveResult.error.code),
                tostring(equipment ~= nil)))

        if instanceId and finalItem then
            EquipmentAPI.ClearEquippedInstance(instanceId)
            TransactionAPI.DestroyInstances({
                actorSource = source,
                actorCharacterId = character.id,
                reason = 'concurrency smoke cleanup',
                resource = GetCurrentResourceName(),
            }, {
                inventoryId = tonumber(finalItem.inventory_id),
                expectedLocation = tostring(finalItem.location),
                instanceIds = { instanceId },
            })
        end
        MySQL.query.await('DELETE FROM `items` WHERE `name`=?;', { definitionName })
        MySQL.query.await('DELETE FROM `inventory` WHERE `uuid`=?;', { targetUuid })
        print('[InvConcurrencySmokeTest] done')
    end, true)

    RegisterCommand('CreateStorageKey', function(source, args)
        InventoryAPI.RegisterForeignKey('storage', 'BIGINT UNSIGNED', 'id')
    end, true)

    RegisterCommand('CreateStorage', function(source, args)
        -- (INV-11) Dev/test-only storage; marked public since this ACE-gated
        -- debug tool has no owner-assignment flow of its own.
        InventoryAPI.RegisterInventory('storage', 1, 'Big Box', nil, nil, nil, nil, true)
    end, true)

    RegisterCommand('AddStorageItems', function(source, args)
        local result = ItemsAPI.AddItem(args[1], tonumber(args[2]), args[3] or nil,
            'dde04bd6-34cc-11ef-a92d-107c61489014')

        if not Result.IsOk(result) then
            Feather.Notify.RightNotify(source, TranslateResult(source, result, 'err_move_failed'), 3000)
        else
            Feather.Notify.RightNotify(source, Translate(source, 'msg_item_added', 'Item added.'), 3000)
        end
    end, true)

    RegisterCommand('InvIntegrityCheck', function(source, args)
        local result = DiagnosticsAPI.RunIntegrityDiagnostics({ sampleLimit = tonumber(args[1]) or 25 })
        if not Result.IsOk(result) then
            print(('[InvIntegrityCheck] failed: %s'):format(
                result.error and result.error.message or 'unknown error'))
            return
        end
        local report = result.value
        print(('[InvIntegrityCheck] dry-run complete: %d finding(s) across %d sampled row(s)')
            :format(report.summary.totalFindings, #report.findings))
        print(json.encode({
            generatedAt = report.generatedAt,
            ok = report.ok,
            byCode = report.summary.byCode,
            bySeverity = report.summary.bySeverity,
            truncatedByCode = report.truncatedByCode,
            findings = report.findings,
        }))
    end, true)
end
