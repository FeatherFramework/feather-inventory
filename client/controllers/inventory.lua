local isInvOpen = false
-- local isHBOpen = false

InventoryAction = {}

function CanOpenInventory()
  if IsEntityDead(PlayerPedId()) then return false end
  if IsPauseMenuActive() then return false end
  -- TODO: Add check for different states where inventory can't open like Handcuffed/HogTied/KnockedOut
  return true
end

InventoryAction.Open = function(otherInventoryId, target)
  if target == nil then
    target = "storage"
  end

  print('Opening Inventory', otherInventoryId or 'character')
  if not isInvOpen and CanOpenInventory() then
    local results = Feather.RPC.CallAsync('Feather:Inventory:GetInventoryItems', { otherInventoryId = otherInventoryId })
    if results.error ~= nil then
      Feather.Notify.RightNotify(results.error, 3000)
      return
    end

    isInvOpen = true

    local player_display = Feather.RPC.CallAsync('Feather:Inventory:GetCharacterInfoForDisplay')
    
    SendNUIMessage({
      type = "toggleInventory",
      target = target,
      visible = true,
      playerInventory = results.inventory,
      playerItems = results.inventoryItems,
      playerIgnoreLimits = results.inventoryIgnoreLimits or 0,
      otherInventory = results.otherInventory,
      otherItems = results.otherInventoryItems,
      otherIgnoreLimits = results.otherInventoryIgnoreLimits,
      otherName = results.otherName,
      maxWeight = Config.maxWeight,
      maxSlots = Config.maxItemSlots, -- TODO: Make this customizable
      categories = Feather.RPC.CallAsync('Feather:Inventory:GetCategories', {}),
      player = {
        dollars = player_display.dollars,
        gold = player_display.gold,
        tokens = player_display.tokens,
        id = player_display.id
      }
    })
    SetNuiFocus(true, true)
  end
end

InventoryAction.Close = function()
  if isInvOpen then
    SetNuiFocus(false, false)
    isInvOpen = false

    Feather.RPC.CallAsync('Feather:Inventory:Server:CloseInventory', {})
  end
end

RegisterNetEvent('Feather:Inventory:OpenInventory', function(otherInventoryId, target)
  InventoryAction.Open(otherInventoryId, target)
end)

RegisterNetEvent('Feather:Inventory:CloseInventory', function()
  InventoryAction.Close()
end)

-- function IsHotbarOpen()
--   return isHBOpen
-- end

-- function ToggleHotbar()
--   isHBOpen = not isHBOpen
--   ToggleHotbarDisplay(isHBOpen)
-- end
