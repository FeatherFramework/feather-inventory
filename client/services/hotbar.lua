local PREFERENCE_KEY = 'hotbar_visibility'
local SETTINGS_CHOICE_ID = 'feather-inventory:hotbar-visibility'
local OPACITY_PREFERENCE_KEY = 'hotbar_opacity'
local SETTINGS_OPACITY_ID = 'feather-inventory:hotbar-opacity'
local SETTINGS_VISIBILITY_EVENT = 'Feather:Inventory:Settings:SetHotbarVisibility'
local SETTINGS_OPACITY_EVENT = 'Feather:Inventory:Settings:SetHotbarOpacity'
local VALID_VISIBILITY = { Temporary=true, Always=true }
local HotbarBindings = { enabled=false, slots=0, bindings={} }
local temporaryGeneration = 0
local settingsRegistrationGeneration = 0
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

local function GetOpacity()
    local saved = tonumber(GetResourceKvpString(OPACITY_PREFERENCE_KEY))
    local configured = tonumber(Config.Hotbar and Config.Hotbar.DefaultOpacity) or 90
    return math.max(50, math.min(100, math.floor(saved or configured)))
end

local function SetOpacity(value)
    if not GetPolicy().enabled then return false end
    local numeric = tonumber(value)
    if not numeric then return false end
    numeric = math.max(50, math.min(100, math.floor((numeric + 2.5) / 5) * 5))
    SetResourceKvp(OPACITY_PREFERENCE_KEY, tostring(numeric))
    TriggerEvent('Feather:Inventory:HotbarVisibilityChanged', GetPreference())
    return true
end

exports('GetHotbarPolicy', GetPolicy)
exports('GetHotbarVisibility', GetPreference)
exports('SetHotbarVisibility', SetPreference)
exports('GetHotbarOpacity', GetOpacity)
exports('SetHotbarOpacity', SetOpacity)

AddEventHandler(SETTINGS_VISIBILITY_EVENT, function(value)
    SetPreference(value)
end)

AddEventHandler(SETTINGS_OPACITY_EVENT, function(value)
    SetOpacity(value)
end)

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
        opacity = GetOpacity(),
        modifier = string.upper(tostring(Config.Hotbar.Modifier or 'SHIFT')),
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
    if GetResourceState('feather-settings') ~= 'started' then return 'retry' end

    -- Visibility policy is resource configuration, so it cannot change until
    -- Inventory restarts. Register the provider only for UserDefined instead
    -- of passing an isVisible function across the CFX resource boundary. A
    -- failed cross-resource callback was interpreted by Settings as false and
    -- silently hid an otherwise valid provider.
    if not GetPolicy().userCanChoose then
        pcall(function()
            exports['feather-settings']:UnregisterChoice(SETTINGS_CHOICE_ID, GetCurrentResourceName())
        end)
    else
        local ok, registered, rejectionReason = pcall(function()
            return exports['feather-settings']:RegisterChoice({
            id = SETTINGS_CHOICE_ID,
            ownerResource = GetCurrentResourceName(),
            label = Translate('ui_hotbar_visibility', 'Hotbar Visibility'),
            control = 'arrows',
            options = {
                { value='Temporary', label=Translate('ui_hotbar_temporary', 'Temporary') },
                { value='Always', label=Translate('ui_hotbar_always', 'Always') },
            },
            initialValue = GetPreference(),
            setEvent = SETTINGS_VISIBILITY_EVENT,
            })
        end)
        if not ok or registered ~= true then
            print(('[feather-inventory] hotbar Settings choice registration failed: %s')
                :format(ok and tostring(rejectionReason or 'provider rejected') or tostring(registered)))
            return 'rejected'
        end
    end

    local opacityOk, opacityRegistered, opacityReason = pcall(function()
        return exports['feather-settings']:RegisterChoice({
            id = SETTINGS_OPACITY_ID,
            ownerResource = GetCurrentResourceName(),
            label = Translate('ui_hotbar_opacity', 'Hotbar Opacity'),
            control = 'slider',
            min = 50,
            max = 100,
            step = 5,
            initialValue = GetOpacity(),
            setEvent = SETTINGS_OPACITY_EVENT,
        })
    end)
    if not opacityOk or opacityRegistered ~= true then
        print(('[feather-inventory] hotbar opacity Settings registration failed: %s')
            :format(opacityOk and tostring(opacityReason or 'provider rejected') or tostring(opacityRegistered)))
        return 'rejected'
    end
    return 'done'
end

local function ScheduleSettingsRegistration()
    settingsRegistrationGeneration = settingsRegistrationGeneration + 1
    local generation = settingsRegistrationGeneration
    CreateThread(function()
        -- Settings is optional and commonly starts after Inventory. Its client
        -- start event may arrive while GetResourceState still says `starting`,
        -- so keep retrying until it is fully started and accepts the provider.
        while generation == settingsRegistrationGeneration do
            local outcome = RegisterSettingsChoice()
            if outcome == 'done' or outcome == 'rejected' then return end
            Wait(250)
        end
    end)
end

ScheduleSettingsRegistration()

AddEventHandler('onClientResourceStart', function(resourceName)
    if resourceName == 'feather-settings' then ScheduleSettingsRegistration() end
end)

AddEventHandler('onClientResourceStop', function(resourceName)
    if resourceName == 'feather-settings' then
        settingsRegistrationGeneration = settingsRegistrationGeneration + 1
    end
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
    pcall(function()
        exports['feather-settings']:UnregisterChoice(SETTINGS_CHOICE_ID, GetCurrentResourceName())
        exports['feather-settings']:UnregisterChoice(SETTINGS_OPACITY_ID, GetCurrentResourceName())
    end)
end)
