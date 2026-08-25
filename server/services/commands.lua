-- (INV-05) Gated on Config.DevMode (default false) AND registered as
-- ACE-restricted ("true" below, was "false") -- so a server that flips
-- DevMode back on for testing doesn't hand free-item commands to every
-- player, only to principals explicitly granted `command.<name>`.
if Config.DevMode then
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
        local player = Feather.Character.GetCharacter({ src = source })
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
        InventoryControllers.DeleteInventoryItem(ghost)
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
                InventoryControllers.DeleteInventoryItem(issued.value.instanceId)
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
end
