-- Real migration/rollback code with modeled domain storage and Access receipts.
local root = arg and arg[1] or '.'
local function Copy(value)
    if type(value) ~= 'table' then return value end
    local result = {}; for key, item in pairs(value) do result[key] = Copy(item) end; return result
end
local function Encode(value)
    if type(value) == 'string' then return string.format('%q', value) end
    if type(value) ~= 'table' then return tostring(value) end
    local keys = {}; for key in pairs(value) do keys[#keys + 1] = key end
    table.sort(keys, function(a,b) return tostring(a) < tostring(b) end)
    local parts = {}; for _, key in ipairs(keys) do parts[#parts+1] = '[' .. Encode(key) .. ']=' .. Encode(value[key]) end
    return '{' .. table.concat(parts, ',') .. '}'
end
json = {encode = Encode, decode = function(value) return assert(load('return ' .. value, '@codec', 't', {}))() end}
local count, sequence, active, failAt, attempts = 0, 0, false, 2, 0
local function Check(value, label) assert(value, label); count = count + 1 end
local function Id(number) return ('70000000-0000-4000-8000-%012d'):format(number) end
local now = 1800000000000
local inventory = {id = 1, uuid = Id(1), owner_character_id = Id(2), access_epoch = 1, access_authority = 'legacy', location = 'storage'}
local legacy = {{id = 1, character_id = Id(3), granted_by_character_id = Id(2)}}
local saved, grants, receipts = nil, {}, {}
Config = {Access = {NativeDelegation = true}}
InventoryAPI = {}
CreateThread = function() end
AddEventHandler = function() end
RegisterCommand = function() end
GetResourceState = function() return 'started' end
GetCurrentResourceName = function() return 'feather-inventory' end
DefaultQuery = function() end
local function One(sql)
    if sql:find('inventory_access_cutovers', 1, true) then return Copy(saved) end
    if sql:find('FROM `inventory`', 1, true) then return Copy(inventory) end
    error('Unmodeled one: ' .. sql)
end
local function Exec(sql, ...)
    local args = {...}
    if sql:find('INSERT INTO `inventory_access_cutovers`', 1, true) then
        saved = {inventory_id = args[1], valid_from = args[2], valid_until = args[3], epoch = args[4], legacy_json = args[5], state = 'preparing'}
    elseif sql:find('UPDATE `inventory`', 1, true) then
        inventory.access_authority = sql:find("'access'", 1, true) and 'access' or 'legacy'
    elseif sql:find('UPDATE `inventory_access_cutovers`', 1, true) then
        saved.state = sql:find("'rolled_back'", 1, true) and 'rolled_back' or 'access'
        saved.grants_json = args[1]
    else error('Unmodeled exec: ' .. sql) end
    return 1
end
DB = {
    one = function(sql, ...) assert(not active, 'global query inside transaction'); return One(sql, ...) end,
    transaction = function(fn)
        local before = {Copy(inventory), Copy(saved), Copy(legacy)}
        active = true
        local ok, result = pcall(fn, {one = One, value = function() return now end, exec = Exec,
            query = function() return Copy(legacy) end})
        active = false
        if not ok or result ~= true then inventory, saved, legacy = before[1], before[2], before[3] end
        if not ok then error(result) end
        return result
    end,
}
DefaultQuery = function(sql) local row = One(sql); return row and {row} or {} end
exports = {['feather-access'] = {
    GrantCapability = function(_, request)
        assert(not active, 'Access grant inside Inventory transaction')
        if receipts[request.requestId] then return {ok = true, value = Copy(receipts[request.requestId])} end
        attempts = attempts + 1
        if attempts == failAt then return {ok = false, code = 'injected_failure'} end
        sequence = sequence + 1
        local value = {grantId = Id(sequence + 10), status = 'active', revision = 1}
        grants[value.grantId], receipts[request.requestId] = Copy(value), Copy(value)
        return {ok = true, value = value}
    end,
    ListTargetGrants = function()
        assert(not active, 'Access list inside Inventory transaction')
        local rows = {}; for _, grant in pairs(grants) do rows[#rows + 1] = Copy(grant) end
        return {ok = true, value = {items = rows}}
    end,
    FindOperation = function(_, request)
        return {ok = true, value = {found = receipts[request.requestId] ~= nil, result = Copy(receipts[request.requestId])}}
    end,
    WithInventoryFence = function(_, callback) return {ok = true, value = callback()} end,
}}
dofile(root .. '/server/services/inventory_delegation.lua')
InventoryDelegation.ready = true
dofile(root .. '/server/services/inventory_delegation_cutover.lua')
local D = InventoryDelegation
Check(not pcall(D.Migrate, inventory.uuid, now + 3600000), 'partial import fails without cutover')
Check(inventory.access_authority == 'legacy' and saved.state == 'preparing', 'legacy remains sole authority on failure')
Check(#legacy == 1 and legacy[1].character_id == Id(3), 'legacy share retained')
Check(not D.LegacyWrite(1), 'preparing receipt freezes legacy writers across restarts')
failAt = nil
local result = D.Migrate(inventory.uuid, now + 3600000)
Check(result.imported == 3 and inventory.access_authority == 'access', 'resume imports three exact grants then switches')
Check(sequence == 3, 'receipt replay did not duplicate partial grant')
Check(not D.LegacyWrite(1), 'native authority rejects legacy writers')
Check(D.Rollback(inventory.uuid) and inventory.access_authority == 'legacy', 'unchanged native state permits rollback')
Check(D.LegacyWrite(1), 'rollback restores legacy writer')
Check(D.Migrate(inventory.uuid, now + 3600000).imported == 3 and sequence == 3, 'unchanged cutover can replay')
for _, grant in pairs(grants) do grant.status = 'revoked'; grant.revision = 2; break end
Check(not pcall(D.Rollback, inventory.uuid) and inventory.access_authority == 'access', 'native grant changes reject unsafe rollback')
Check(not pcall(D.Migrate, inventory.uuid, now + 7200000), 'expiry rewrite rejected')
inventory.access_epoch = 2
Check(not pcall(D.Migrate, inventory.uuid, now + 3600000), 'changed ownership rejects stale import')
-- Empty containers do not fabricate legacy grants.
inventory.access_epoch, inventory.access_authority = 1, 'legacy'
legacy, grants, receipts, saved = {}, {}, {}, nil
Check(D.Migrate(inventory.uuid, now + 3600000).imported == 0, 'empty-container cutover')
Check(D.Rollback(inventory.uuid), 'empty-container rollback')
-- A partial preparation also has a recoverable rollback path.
legacy = {{id = 1, character_id = Id(3), granted_by_character_id = Id(2)}}
grants, receipts, saved, attempts, failAt = {}, {}, nil, 0, 2
Check(not pcall(D.Migrate, inventory.uuid, now + 3600000), 'partial preparation failure repeat')
Check(D.Rollback(inventory.uuid) and saved.state == 'rolled_back' and D.LegacyWrite(1), 'partial-import rollback restores legacy management')
print(('PASS %d migration/reconciliation/rollback assertions; SQL/Access modeled'):format(count))
