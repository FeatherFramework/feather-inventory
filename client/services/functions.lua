local isInvOpen = false
local isHBOpen = false

function OpenInventory(src)
  isInvOpen = true
end

function CloseInventory(src)
  isInvOpen = false
end

function isInventoryOpen()
  return isInvOpen
end

function isHotbarOpen()
  return isHBOpen
end

function ToggleHotbar()
  isHBOpen = not isHBOpen
  ToggleHotbarDisplay(isHBOpen)
end

function canOpenInventory(src)
  if IsEntityDead(PlayerPedId()) then return false end
  if IsPauseMenuActive() then return false end
  -- Add check for different states where inventory can't open like Handcuffed/HogTied/KnockedOut

  return true
end

function GetPlayerItems()
  return {}
end
