local isInvOpen = false
local isHBOpen = false

RegisterNetEvent('Feather:Inventory:OpenInventory', function(otherInventoryId)
  print('Opening Inventory', otherInventoryId or 'character')
  if not isInvOpen and CanOpenInventory() then
    print('Inventory is not open and you can open it')
    isInvOpen = true

    local results = Feather.RPC.CallAsync('Feather:Inventory:GetInventoryItems', { otherInventoryId = otherInventoryId })
    
    SendNUIMessage({
      type = "toggleInventory",
      visible = true,
      playerInventory = results.inventory,
      playerItems = results.inventoryItems,
      playerIgnoreLimits = results.inventoryIgnoreLimits or 0,
      otherInventory = results.otherInventory,
      otherItems = results.otherInventoryItems,
      otherIgnoreLimits = results.otherInventoryIgnoreLimits,
      maxWeight = Config.maxWeight,
      maxSlots = Config.maxItemSlots,
      categories = Feather.RPC.CallAsync('Feather:Inventory:GetCategories', {})
    })
    SetNuiFocus(true, true)
  end
end)

RegisterNetEvent('Feather:Inventory:CloseInventory', function()
  if isInvOpen then
    SetNuiFocus(false, false)
    isInvOpen = false

    Feather.RPC.CallAsync('Feather:Inventory:Server:CloseInventory', {})
  end
end)

-- function IsHotbarOpen()
--   return isHBOpen
-- end

-- function ToggleHotbar()
--   isHBOpen = not isHBOpen
--   ToggleHotbarDisplay(isHBOpen)
-- end

function CanOpenInventory()
  if IsEntityDead(PlayerPedId()) then return false end
  if IsPauseMenuActive() then return false end
  -- Add check for different states where inventory can't open like Handcuffed/HogTied/KnockedOut
  return true
end
