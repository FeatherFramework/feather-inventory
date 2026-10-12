
-- The inventory hotkey is registered immediately in DevMode (so it works
-- before a character has even spawned, for quicker testing), otherwise it
-- waits for Feather:Character:Spawned so the key does nothing until there's
-- an actual character/inventory to open.
local function MenuInputCaptured()
  if GetResourceState('feather-menu-v2') ~= 'started' then return false end
  local ok, captured = pcall(function()
    return exports['feather-menu-v2']:IsInputCaptured()
  end)
  return ok and captured == true
end

InventoryCharacterActive = Config.DevMode == true
local inventoryKeyListener

local function EnsureInventoryKeyListener()
  if inventoryKeyListener then return end
  inventoryKeyListener = Feather.Keys:RegisterListener(Config.hotkey, function()
    if InventoryCharacterActive and not MenuInputCaptured() then
      InventoryAction.Open(nil, "player")
    end
  end)
end

if Config.DevMode then
  EnsureInventoryKeyListener()
end
-- DevMode may register the key early, but must never bypass lifecycle cleanup.
RegisterNetEvent("Feather:Character:Spawned", function()
  InventoryCharacterActive = true
  EnsureInventoryKeyListener()
end)
AddEventHandler('Feather:Character:Logout', function()
  InventoryCharacterActive = false
  InventoryAction.Close(true)
end)
AddEventHandler('feather-medical:client:condition-changed.v1', function(condition)
  if type(condition)=='table' and (condition.lifeState=='dead' or condition.lifeState=='incapacitated') then
    InventoryAction.Close(true)
  end
end)
AddEventHandler('onResourceStop', function(resourceName)
  if resourceName == GetCurrentResourceName() or resourceName == 'feather-character' then
    InventoryCharacterActive = false
    -- Clear focus/UI immediately; do not make an RPC through a stopping owner
    -- or imply that pending server economic work was rolled back.
    InventoryAction.Close(true, true)
  elseif resourceName == 'feather-weapons' then
    -- Other Inventory actions remain usable; only the provider-owned ammo
    -- panel and its pending presentation responses are invalidated.
    SendNUIMessage({ type = 'ammoPanelInvalidated' })
  end
end)


RegisterCommand('open_inventory', function()
  if InventoryCharacterActive then InventoryAction.Open(nil, "player") end
end, false)

RegisterCommand('close_inventory', function()
  InventoryAction.Close()
end, false)

if Config.DevMode then
  RegisterCommand('open_storage', function()
    InventoryAction.Open('dde04bd6-34cc-11ef-a92d-107c61489014')
  end, false)
end

-- RegisterCommand('toggle_hotbar', function()
--   if CanOpenInventory() then
--     ToggleHotbar()
--   end
-- end, false)
