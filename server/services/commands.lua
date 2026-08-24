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
