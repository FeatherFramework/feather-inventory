RegisterCommand('open_inventory', function()
  if not IsInventoryOpen() and CanOpenInventory() then
    PlayOpenAnimation()
    OpenInventory()
  end
end, false)

RegisterCommand('close_inventory', function()
  CloseInventory()
end, false)

-- RegisterCommand('toggle_hotbar', function()
--   if CanOpenInventory() then
--     ToggleHotbar()
--   end
-- end, false)
