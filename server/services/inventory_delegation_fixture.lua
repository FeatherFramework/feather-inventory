local D = InventoryDelegation
exports('InventoryDelegationFixture', function(request)
    local caller = GetInvokingResource()
    if not Config.DevMode or caller ~= 'feather-inventory-access-tests' or type(request) ~= 'table' then
        return Result.Err(Result.Codes.DENIED, 'Development delegation fixture only.')
    end
    if type(request.run) ~= 'string' or #request.run > 24 or not request.run:match('^[a-z][a-z0-9_]*$') then
        return Result.Err(Result.Codes.INVALID_INPUT, 'Stable fixture run required.')
    end
    local ok, result = xpcall(function()
        assert(D.ready, 'Delegation schema not ready')
        local fixture = DB.one('SELECT * FROM `inventory_delegation_fixtures` WHERE `run_key`=?', request.run)
        if request.action == 'create' and not fixture then
            assert(DB.transaction(function(tx)
                local ids = tx.one('SELECT UUID() AS target, UUID() AS owner')
                -- Synthetic owner is isolated fixture attribution, never another
                -- player's profile. The actual tester is the delegated recipient.
                tx.exec([[INSERT INTO `inventory` (`uuid`,`location`,`name`,`owner_character_id`,`is_public`,`access_authority`,`max_weight`,`max_slots`)
                    VALUES (?,'delegation_fixture',?,?,0,'legacy',10,2)]], ids.target, 'Access fixture ' .. request.run, ids.owner)
                local id = tx.value('SELECT `id` FROM `inventory` WHERE `uuid`=?', ids.target)
                tx.exec('INSERT INTO `inventory_delegation_fixtures` (`run_key`,`inventory_id`) VALUES (?,?)', request.run, id)
                return true
            end), 'Fixture creation unconfirmed; retry same run')
            fixture = DB.one('SELECT * FROM `inventory_delegation_fixtures` WHERE `run_key`=?', request.run)
        end
        assert(fixture, 'Fixture does not exist')
        local row = D.Row(fixture.inventory_id)
        assert(row and row.location == 'delegation_fixture' and row.owner_character_id, 'Fixture identity changed')
        D.fixtureTargets[row.uuid] = true
        if request.action == 'create' then return {id = row.id, uuid = row.uuid, authority = row.access_authority} end
        if request.action == 'migrate' then
            local untilMs = tonumber(DB.value('SELECT FLOOR(UNIX_TIMESTAMP(CURRENT_TIMESTAMP(3))*1000)')) + 3600000
            local saved = DB.one('SELECT `valid_until` FROM `inventory_access_cutovers` WHERE `inventory_id`=?', row.id)
            return D.Migrate(row.uuid, saved and saved.valid_until or untilMs)
        end
        if request.action == 'rollback' then return D.Rollback(row.uuid) end
        local source = tonumber(request.source)
        local session = source and InventoryIdentity.GetSession(source)
        assert(session and Result.IsOk(session), 'Selected test character required')
        assert(session.value.characterId ~= row.owner_character_id, 'Tester must be a delegate, not the fixture owner')
        if request.action == 'seed_legacy' then
            assert(row.access_authority == 'legacy', 'Seed only before migration')
            DB.exec('INSERT IGNORE INTO `inventory_access` (`inventory_id`,`character_id`,`granted_by_character_id`) VALUES (?,?,?)',
                row.id, session.value.characterId, row.owner_character_id)
            return true
        end
        if request.action == 'grant' then
            assert(request.mode == 'read' or request.mode == 'insert' or request.mode == 'remove', 'Exact fixture capability required')
            local now = tonumber(DB.value('SELECT FLOOR(UNIX_TIMESTAMP(CURRENT_TIMESTAMP(3))*1000)'))
            assert(request.series == nil or request.series == 'restore', 'Unsupported fixture series')
            local operation = 'inventory-fixture:' .. request.run .. ':' .. request.mode .. (request.series and ':restore' or '')
            local prior = D.Access('FindOperation', {requestId = operation})
            assert(prior.ok, 'Receipt read denied')
            if prior.value.found then return prior.value.result end
            local grant = D.Access('GrantCapability', {requestId = operation,
                targetType = 'inventory.storage', targetId = row.uuid, expectedEpoch = tonumber(row.access_epoch),
                granteeType = 'character', granteeId = session.value.characterId, capability = 'inventory.' .. request.mode,
                validFrom = now - 1000, validUntil = now + 3600000,
                provenanceType = 'inventory.fixture', provenanceId = row.uuid, reasonCode = 'inventory.fixture'})
            assert(grant.ok, 'Grant failed: ' .. tostring(grant.code)); return grant.value
        end
        if request.action == 'revoke' then
            local operation = 'inventory-fixture:' .. request.run .. ':' .. request.mode
            local prior = D.Access('FindOperation', {requestId = operation})
            assert(prior.ok and prior.value.found, 'Grant receipt missing')
            local revoked = D.Access('RevokeGrant', {requestId = operation .. ':revoke', grantId = prior.value.result.grantId,
                expectedRevision = 1, reasonCode = 'inventory.fixture'})
            assert(revoked.ok, 'Revoke failed: ' .. tostring(revoked.code)); return revoked.value
        end
        if request.action == 'open' then
            assert(D.Read(source, row.id, 'read') == true, 'No read capability')
            return InventoryAPI.OpenDelegationFixtureSession(source, row.id)
        end
        if request.action == 'ui' then
            assert(D.Read(source, row.id, 'read') == true, 'No fixture read capability')
            return Result.IsOk(InventoryAPI.OpenInventory(source, row.uuid))
        end
        if request.action == 'close' then InventoryAPI.CloseDelegationFixtureSession(source, row.id); return true end
        if request.action == 'read' then return IsAuthorizedForOwnedInventory(source, session.value.characterId, row.id) == true end
        if request.action == 'mutate' then
            assert(request.mode == 'insert' or request.mode == 'remove', 'Exact mutation mode required')
            local before = tonumber(DB.value('SELECT `counter` FROM `inventory_delegation_fixtures` WHERE `run_key`=?', request.run))
            local mutation = TransactionAPI.Transaction({actorSource = source, reason = 'inventory.fixture'}, function(tx)
                local denied = tx:RequireAccess(row.id, request.mode)
                if denied then return denied end
                tx.query('UPDATE `inventory_delegation_fixtures` SET `counter`=`counter`+1 WHERE `run_key`=?', {request.run})
                return Result.Ok(true)
            end)
            local after = tonumber(DB.value('SELECT `counter` FROM `inventory_delegation_fixtures` WHERE `run_key`=?', request.run))
            return {allowed = Result.IsOk(mutation), delta = after - before}
        end
        error('Unknown fixture action')
    end, debug.traceback)
    if not ok then return Result.Err(Result.Codes.INTERNAL, tostring(result)) end
    return Result.Ok(result)
end)
