RegisterCommand('open_inventory', function()
  TriggerEvent('Feather:Inventory:OpenInventory', nil)
end, false)

RegisterCommand('close_inventory', function()
  TriggerEvent('Feather:Inventory:CloseInventory')
end, false)

-- RegisterCommand('toggle_hotbar', function()
--   if CanOpenInventory() then
--     ToggleHotbar()
--   end
-- end, false)
