RegisterCommand('open_inventory', function()
  TriggerEvent('Feather:Inventory:OpenInventory', nil)
end, false)

RegisterCommand('open_storage', function()
  TriggerEvent('Feather:Inventory:OpenInventory', '5ab95e93-c590-11ee-a5cf-40b07640984b')
end, false)

RegisterCommand('close_inventory', function()
  TriggerEvent('Feather:Inventory:CloseInventory')
end, false)

-- RegisterCommand('toggle_hotbar', function()
--   if CanOpenInventory() then
--     ToggleHotbar()
--   end
-- end, false)
