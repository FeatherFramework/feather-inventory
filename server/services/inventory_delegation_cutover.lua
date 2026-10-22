local D = InventoryDelegation
local function Legacy(tx, id)
    return tx.query('SELECT `id`,`character_id`,`granted_by_character_id` FROM `inventory_access` WHERE `inventory_id`=? ORDER BY `character_id` FOR UPDATE', id)
end
local function Signature(rows)
    local result = {}
    for _, row in ipairs(rows) do result[#result + 1] = {tostring(row.id), row.character_id, row.granted_by_character_id or ''} end
    return json.encode(result)
end
local function CurrentGrants(uuid)
    local all, cursor = {}, nil
    for _ = 1, 64 do
        local result = D.Access('ListTargetGrants', {targetType = 'inventory.storage', targetId = uuid, limit = 50, cursor = cursor})
        assert(result.ok, 'Access target read failed: ' .. tostring(result.code))
        for _, grant in ipairs(result.value.items) do all[grant.grantId] = grant end
        cursor = result.value.nextCursor
        if not cursor then return all end
    end
    error('Target grant reconciliation exceeds bounded limit')
end
local function Reconciled(uuid, imported)
    local actual, expected = CurrentGrants(uuid), {}
    for _, id in ipairs(imported) do expected[id] = true end
    for id, grant in pairs(actual) do
        assert(expected[id] and grant.status == 'active' and grant.revision == 1, 'Native grants changed; automatic cutover/rollback refused')
        expected[id] = nil
    end
    assert(next(expected) == nil, 'Imported grant is missing')
end
function D.Migrate(uuid, validUntil)
    assert(D.ready and Config.Access.NativeDelegation and D.Uuid(uuid), 'Native delegation must be ready and UUID valid')
    validUntil = tonumber(validUntil)
    assert(validUntil and validUntil % 1 == 0, 'Explicit expiry in epoch milliseconds required')
    local row = DB.one('SELECT `id` FROM `inventory` WHERE `uuid`=?', uuid)
    assert(row, 'Container missing')
    local id = row.id
    assert(not D.migrating[tostring(id)], 'Container operation already running')
    D.migrating[tostring(id)] = true
    local ok, outcome = xpcall(function()
        local saved
        local committed = DB.transaction(function(tx)
            local target = tx.one('SELECT * FROM `inventory` WHERE `id`=? FOR UPDATE', id)
            assert(D.Uuid(target.owner_character_id) and target.uuid == target.uuid:lower()
                and target.location ~= 'character' and target.location ~= 'ground', 'Only owned storage with canonical UUIDs can migrate')
            local rows = Legacy(tx, id)
            assert(#rows <= 100, 'Migration bounded to 100 legacy shares per container')
            saved = tx.one('SELECT * FROM `inventory_access_cutovers` WHERE `inventory_id`=? FOR UPDATE', id)
            if not saved then
                local now = tonumber(tx.value('SELECT FLOOR(UNIX_TIMESTAMP(CURRENT_TIMESTAMP(3))*1000)'))
                assert(validUntil > now and validUntil - (now - 1000) <= 31622400000, 'Expiry must be future and within Access maximum validity')
                tx.exec([[INSERT INTO `inventory_access_cutovers` (`inventory_id`,`valid_from`,`valid_until`,`epoch`,`legacy_json`)
                    VALUES (?,?,?,?,?)]], id, now - 1000, validUntil, target.access_epoch, Signature(rows))
                saved = tx.one('SELECT * FROM `inventory_access_cutovers` WHERE `inventory_id`=?', id)
            end
            assert(tonumber(saved.valid_until) == validUntil and tonumber(saved.epoch) == tonumber(target.access_epoch), 'Migration terms/ownership changed')
            assert(saved.legacy_json == Signature(rows), 'Legacy shares changed; reconciliation required')
            saved.rows, saved.uuid = rows, target.uuid
            return true
        end)
        assert(committed, 'Migration preparation did not commit; retry same expiry')
        local imported = {}
        for _, share in ipairs(saved.rows) do
            assert(D.Uuid(share.character_id), 'Legacy character UUID malformed')
            for _, mode in ipairs({'read', 'insert', 'remove'}) do
                local grant = D.Access('GrantCapability', {
                    requestId = 'inventory-import:' .. saved.uuid .. ':' .. share.character_id .. ':' .. mode,
                    targetType = 'inventory.storage', targetId = saved.uuid, expectedEpoch = tonumber(saved.epoch),
                    granteeType = 'character', granteeId = share.character_id,
                    capability = 'inventory.' .. mode, validFrom = tonumber(saved.valid_from), validUntil = validUntil,
                    provenanceType = 'inventory.legacy_import', provenanceId = saved.uuid, reasonCode = 'inventory.legacy_import',
                })
                assert(grant.ok, 'Import failed: ' .. tostring(grant.code) .. '; legacy remains authoritative, retry same expiry')
                imported[#imported + 1] = grant.value.grantId
            end
        end
        -- Fence grant writes while reconciling and switching Inventory's sole
        -- persistent delegation authority. Imported records remain inert until flip.
        local switched = D.Access('WithInventoryFence', function()
            Reconciled(saved.uuid, imported)
            return DB.transaction(function(tx)
                local target = tx.one('SELECT `access_epoch` FROM `inventory` WHERE `id`=? FOR UPDATE', id)
                assert(tonumber(target.access_epoch) == tonumber(saved.epoch), 'Ownership changed')
                assert(Signature(Legacy(tx, id)) == saved.legacy_json, 'Legacy shares changed')
                local now = tonumber(tx.value('SELECT FLOOR(UNIX_TIMESTAMP(CURRENT_TIMESTAMP(3))*1000)'))
                assert(validUntil > now, 'Imported grants expired before cutover')
                tx.exec("UPDATE `inventory` SET `access_authority`='access' WHERE `id`=?", id)
                tx.exec("UPDATE `inventory_access_cutovers` SET `state`='access',`grants_json`=? WHERE `inventory_id`=?", json.encode(imported), id)
                return true
            end)
        end)
        assert(switched.ok and switched.value == true, 'Cutover did not confirm; inspect authority and retry same expiry')
        return {inventoryId = id, targetId = saved.uuid, imported = #imported, authority = 'access'}
    end, debug.traceback)
    D.migrating[tostring(id)] = nil
    if not ok then error(outcome) end
    return outcome
end
function D.Rollback(uuid)
    assert(D.ready and D.Uuid(uuid), 'Delegation ready and exact UUID required')
    local target = DB.one('SELECT `id` FROM `inventory` WHERE `uuid`=?', uuid)
    assert(target and not D.migrating[tostring(target.id)], 'Target missing or busy')
    local id = target.id
    D.migrating[tostring(id)] = true
    local ok, result = xpcall(function()
        local saved = DB.one('SELECT * FROM `inventory_access_cutovers` WHERE `inventory_id`=?', id)
        assert(saved, 'No prepared cutover to roll back')
        local imported = saved.grants_json and json.decode(saved.grants_json) or {}
        if not saved.grants_json then
            for _, share in ipairs(json.decode(saved.legacy_json)) do
                for _, mode in ipairs({'read', 'insert', 'remove'}) do
                    local prior = D.Access('FindOperation', {requestId = 'inventory-import:' .. uuid .. ':' .. share[2] .. ':' .. mode})
                    assert(prior.ok, 'Partial-import receipt lookup failed')
                    if prior.value.found then imported[#imported + 1] = prior.value.result.grantId end
                end
            end
        end
        local fenced = D.Access('WithInventoryFence', function()
            Reconciled(uuid, imported)
            return DB.transaction(function(tx)
                local row = tx.one('SELECT `access_epoch` FROM `inventory` WHERE `id`=? FOR UPDATE', id)
                assert(tonumber(row.access_epoch) == tonumber(saved.epoch), 'Ownership changed; automatic rollback refused')
                assert(Signature(Legacy(tx, id)) == saved.legacy_json, 'Legacy archive changed')
                tx.exec("UPDATE `inventory` SET `access_authority`='legacy' WHERE `id`=?", id)
                tx.exec("UPDATE `inventory_access_cutovers` SET `state`='rolled_back',`grants_json`=? WHERE `inventory_id`=?", json.encode(imported), id)
                return true
            end)
        end)
        assert(fenced.ok and fenced.value == true, 'Rollback unconfirmed; inspect before retry')
        return true
    end, debug.traceback)
    D.migrating[tostring(id)] = nil
    if not ok then error(result) end
    return result
end
InventoryAPI.GrantInventoryCapability = function(source, inventoryId, request)
    source = tonumber(source)
    if not source or source % 1 ~= 0 or source < 1 or source > 65535 then
        return Result.Err(Result.Codes.INVALID_INPUT, 'Online actor source required.')
    end
    local row = D.Row(inventoryId)
    if not row or row.access_authority ~= 'access' or type(request) ~= 'table' then
        return Result.Err(Result.Codes.DENIED, 'An Access-backed container and exact grant terms are required.')
    end
    local fields = {}; for key, value in pairs(request) do fields[key] = value end
    fields.actorSource, fields.targetType, fields.targetId, fields.expectedEpoch = tonumber(source), 'inventory.storage', row.uuid, tonumber(row.access_epoch)
    local granted = D.Access('GrantCapability', fields)
    if not granted.ok then return Result.Err(granted.code, granted.message or 'Grant denied.') end
    return Result.Ok(granted.value)
end
InventoryAPI.RevokeInventoryCapability = function(source, request)
    source = tonumber(source)
    if not source or source % 1 ~= 0 or source < 1 or source > 65535 then
        return Result.Err(Result.Codes.INVALID_INPUT, 'Online actor source required.')
    end
    if type(request) ~= 'table' then return Result.Err(Result.Codes.INVALID_INPUT, 'Revoke terms required.') end
    local fields = {}; for key, value in pairs(request) do fields[key] = value end
    fields.actorSource = tonumber(source)
    local revoked = D.Access('RevokeGrant', fields)
    if not revoked.ok then return Result.Err(revoked.code, revoked.message or 'Revoke denied.') end
    return Result.Ok(revoked.value)
end
InventoryAPI.ListInventoryCapabilities = function(source, inventoryId, limit, cursor)
    local row = D.Row(inventoryId)
    source = tonumber(source)
    if not row or row.access_authority ~= 'access' or not source or source < 1 or source % 1 ~= 0 then
        return Result.Err(Result.Codes.INVALID_INPUT, 'Actor and native container required.')
    end
    local listed = D.Access('ListTargetGrants', {targetType = 'inventory.storage', targetId = row.uuid,
        actorSource = source, limit = limit or 20, cursor = cursor})
    if not listed.ok then return Result.Err(listed.code, listed.message or 'Grant list denied.') end
    return Result.Ok(listed.value)
end
RegisterCommand('InventoryAccessMigrate', function(source, args)
    if source ~= 0 then return end
    CreateThread(function()
        local ok, result = pcall(D.Migrate, args[1], args[2])
        print('[InventoryAccessMigrate] ' .. (ok and ('PASS target=' .. result.targetId .. ' imported=' .. result.imported .. ' authority=access') or ('FAIL ' .. tostring(result))))
    end)
end, true)
RegisterCommand('InventoryAccessRollback', function(source, args)
    if source ~= 0 then return end
    CreateThread(function()
        local ok, result = pcall(D.Rollback, args[1])
        print('[InventoryAccessRollback] ' .. (ok and 'PASS authority=legacy' or ('FAIL ' .. tostring(result))))
    end)
end, true)
