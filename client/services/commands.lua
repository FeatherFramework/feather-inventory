
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

if Config.DevMode then
  Feather.Keys:RegisterListener(Config.hotkey, function()
    if not MenuInputCaptured() then InventoryAction.Open(nil, "player") end
  end)
else
  RegisterNetEvent("Feather:Character:Spawned", function()
    Feather.Keys:RegisterListener(Config.hotkey, function()
      if not MenuInputCaptured() then InventoryAction.Open(nil, "player") end
    end)
  end)
end


RegisterCommand('open_inventory', function()
  InventoryAction.Open(nil, "player")
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
