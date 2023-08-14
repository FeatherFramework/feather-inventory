RegisterCommand('close_inventory', function()
  CloseInventory()
end, false)

RegisterCommand('open_inventory', function()
  if not IsInventoryOpen() and CanOpenInventory() then
    PlayOpenAnimation()
    OpenInventory()
  end
end, false)

RegisterCommand('toggle_hotbar', function()
  if CanOpenInventory() then
    ToggleHotbar()
  end
end, false)

for itemSlot = 1, Config.hotbarLimit do
  RegisterCommand('slot' .. itemSlot, function()
    if CanOpenInventory() then
      if itemSlot == Config.hotbarLimit then
        itemSlot = Config.maxItemSlots
      end
      Feather.RPC.Call('Inventory:UseItem', { ['itemSlot'] = itemSlot })
    end
  end, false)
end
