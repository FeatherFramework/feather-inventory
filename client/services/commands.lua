
RegisterNetEvent("Feather:Character:Spawned", function()
  Feather.Keys:RegisterListener(Config.hotkey, function()
    print("CLICKED!")
    InventoryAction.Open(nil, "player")
  end)
end)

-- Feather.Keys:RegisterListener(Config.hotkey, function()
--   print("CLICKED!")
--   if InventoryHotkeyEnabled == true then
--     InventoryAction.Open(nil, "player")
--   end
-- end)

RegisterCommand('open_inventory', function()
  InventoryAction.Open(nil, "player")
end, false)

RegisterCommand('close_inventory', function()
  InventoryAction.Close()
end, false)


RegisterCommand('open_storage', function()
  InventoryAction.Open('5ab95e93-c590-11ee-a5cf-40b07640984b')
end, false)

-- RegisterCommand('toggle_hotbar', function()
--   if CanOpenInventory() then
--     ToggleHotbar()
--   end
-- end, false)
