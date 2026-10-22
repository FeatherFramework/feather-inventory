-- Inventory owns identities/epochs and SQL locks; Access owns delegated grants.
InventoryDelegation = {ready = false, migrating = {}, fixtureTargets = {}}
local D, sessions = InventoryDelegation, {}
local modes = {read = 'inventory.read', insert = 'inventory.insert', remove = 'inventory.remove'}
local function Uuid(value)
    return type(value) == 'string' and value:match('^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$') ~= nil
end
D.Uuid = Uuid
function D.Query(query, sql, params) return (query or DefaultQuery)(sql, params) end
function D.Row(id, query, lock)
    if not D.ready then return nil end
    local rows = D.Query(query, [[SELECT `id`,`uuid`,`location`,`owner_character_id`,`is_public`,
        `access_authority`,`access_epoch` FROM `inventory` WHERE `id`=?]] .. (lock and ' FOR UPDATE' or ''), {id})
    return rows and rows[1]
end
function D.Access(operation, request)
    if GetResourceState('feather-access') ~= 'started' then return {ok = false, code = 'provider_unavailable'} end
    local called, result = pcall(function() return exports['feather-access'][operation](nil, request) end)
    if not called or type(result) ~= 'table' then return {ok = false, code = 'provider_unavailable'} end
    return result
end
local function Session(source)
    local result = InventoryIdentity.GetSession(source)
    return Result.IsOk(result) and result.value or nil
end
local function SameSession(source, before)
    local current = Session(source)
    return current and before and current.characterId == before.characterId and current.sessionId == before.sessionId
        and current.accountId == before.accountId and current.generation == before.generation
end
local function Native(row) return row and row.access_authority == 'access' end
function D.Base(source, character, row)
    if row.owner_character_id == character or Boolean[row.is_public] == true then return true end
    local temporary = InventoryAPI.HasTemporaryAccess(source, row.id)
    return Result.IsOk(temporary) and temporary.value == true
end
function D.Read(source, id, action)
    if not D.ready then return false end
    local row = D.Row(id)
    if not Native(row) then return nil end
    local session = Session(source)
    if not session then return false end
    if D.Base(source, session.characterId, row) then return true end
    if not Config.Access.NativeDelegation or not modes[action] then return false end
    local result = D.Access('CheckCapability', {targetType = 'inventory.storage', targetId = row.uuid,
        capability = modes[action], actorSource = tonumber(source)})
    return SameSession(source, session) and result.ok == true and result.value.allowed == true
end
local function ValidFence(token)
    local result = D.Access('ValidateInventoryFence', token)
    return result.ok == true and result.value == true
end
local function Fresh(decision)
    return type(decision) == 'table' and decision.allowed == true
        and (GetGameTimer() - decision.started) % 4294967296 < decision.validForMs
end
function D.Check(source, id, action, query)
    if not D.ready then return false end
    local row = D.Row(id, query)
    if not Native(row) then return nil end
    local session = Session(source)
    if not session then return false end
    if D.Base(source, session.characterId, row) then return true end
    if not query then return D.Read(source, id, action) end
    -- Transaction decisions are prepared outside SQL, never queried through
    -- another resource while Inventory is holding rows on its own connection.
    local snapshot = sessions[coroutine.running()]
    local decision = snapshot and snapshot.rows[tostring(id)]
    local allowed = snapshot ~= nil and SameSession(source, snapshot.session) and snapshot.source == tonumber(source)
        and decision ~= nil and decision.epoch == tonumber(row.access_epoch)
        and decision.uuid == row.uuid and Fresh(decision[action]) and ValidFence(snapshot.token)
    if allowed then snapshot.used[tostring(id) .. ':' .. action] = decision[action] end
    return allowed
