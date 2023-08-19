local isInvOpen = false
local isHBOpen = false

function OpenInventory()
  isInvOpen = true
  OpenUI()
end

function CloseInventory()
  isInvOpen = false
  CloseUI()
end

function IsInventoryOpen()
  return isInvOpen
end

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
