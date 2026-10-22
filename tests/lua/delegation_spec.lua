-- Real Inventory gate/transaction adapter + real Access fence; modeled SQL/Cfx.
local root = arg and arg[1] or '.'
local clock, count, counter, active, beforeTransaction, pause = 0, 0, 0, false, nil, false
local rights = {read = true, insert = false, remove = false}
local sourceCharacter, sessionId = '60000000-0000-4000-8000-000000000001', 'session-1'
local row = {id = 2, uuid = '60000000-0000-4000-8000-000000000002', location = 'delegation_fixture',
    owner_character_id = '60000000-0000-4000-8000-000000000003', is_public = 0, access_authority = 'access', access_epoch = 1}
Config = {DevMode = true, Access = {NativeDelegation = true}, Grants = {Readers = {['feather-inventory'] = true}}}
Boolean = {[1] = true, [0] = false, [true] = true, [false] = false}
CreateThread = function() end
AddEventHandler = function() end
RegisterCommand = function() end
GetResourceState = function() return 'started' end
GetCurrentResourceName = function() return 'feather-access' end
GetGameTimer = function() return clock end
Wait = function() clock = clock + 1; coroutine.yield('wait') end
warn = function() end
DebugPrint = function() end
local function Check(value, label) assert(value, label); count = count + 1 end
local function Copy(value) local out = {}; for key, item in pairs(value) do out[key] = item end; return out end
Access = {Ok = function(value) return {ok = true, value = value} end,
    Err = function(code, message) return {ok = false, code = code, message = message} end}
Access.Ready = function() return Access.Ok(true) end
dofile(root .. '/../feather-access/server/fence.lua')
exports = {['feather-access'] = {
    WithInventoryFence = function(_, callback) return Access.InventoryFence.Run(callback, 'feather-inventory') end,
    ValidateInventoryFence = function(_, token) return Access.InventoryFence.Valid(token, 'feather-inventory') end,
    CheckCapability = function(_, request)
        assert(not active, 'Access lookup called inside Inventory SQL transaction')
        local mode = request.capability:match('inventory%.(.+)')
        return Access.Ok({allowed = rights[mode] == true, validForMs = 100})
    end,
}, ['feather-core'] = {Authorize = function() return {ok = true, value = {allowed = false}} end}}
dofile(root .. '/server/helpers/result.lua')
InventoryIdentity = {
    GetSession = function() return Result.Ok({characterId = sourceCharacter, sessionId = sessionId}) end,
    GetCharacter = function() return {char = {id = sourceCharacter}} end,
    NormalizeCharacterId = function(id) return id end,
}
InventoryControllers = {GetInventoryByCharacter = function() return 1 end,
    GetInventoryLocationById = function() return row.location end}
InventoryMutationMetrics = {Measure = function(_, _, fn, ...) return fn(...) end}
GuardsAPI = {EmitTransactionCommitted = function() end}
local function Query(sql, params)
    if sql:find('FROM `inventory`', 1, true) then
        local own = {id = 1, uuid = '60000000-0000-4000-8000-000000000004', access_epoch = 1,
            access_authority = 'legacy', location = 'character'}
        if sql:find(' IN (', 1, true) then return {own, Copy(row)} end
        return {tonumber(params[1]) == 1 and own or Copy(row)}
    end
    if sql:find('UPDATE fixture_counter', 1, true) then counter = counter + 1; return {affectedRows = 1} end
    error('Unmodeled SQL: ' .. sql)
