-- Console-only committed-receipt gate; all data lives in dedicated test tables.
-- Reuses production Apply; only its inventory/SQL adapter is a fixture.
local fixtureId = '00000000-0000-4000-8000-000000000001'
local prefix = '[InvCharacterAmmoReplaySmokeTest] '
local function FixtureTx(real)
    local fixture = {}
    function fixture.query(sql, params)
        if sql == 'SELECT id FROM inventory WHERE character_id = ? LIMIT 1 FOR UPDATE' then
            return real.query('SELECT id FROM fi_ammo_smoke_balance WHERE character_id = ? FOR UPDATE', params)
        end
        if sql == 'SELECT id, type, instance_mode, archived_at FROM items WHERE name = ? LIMIT 1' then
            assert(params[1] == 'ammo_repeater_regular', 'Only fixture ammunition is supported')
            return { { id = 1, type = 'item_ammo', instance_mode = 'stack' } }
        end
        local mapped
        if sql:match('^SELECT revision, pools FROM feather_character_ammunition ') then
            mapped = sql:gsub('feather_character_ammunition', 'fi_ammo_smoke_ledger')
        elseif sql:match('^UPDATE feather_character_ammunition ') then
            mapped = sql:gsub('feather_character_ammunition', 'fi_ammo_smoke_ledger')
        elseif sql:match('^SELECT result FROM feather_ammunition_operations ')
            or sql:match('^INSERT INTO feather_ammunition_operations ') then
            mapped = sql:gsub('feather_ammunition_operations', 'fi_ammo_smoke_receipts')
        end
        assert(mapped and mapped:find('fi_ammo_smoke_', 1, true), 'Unexpected production SQL in fixture')
        -- No operation may escape to a real character ledger or inventory table.
        assert(not mapped:find('feather_character_ammunition', 1, true)
            and not mapped:find('feather_ammunition_operations', 1, true), 'Unmapped SQL')
        return real.query(mapped, params)
    end
    function fixture:RequireAccess() return nil end -- no player inventory exists here
    function fixture:RemoveQuantity(inventoryId, definitionId, amount)
        assert(inventoryId == 1 and definitionId == 1)
        local changed = real.query('UPDATE fi_ammo_smoke_balance SET quantity = quantity - ? WHERE character_id = ? AND quantity >= ?',
            { amount, fixtureId, amount })
        return changed and tonumber(changed.affectedRows) == 1 and Result.Ok({})
            or Result.Err(Result.Codes.LIMIT_EXCEEDED, 'Fixture balance insufficient.')
    end
    function fixture:AddQuantity(inventoryId, definitionId, amount)
        assert(inventoryId == 1 and definitionId == 1)
        local changed = real.query('UPDATE fi_ammo_smoke_balance SET quantity = quantity + ? WHERE character_id = ?',
            { amount, fixtureId })
        return changed and tonumber(changed.affectedRows) == 1 and Result.Ok({})
            or Result.Err(Result.Codes.CONFLICT, 'Fixture balance missing.')
    end
    return fixture
end
local function schema()
    DB.exec([[CREATE TABLE IF NOT EXISTS fi_ammo_smoke_balance (
        character_id CHAR(36) NOT NULL PRIMARY KEY, id INT NOT NULL, quantity INT UNSIGNED NOT NULL) ENGINE=InnoDB]])
    DB.exec([[CREATE TABLE IF NOT EXISTS fi_ammo_smoke_ledger (
        character_id CHAR(36) NOT NULL PRIMARY KEY, revision BIGINT UNSIGNED NOT NULL, pools LONGTEXT NOT NULL) ENGINE=InnoDB]])
    DB.exec([[CREATE TABLE IF NOT EXISTS fi_ammo_smoke_receipts (
        character_id CHAR(36) NOT NULL, operation_id VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        result LONGTEXT NOT NULL, PRIMARY KEY(character_id, operation_id)) ENGINE=InnoDB]])
end
local function request(operation, amount, revision)
    return { operationId = operation, ammunitionId = 'ammo_repeater_regular', amount = amount,
        expectedRevision = revision, limits = { ammo_repeater_regular = 200 } }
end
local function transact(spec, holdLock, forceRollback)
    return TransactionAPI.Transaction({ reason = 'ammo_receipt_fixture', resource = 'feather-inventory' }, function(tx)
        local fixture = FixtureTx(tx)
        if holdLock then
            local query, held = fixture.query, false
            fixture.query = function(sql, params)
                local value = query(sql, params)
                if not held and sql == 'SELECT id FROM inventory WHERE character_id = ? LIMIT 1 FOR UPDATE' then
                    held = true
                    Wait(100) -- test-only: hold the fixture row so another connection contends
                end
                return value
            end
        end
        local result = CharacterAmmunitionAPI.Apply(fixture, { characterId = fixtureId }, spec)
        if result.ok and forceRollback then
            return Result.Err(Result.Codes.DENIED, 'intentional_concurrent_fixture_rollback')
        end
        return result
    end)
