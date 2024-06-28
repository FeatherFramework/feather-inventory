
if Config.DevMode then
  Feather.Keys:RegisterListener(Config.hotkey, function()
    InventoryAction.Open(nil, "player")
  end)
else
  RegisterNetEvent("Feather:Character:Spawned", function()
    Feather.Keys:RegisterListener(Config.hotkey, function()
      InventoryAction.Open(nil, "player")
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
