local registered = false
local function register()
    if registered or GetResourceState('feather-chat') ~= 'started' then return end
    local health = exports['feather-chat']:GetHealth()
    if not health.ok or health.value.state ~= 'ready' then return end
    for _, definition in ipairs({
        { key='feather-inventory.open', trigger='/open_inventory', description='Open your inventory' },
        { key='feather-inventory.close', trigger='/close_inventory', description='Close your inventory' }
    }) do
        local result = exports['feather-chat']:RegisterSuggestion(definition)
        if not result.ok and result.code ~= 'conflict' then
            print('[feather-inventory] chat suggestion registration failed code=' .. tostring(result.code)); return
        end
    end
    registered = true
end
AddEventHandler('chat.ready.v1', register)
AddEventHandler('onResourceStop', function(resource) if resource == 'feather-chat' then registered = false end end)
CreateThread(register)
