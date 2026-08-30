local PREFERENCE_KEY = 'hotbar_visibility'
local SETTINGS_CHOICE_ID = 'feather-inventory:hotbar-visibility'
local VALID_VISIBILITY = { Temporary=true, Always=true }
local HotbarBindings = { enabled=false, slots=0, bindings={} }
local temporaryGeneration = 0
local paused = false

local function NormalizePolicy(value)
    if value == 'Temporary' or value == 'Always' or value == 'UserDefined' then return value end
    return 'Temporary'
end

local function DefaultPreference()
    local configured = Config.Hotbar and Config.Hotbar.DefaultVisibility
    return VALID_VISIBILITY[configured] and configured or 'Temporary'
end

local function GetPreference()
    local saved = GetResourceKvpString(PREFERENCE_KEY)
    return VALID_VISIBILITY[saved] and saved or DefaultPreference()
end

local function GetPolicy()
    local enabled = Config.Hotbar and Config.Hotbar.Enabled == true
    local visibility = NormalizePolicy(Config.Hotbar and Config.Hotbar.Visibility)
    local preference = GetPreference()
    return {
        enabled = enabled,
        visibility = visibility,
        userCanChoose = enabled and visibility == 'UserDefined',
        preference = preference,
        effectiveVisibility = visibility == 'UserDefined' and preference or visibility,
    }
end

local function SetPreference(value)
    local policy = GetPolicy()
    if not policy.userCanChoose or not VALID_VISIBILITY[value] then return false end
    SetResourceKvp(PREFERENCE_KEY, value)
    TriggerEvent('Feather:Inventory:HotbarVisibilityChanged', value)
    return true
end

exports('GetHotbarPolicy', GetPolicy)
exports('GetHotbarVisibility', GetPreference)
exports('SetHotbarVisibility', SetPreference)

local function SendHotbar(showTemporary)
    local policy = GetPolicy()
    local visible = policy.enabled and not paused
        and (policy.effectiveVisibility == 'Always' or showTemporary == true)
    SendNUIMessage({
        type = 'hotbar',
        enabled = policy.enabled and HotbarBindings.enabled == true,
        visible = visible,
        slots = HotbarBindings.slots,
        bindings = HotbarBindings.bindings,
    })
end

function ApplyHotbarPayload(payload, showTemporary)
    if type(payload) == 'table' then HotbarBindings = payload end
    SendHotbar(showTemporary)
end

local function ShowTemporary()
    local policy = GetPolicy()
    if policy.effectiveVisibility ~= 'Temporary' then return SendHotbar(false) end
    temporaryGeneration = temporaryGeneration + 1
    local generation = temporaryGeneration
    SendHotbar(true)
    SetTimeout(math.max(250, tonumber(Config.Hotbar.TemporaryDuration) or 4000), function()
        if temporaryGeneration == generation then SendHotbar(false) end
    end)
end

local function RefreshBindings(showTemporary)
    if not GetPolicy().enabled then
        HotbarBindings = { enabled=false, slots=0, bindings={} }
        return SendHotbar(false)
    end
    local result = Feather.RPC.CallAsync('Feather:Inventory:Hotbar:Get', {})
    if result and not result.error and result.value then
        HotbarBindings = result.value
        if showTemporary then ShowTemporary() else SendHotbar(false) end
    end
end

local function UseSlot(slot)
    ShowTemporary()
    local result = Feather.RPC.CallAsync('Feather:Inventory:Hotbar:Use', { slot=slot })
    if result and result.value then HotbarBindings = result.value end
    if not result or result.error then
        local code = result and result.code or ''
        local message = result and result.message or 'That hotbar item could not be used.'
        Feather.Notify.RightNotify(Translate('err_' .. tostring(code), message), 3000)
    end
    ShowTemporary()
end

local function RegisterSettingsChoice()
    if GetResourceState('feather-settings') ~= 'started' then return false end

    local ok, registered = pcall(function()
        return exports['feather-settings']:RegisterChoice({
            id = SETTINGS_CHOICE_ID,
            label = Translate('ui_hotbar_visibility', 'Hotbar Visibility'),
            options = {
                { value='Temporary', label=Translate('ui_hotbar_temporary', 'Temporary') },
                { value='Always', label=Translate('ui_hotbar_always', 'Always') },
            },
            isVisible = function() return GetPolicy().userCanChoose end,
            getValue = GetPreference,
            setValue = SetPreference,
        })
    end)
    return ok and registered == true
end

CreateThread(function()
    -- Settings is intentionally optional. Wait briefly for ordinary startup
    -- ordering, then stop; onClientResourceStart below handles later restarts.
    for _ = 1, 100 do
        if RegisterSettingsChoice() then return end
        Wait(100)
    end
end)

AddEventHandler('onClientResourceStart', function(resourceName)
    if resourceName == 'feather-settings' then RegisterSettingsChoice() end
end)

RegisterNetEvent('Feather:Character:Spawned', function()
    RefreshBindings(false)
end)

RegisterNetEvent('Feather:Inventory:HotbarRefresh', function()
    RefreshBindings(true)
end)

AddEventHandler('Feather:Inventory:HotbarRefreshAfterInventory', function()
    RefreshBindings(false)
end)

AddEventHandler('Feather:Inventory:HotbarVisibilityChanged', function()
    SendHotbar(false)
end)

CreateThread(function()
    while true do
        Wait(0)
        local policy = GetPolicy()
        local nowPaused = IsPauseMenuActive()
        if nowPaused ~= paused then
            paused = nowPaused
            SendHotbar(false)
        end

        if policy.enabled and not nowPaused then
            local modifierHash = Feather.KeyCodes[Config.Hotbar.Modifier or 'SHIFT']
            local modifierHeld = modifierHash and IsControlPressed(0, modifierHash)
            if modifierHeld then
                for slot = 1, math.min(tonumber(Config.Hotbar.Slots) or 6, 8) do
                    local keyHash = Feather.KeyCodes[tostring(slot)]
                    if keyHash then
                        -- Prevent RedM's own plain-number weapon hotbar from
                        -- firing underneath the Shift+number inventory chord.
                        DisableControlAction(0, keyHash, true)
                        if Citizen.InvokeNative(0x91AEF906BCA88877, 0, keyHash) then
                            UseSlot(slot)
                        end
                    end
                end
            end
        end
    end
end)

CreateThread(function()
    Wait(1000)
    RefreshBindings(false)
end)

AddEventHandler('onClientResourceStop', function(resourceName)
    if resourceName ~= GetCurrentResourceName()
        or GetResourceState('feather-settings') ~= 'started' then return end
    pcall(function() exports['feather-settings']:UnregisterChoice(SETTINGS_CHOICE_ID) end)
end)
