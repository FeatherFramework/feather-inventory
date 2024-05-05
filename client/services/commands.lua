
if Config.DevMode then
  Feather.KeyCodes:RegisterListener(Config.hotkey, function()
    InventoryAction.Open(nil, "player")
  end)
else
  RegisterNetEvent("Feather:Character:Spawned", function()
    Feather.KeyCodes:RegisterListener(Config.hotkey, function()
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
    InventoryAction.Open('5ab95e93-c590-11ee-a5cf-40b07640984b')
  end, false)
end


-- RegisterCommand('toggle_hotbar', function()
--   if CanOpenInventory() then
--     ToggleHotbar()
--   end
-- end, false)
