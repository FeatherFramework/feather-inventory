local isInvOpen = false
local isHBOpen = false

RegisterNetEvent('Feather:Inventory:OpenInventory', function(otherInventoryId)
  print('Opening Inventory')
  if not isInvOpen and CanOpenInventory() then
    print('Inventory is not open and you can open it')
    isInvOpen = true

    local results = Feather.RPC.CallAsync('Feather:Inventory:GetInventoryItems', { otherInventoryId = otherInventoryId })

    SendNUIMessage({
      type = "toggleInventory",
      visible = true,
      playerInventory = results.inventory,
      playerItems = results.inventoryItems,
      otherInventory = results.otherInventory,
      otherItems = results.otherInventoryItems,
      maxWeight = Config.maxWeight,
      maxSlots = Config.maxItemSlots,
    })
    SetNuiFocus(true, true)
  end
end)

RegisterNetEvent('Feather:Inventory:CloseInventory', function()
  if isInvOpen then
    SendNUIMessage({
      type = "toggleInventory",
      visible = false,
    })
    SetNuiFocus(false, false)
    isInvOpen = false
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
