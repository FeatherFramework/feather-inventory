Feather = {}
Feather.RPC = {
    Register = function(name, callback, options)
        return exports['feather-core']:RegisterRPC(name, callback, options)
    end
}
Feather.Locale = {
    register = function(locale, translations)
        return exports['feather-core']:RegisterLocale(locale, translations)
    end,
    translate = function(source, key, ...)
        local result = exports['feather-core']:TranslateLocale(source, key, ...)
        return type(result) == 'table' and result.ok == true and result.value
            or ('Translation [%s] is unavailable'):format(tostring(key))
    end
}

-- Transitional server adapter: existing Inventory call sites retain their
-- local Notify shape while delivery crosses Core's Contract 1 boundary.
-- Client notifications are separate and remain unchanged.
local contractNotify = {}

contractNotify.RightNotify = function(source, message, duration)
    local result = exports['feather-core']:SendNotification({
        source = source,
        style = 'right',
        message = message,
        duration = duration
    })
    if type(result) ~= 'table' or result.ok ~= true then
        print(('[feather-inventory] notification failed source=%s code=%s'):format(
            tostring(source), tostring(type(result) == 'table' and result.code or 'invalid_result')))
    end
    return result
end

Feather.Notify = contractNotify

if Config.DevMode then
    RegisterCommand('InvNotificationSmokeTest', function(source, args)
        if source ~= 0 then return end
        local target = tonumber(args and args[1])
        local result = target and Feather.Notify.RightNotify(target,
            'Feather Inventory notification contract is working.', 3000) or nil
        local passed = type(result) == 'table' and result.ok == true
        print(('[InvNotificationSmokeTest] contract delivery       %s%s'):format(
            passed and 'PASS' or 'FAIL', target and ('  -- source=' .. tostring(target)) or '  -- target required'))
        print(('[InvNotificationSmokeTest] done %d/1 passed'):format(passed and 1 or 0))
    end, true)
end

if Config.DevMode then
    RegisterCommand('InvServerCoreCutoverSmokeTest', function(source, args)
        if source ~= 0 then return end
        local ownerSource = tonumber(args and args[1])
        local playerSource = tonumber(args and args[2])
        local owner = ownerSource and exports['feather-core']:Authorize('inventory.manage', { source = ownerSource }) or nil
        local player = playerSource and exports['feather-core']:Authorize('inventory.manage', { source = playerSource }) or nil
        local function Detail(result)
            if type(result) ~= 'table' then return 'result=' .. type(result) end
            local encoded = json.encode(result)
            return type(encoded) == 'string' and encoded or 'result=unencodable'
        end
        local tests = {
            { name = 'legacy character absent', passed = Feather.Character == nil },
            { name = 'owner policy allowed', passed = owner and owner.ok == true and owner.value.allowed == true,
                detail = Detail(owner) },
            { name = 'player policy denied', passed = player and player.ok == true and player.value.allowed == false,
                detail = Detail(player) }
        }
        local passed = 0
        for _, test in ipairs(tests) do
            if test.passed then passed = passed + 1 end
            print(('[InvServerCoreCutoverSmokeTest] %-25s %s%s'):format(
                test.name, test.passed and 'PASS' or 'FAIL',
                not test.passed and test.detail and ('  -- ' .. test.detail) or ''))
        end
        print(('[InvServerCoreCutoverSmokeTest] done %d/%d passed owner=%s player=%s'):format(
            passed, #tests, tostring(ownerSource), tostring(playerSource)))
    end, true)
end