end
local function pair(specifications)
    local results, completed, start = {}, 0, false
    for index = 1, 2 do
        CreateThread(function()
            while not start do Wait(0) end
            local ok, result = pcall(transact, specifications[index], true)
            results[index] = ok and result or Result.Err(Result.Codes.INTERNAL, tostring(result))
            completed = completed + 1
        end)
    end
    start = true
    local deadline = GetGameTimer() + 30000
    while completed < 2 and GetGameTimer() < deadline do Wait(10) end
    if completed < 2 then return nil end
    return results
end
local function snapshot()
    local balance = DB.one('SELECT quantity FROM fi_ammo_smoke_balance WHERE character_id = ?', fixtureId)
    local ledger = DB.one('SELECT revision, pools FROM fi_ammo_smoke_ledger WHERE character_id = ?', fixtureId)
    local count = DB.value('SELECT COUNT(*) FROM fi_ammo_smoke_receipts WHERE character_id = ?', fixtureId)
    if not balance or not ledger then return nil end
    local ok, pools = pcall(json.decode, ledger.pools)
    if not ok or type(pools) ~= 'table' then return nil end
    return { quantity = tonumber(balance.quantity), revision = tonumber(ledger.revision),
        carried = pools.ammo_repeater_regular, receipts = tonumber(count) }
end
local function expected(value)
    return value and value.quantity == 7 and value.carried == 5
        and value.revision == 1 and value.receipts == 1