end
DB = {
    query = function(sql, ...) assert(not active, 'Global Inventory query inside SQL transaction'); return Query(sql, {...}) end,
    transaction = function(fn)
        if beforeTransaction then local hook = beforeTransaction; beforeTransaction = nil; hook() end
        local prior = counter
        active = true
        local ok, result = pcall(fn, {raw = function(sql, ...) return Query(sql, {...}) end})
        active = false
        if not ok or result ~= true then counter = prior end
        if not ok then error(result) end
        return result == true
    end,
}
dofile(root .. '/server/services/inventory.lua')
dofile(root .. '/server/services/inventory_access.lua')
dofile(root .. '/server/services/transactions.lua')
dofile(root .. '/server/services/inventory_delegation.lua')
InventoryDelegation.ready = true
Check(InventoryAPI.OpenDelegationFixtureSession(1, 2), 'real open session requires read')
local function Mutate(mode, hook)
    return TransactionAPI.Transaction({actorSource = 1}, function(tx)
        local denied = tx:RequireAccess(2, mode)
        if denied then return denied end
        tx.query('UPDATE fixture_counter SET value=value+1', {})
        if hook then hook() end
        return Result.Ok(true)
    end)
end
Check(not Mutate('insert').ok and counter == 0, 'read-only insertion denied and no write')
Check(not Mutate('remove').ok and counter == 0, 'read-only removal denied and no write')
rights.insert = true
Check(Mutate('insert').ok and counter == 1, 'exact insert capability commits')
Check(not Mutate('remove').ok and counter == 1, 'insert never implies remove')
rights.remove = true
Check(Mutate('remove').ok and counter == 2, 'exact remove capability commits')
rights.remove = false
Check(not Mutate('remove').ok and counter == 2, 'revoke denies despite open session')
Config.Access.NativeDelegation = false
Check(InventoryDelegation.Read(1, 2, 'read') == false, 'disabled adapter never falls back to archived shares')
Check(not Mutate('insert').ok and counter == 2, 'disabled adapter denies native mutations')
Config.Access.NativeDelegation = true
Check(not Mutate('manage').ok, 'recipient cannot manage')
local oldOwner = row.owner_character_id
row.owner_character_id = sourceCharacter
Check(Mutate('remove').ok, 'owner path remains independent of grants')
row.owner_character_id = oldOwner
local before = counter
beforeTransaction = function() row.access_epoch = row.access_epoch + 1 end
Check(not Mutate('insert').ok and counter == before, 'ownership epoch changed before locks rolls back')
row.access_authority = 'legacy'
beforeTransaction = function() row.access_authority = 'access' end
Check(not Mutate('insert').ok and counter == before, 'legacy-to-native switch during preparation cannot use stale session')
before = counter
Check(not Mutate('insert', function() sessionId = 'new-session' end).ok and counter == before, 'session replacement rolls back writes')
before = counter
Check(not Mutate('insert', function() clock = clock + 101 end).ok and counter == before, 'expiry before commit rolls back writes')
-- Two coroutines demonstrate normal-runtime revoke ordering around a committed mutation.
local order = {}
local mutation = coroutine.create(function()
    local result = Mutate('insert', function() coroutine.yield('mutation-paused') end)
    Check(result.ok, 'in-flight authorized mutation commits before revoke')
    order[#order + 1] = 'commit'
end)
local revoke = coroutine.create(function()
    Access.InventoryFence.Mutate(function() rights.insert = false; order[#order + 1] = 'revoke'; return Access.Ok(true) end, {}, 'test')
end)
assert(coroutine.resume(mutation))
assert(coroutine.resume(revoke))
Check(coroutine.status(revoke) == 'suspended', 'revoke waits for active mutation fence')
assert(coroutine.resume(mutation))
assert(coroutine.resume(revoke))
Check(order[1] == 'commit' and order[2] == 'revoke', 'revoke acknowledgement ordered after prior commit')
Check(not Mutate('insert').ok, 'mutation after revoke acknowledgement denied')
Check(not Access.InventoryFence.Run(function() end, 'foreign').ok, 'foreign callback rejected')
rights.insert = true
before = counter
Check(not Mutate('insert', function() Access.InventoryFence.Stopped('feather-inventory') end).ok and counter == before,
    'consumer stop during mutation latches fence and rolls back')
Check(not Access.InventoryFence.Valid('invalid', 'feather-inventory').value, 'stopped fence cannot validate')
print(('PASS %d native delegation gate/transaction/fence assertions; SQL/Cfx modeled'):format(count))