end
function D.Transaction(context, runner)
    local metrics = context and context._timing
    local preparationStarted = metrics and GetGameTimer()
    local function Prepared()
        if metrics then
            metrics.delegationPrepareMs = (metrics.delegationPrepareMs or 0)
                + InventoryMutationMetrics.Elapsed(preparationStarted)
        end
    end
    local source = context and tonumber(context.actorSource)
    if not source or not D.ready or not Config.Access.NativeDelegation then return runner() end
    local session = Session(source)
    if not session then return false, false end
    local candidates, observed = {}, {}
    for id, opened in pairs(InventoryAPI.DelegationSessions(source)) do
        if opened.src == tostring(source) and not tonumber(opened.uuid) then
            local row = D.Row(id)
            if row then observed[tostring(row.id)] = {epoch = tonumber(row.access_epoch), uuid = row.uuid, authority = row.access_authority} end
            if Native(row) and not D.Base(source, session.characterId, row) then candidates[#candidates + 1] = row end
        end
    end
    if next(observed) == nil then Prepared(); return runner() end
    local observedCount = 0; for _ in pairs(observed) do observedCount = observedCount + 1 end
    if observedCount > 8 then return false, false end
    local ownId = InventoryControllers.GetInventoryByCharacter(session.characterId)
    local own = ownId and D.Row(ownId)
    if own then observed[tostring(own.id)] = {epoch = tonumber(own.access_epoch), uuid = own.uuid, authority = own.access_authority} end
    if #candidates > 8 then return false, false end
    table.sort(candidates, function(a, b) return tonumber(a.id) < tonumber(b.id) end)
    local fenceStarted = metrics and GetGameTimer()
    local function Perform(token)
        if metrics and token then
            metrics.delegationFenceWaitMs = (metrics.delegationFenceWaitMs or 0)
                + InventoryMutationMetrics.Elapsed(fenceStarted)
        end
        local snapshot = {source = source, session = session, token = token, rows = observed, used = {}}
        for _, row in ipairs(candidates) do
            local decisions = snapshot.rows[tostring(row.id)]
            for action, capability in pairs(modes) do
                local started = GetGameTimer()
                local result = D.Access('CheckCapability', {targetType = 'inventory.storage', targetId = row.uuid,
                    capability = capability, actorSource = source})
                if metrics then
                    metrics.delegationChecksMs = (metrics.delegationChecksMs or 0)
                        + InventoryMutationMetrics.Elapsed(started)
                    metrics.delegationChecks = (metrics.delegationChecks or 0) + 1
                end
                decisions[action] = {started = started, allowed = result.ok == true and result.value.allowed == true,
                    validForMs = result.ok == true and tonumber(result.value.validForMs) or 0}
                if not decisions[action].validForMs then decisions[action].allowed = false end
            end
            snapshot.rows[tostring(row.id)] = decisions
        end
        local thread = coroutine.running()
        Prepared()
        sessions[thread] = snapshot
        local called, values = pcall(function() return table.pack(runner(snapshot)) end)
        sessions[thread] = nil
        if not called then return {values = {false, false, n = 2}} end
        return {values = values}
    end
    if #candidates == 0 then
        local result = Perform()
        return table.unpack(result.values, 1, result.values.n)
    end
    local fenced = D.Access('WithInventoryFence', Perform)
    if fenced.ok ~= true or type(fenced.value) ~= 'table' or type(fenced.value.values) ~= 'table' then return false, false end
    return table.unpack(fenced.value.values, 1, fenced.value.values.n)
end
function D.LockSnapshot(query, snapshot)
    if not snapshot then return true end
    local ids = {}; for id in pairs(snapshot.rows) do ids[#ids + 1] = tonumber(id) end
    table.sort(ids)
    local placeholders = {}; for i in ipairs(ids) do placeholders[i] = '?' end
    local rows = query('SELECT `id`,`uuid`,`access_epoch`,`access_authority` FROM `inventory` WHERE `id` IN (' ..
        table.concat(placeholders, ',') .. ') ORDER BY `id` FOR UPDATE', ids)
    if #rows ~= #ids then return false end
    for _, row in ipairs(rows) do
        local expected = snapshot.rows[tostring(row.id)]
        if not expected or row.uuid ~= expected.uuid or tonumber(row.access_epoch) ~= expected.epoch
            or row.access_authority ~= expected.authority then return false end
    end
    return SameSession(snapshot.source, snapshot.session) and (not snapshot.token or ValidFence(snapshot.token))
end
function D.EndSnapshot(snapshot)
    if not snapshot then return true end
    for _, decision in pairs(snapshot.used) do if not Fresh(decision) then return false end end
    return SameSession(snapshot.source, snapshot.session) and (not snapshot.token or ValidFence(snapshot.token))
end
function D.LegacyWrite(id)
    if not D.ready then return false end
    local row = D.Row(id)
    local pending = DB.one('SELECT `state` FROM `inventory_access_cutovers` WHERE `inventory_id`=?', id)
    return not D.migrating[tostring(id)] and (not pending or pending.state ~= 'preparing')
        and (not row or row.access_authority == 'legacy')
end
function D.LegacyMutation(id, fn)
    local changed = false
    local ok, committed = pcall(DB.transaction, function(tx)
        local row = tx.one('SELECT `access_authority` FROM `inventory` WHERE `id`=? FOR UPDATE', id)
        local cutover = tx.one('SELECT `state` FROM `inventory_access_cutovers` WHERE `inventory_id`=? FOR UPDATE', id)
        if not row or row.access_authority ~= 'legacy' or D.migrating[tostring(id)]
            or (cutover and cutover.state == 'preparing') then return false end
        fn(tx); changed = true; return true
    end)
    if not ok or not committed or not changed then return Result.Err(Result.Codes.DENIED, 'Legacy delegation changed or is migrating.') end
    return Result.Ok(true)
end
local function Register()
    if not D.ready or GetResourceState('feather-access') ~= 'started' then return end
    local available = exports['feather-access']:AwaitReady(30000)
    if not available.ok then return end
    D.Access('UnregisterTargetProvider', {targetType = 'inventory.storage'})
    local result = D.Access('RegisterTargetProvider', {targetType = 'inventory.storage', contract = 1,
        resolve = function(request)
            local row = DB.one('SELECT `id` FROM `inventory` WHERE `uuid`=?', request.targetId)
            row = row and D.Row(row.id)
            if not row or not row.owner_character_id or row.location == 'ground' or row.location == 'character' then
                return {ok = false, code = 'target_not_found'}
            end
            return {ok = true, value = {targetType = 'inventory.storage', targetId = row.uuid,
                epoch = tonumber(row.access_epoch), status = 'active',
                capabilities = {'inventory.read', 'inventory.insert', 'inventory.remove'}}}
        end,
        authorize = function(request)
            local row = DB.one('SELECT `id` FROM `inventory` WHERE `uuid`=?', request.target.targetId)
            row = row and D.Row(row.id)
            local actor, allowed = request.actor, false
            if row and actor.resource == 'feather-inventory' then
                if actor.characterId then
                    allowed = actor.characterId == row.owner_character_id
                    if not allowed and actor.actorSource then
                        local policy = exports['feather-core']:Authorize('inventory.manage', {
                            source = actor.actorSource, subject = {ownerCharacterId = row.owner_character_id}})
                        allowed = policy.ok == true and policy.value.allowed == true
                    end
                else allowed = D.migrating[tostring(row.id)] == true or D.fixtureTargets[row.uuid] == true end
            end
            return {ok = true, value = {allowed = allowed}}
        end,
    })
    D.registered = result.ok == true
    print('[InventoryAccess] provider=' .. (result.ok and 'ready' or tostring(result.code)))
end
D.Register = Register
CreateThread(function()
    InventoryAwaitDatabase()
    while not InventoryAccessSchemaReady do Wait(0) end
    -- Inventory owns these additive columns; its existing UUID is the Access target.
    for name, definition in pairs({access_authority = "VARCHAR(16) NOT NULL DEFAULT 'legacy'",
        access_epoch = 'BIGINT UNSIGNED NOT NULL DEFAULT 1'}) do
        if #DB.query('SHOW COLUMNS FROM `inventory` LIKE ?', name) == 0 then
            DB.exec('ALTER TABLE `inventory` ADD COLUMN `' .. name .. '` ' .. definition)
        end
    end
    DB.exec([[CREATE TABLE IF NOT EXISTS `inventory_access_cutovers` (
        `inventory_id` BIGINT UNSIGNED NOT NULL PRIMARY KEY, `valid_from` BIGINT UNSIGNED NOT NULL,
        `valid_until` BIGINT UNSIGNED NOT NULL, `epoch` BIGINT UNSIGNED NOT NULL,
        `legacy_json` LONGTEXT NOT NULL, `grants_json` LONGTEXT NULL,
        `state` VARCHAR(16) NOT NULL DEFAULT 'preparing') ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
    DB.exec([[CREATE TABLE IF NOT EXISTS `inventory_delegation_fixtures` (
        `run_key` VARCHAR(40) NOT NULL PRIMARY KEY, `inventory_id` BIGINT UNSIGNED NOT NULL,
        `counter` INT NOT NULL DEFAULT 0) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4]])
    D.ready = true
    Register()
end)
AddEventHandler('onResourceStart', function(resource) if resource == 'feather-access' then CreateThread(function()
    local result = exports['feather-access']:AwaitReady(30000)
    if result.ok then Register() end
end) end end)
AddEventHandler('onResourceStop', function(resource) if resource == 'feather-access' then D.registered = false end end)
RegisterCommand('InventoryAccessStatus', function(source)
    if source ~= 0 then return end
    if not D.ready then print('[InventoryAccessStatus] ready=false'); return end
    CreateThread(function()
        local native = DB.value("SELECT COUNT(*) FROM `inventory` WHERE `access_authority`='access'")
        local preparing = DB.value("SELECT COUNT(*) FROM `inventory_access_cutovers` WHERE `state`='preparing'")
        print(('[InventoryAccessStatus] ready=true provider=%s native=%s preparing=%s'):format(tostring(D.registered == true), tostring(native), tostring(preparing)))
    end)
end, true)