end
RegisterCommand('InvCharacterAmmoReplaySmokeTest', function(source, args)
    if source ~= 0 or not Config.DevMode then return end
    local mode = args and args[1]
    if mode ~= 'prepare' and mode ~= 'verify' and mode ~= 'cleanup' and mode ~= 'concurrent' then
        print(prefix .. 'usage: InvCharacterAmmoReplaySmokeTest prepare|verify|concurrent|cleanup'); return
    end
    if GetResourceState('feather-weapons') == 'started' then
        print(prefix .. 'BLOCKED: keep production Weapons stopped'); return
    end
    schema()
    if mode == 'prepare' then
        local result = TransactionAPI.Transaction({ reason = 'ammo_fixture_prepare' }, function(tx)
            if #tx.query('SELECT id FROM fi_ammo_smoke_balance WHERE character_id = ? FOR UPDATE', { fixtureId }) > 0 then
                return Result.Err(Result.Codes.CONFLICT, 'Fixture already exists; verify or cleanup, never reset silently.')
            end
            tx.query('INSERT INTO fi_ammo_smoke_balance (character_id, id, quantity) VALUES (?, 1, 10)', { fixtureId })
            tx.query('INSERT INTO fi_ammo_smoke_ledger (character_id, revision, pools) VALUES (?, 0, ?)',
                { fixtureId, json.encode({ ammo_repeater_regular = 2 }) })
            return CharacterAmmunitionAPI.Apply(FixtureTx(tx), { characterId = fixtureId }, request('committed-load', 3, 0))
        end)
        print(prefix .. 'prepare ' .. (result.ok and expected(snapshot()) and 'PASS' or 'FAIL'))
        if not result.ok then print(prefix .. json.encode(result)) end
        print(prefix .. 'fixture only: loose=7 carried=5 revision=1 receipts=1 expected; restart Inventory, then verify')
    elseif mode == 'verify' then
        if not expected(snapshot()) then print(prefix .. 'FAIL missing/unexpected committed fixture; do not prepare again'); return end
        local replay = transact(request('committed-load', 3, 0))
        local conflict = transact(request('committed-load', 4, 0))
        local stale = transact(request('new-stale-request', 1, 0))
        local checks = {
            committedState = expected(snapshot()),
            receiptReplay = replay.ok == true and replay.value.revision == 1 and replay.value.inventoryDelta == -3,
            changedInputRejected = conflict.ok == false and conflict.error.code == Result.Codes.CONFLICT,
            staleRevisionRejected = stale.ok == false and stale.error.code == Result.Codes.CONFLICT,
            conserved = expected(snapshot())
        }
        local passed = 0
        for _, name in ipairs({ 'committedState', 'receiptReplay', 'changedInputRejected', 'staleRevisionRejected', 'conserved' }) do
            if checks[name] then passed = passed + 1 end
            print(prefix .. name .. ' ' .. (checks[name] and 'PASS' or 'FAIL'))
        end
        print(prefix .. ('done %d/5; dedicated fixture only, no real inventory/native changes'):format(passed))
    elseif mode == 'concurrent' then
        local initialized = TransactionAPI.Transaction({ reason = 'ammo_concurrent_fixture_prepare' }, function(tx)
            if #tx.query('SELECT id FROM fi_ammo_smoke_balance WHERE character_id = ? FOR UPDATE', { fixtureId }) > 0 then
                return Result.Err(Result.Codes.CONFLICT, 'Fixture exists; cleanup previous completed test first.')
            end
            tx.query('INSERT INTO fi_ammo_smoke_balance (character_id, id, quantity) VALUES (?, 1, 10)', { fixtureId })
            tx.query('INSERT INTO fi_ammo_smoke_ledger (character_id, revision, pools) VALUES (?, 0, ?)',
                { fixtureId, json.encode({ ammo_repeater_regular = 2 }) })
            return Result.Ok(true)
        end)
        if not initialized.ok then print(prefix .. 'concurrent BLOCKED ' .. json.encode(initialized)); return end
        local duplicated = pair({ request('concurrent-duplicate', 3, 0), request('concurrent-duplicate', 3, 0) })
        if not duplicated then print(prefix .. 'TIMEOUT: preserve fixture, do not cleanup/retry until workers settle'); return end
        local checks = {
            duplicateAccepted = duplicated[1].ok == true and duplicated[2].ok == true,
            duplicateSpentOnce = expected(snapshot())
        }
        if not checks.duplicateAccepted or not checks.duplicateSpentOnce then
            print(prefix .. 'concurrent duplicate FAIL ' .. json.encode(duplicated)); return
        end
        local competing = pair({ request('concurrent-left', 1, 1), request('concurrent-right', 1, 1) })
        if not competing then print(prefix .. 'TIMEOUT: preserve fixture, do not cleanup/retry until workers settle'); return end
        local winners, conflicts = 0, 0
        for _, result in ipairs(competing) do
            if result.ok then winners = winners + 1
            elseif result.error and result.error.code == Result.Codes.CONFLICT then conflicts = conflicts + 1 end
        end
        checks.oneRevisionWinner = winners == 1 and conflicts == 1
        local function finalCounts()
            local value = snapshot()
            return value and value.quantity == 6 and value.carried == 6
                and value.revision == 2 and value.receipts == 2
        end
        checks.competingConserved = finalCounts()
        local rolledBack = transact(request('forced-rollback', 1, 2), false, true)
        checks.rollbackConserved = rolledBack.ok == false and rolledBack.error.code == Result.Codes.DENIED and finalCounts()
        local passed = 0
        for _, name in ipairs({ 'duplicateAccepted', 'duplicateSpentOnce', 'oneRevisionWinner', 'competingConserved', 'rollbackConserved' }) do
            if checks[name] then passed = passed + 1 end
            print(prefix .. name .. ' ' .. (checks[name] and 'PASS' or 'FAIL'))
        end
        print(prefix .. ('concurrent done %d/5; expected loose=6 carried=6 revision=2 receipts=2; fixture only'):format(passed))
    else
        local result = TransactionAPI.Transaction({ reason = 'ammo_fixture_cleanup' }, function(tx)
            tx.query('SELECT id FROM fi_ammo_smoke_balance WHERE character_id = ? FOR UPDATE', { fixtureId })
            for _, tableName in ipairs({ 'fi_ammo_smoke_receipts', 'fi_ammo_smoke_ledger', 'fi_ammo_smoke_balance' }) do
                tx.query('DELETE FROM ' .. tableName .. ' WHERE character_id = ?', { fixtureId })
            end
            return Result.Ok(true)
        end)
        local remaining = DB.value([[SELECT
            (SELECT COUNT(*) FROM fi_ammo_smoke_balance WHERE character_id = ?) +
            (SELECT COUNT(*) FROM fi_ammo_smoke_ledger WHERE character_id = ?) +
            (SELECT COUNT(*) FROM fi_ammo_smoke_receipts WHERE character_id = ?)]], fixtureId, fixtureId, fixtureId)
        print(prefix .. 'cleanup ' .. (result.ok and tonumber(remaining) == 0 and 'PASS' or 'FAIL') ..
            '; disposable fixture rows removed; empty test tables retained; prepare can recreate test data')
    end
end, true)
return FixtureTx, pair -- for local adapter/scheduler tests; not exports or runtime APIs
