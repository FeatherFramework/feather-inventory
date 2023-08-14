local isInvOpen = false
local isHBOpen = false

function OpenInventory()
  isInvOpen = true
end

function CloseInventory()
  isInvOpen = false
end

function IsInventoryOpen()
  return isInvOpen
end

function IsHotbarOpen()
  return isHBOpen
end

function ToggleHotbar()
  isHBOpen = not isHBOpen
  ToggleHotbarDisplay(isHBOpen)
end

function CanOpenInventory()
  if IsEntityDead(PlayerPedId()) then return false end
  if IsPauseMenuActive() then return false end
  -- Add check for different states where inventory can't open like Handcuffed/HogTied/KnockedOut

  return true
end

function GetPlayerItems()
  return {}
end

function IsTable(var)
  return type(var) == 'table'
end

function IsArray(t)
  local i = 0
  for _ in pairs(t) do
    i = i + 1
    if t[i] == nil then return false end
  end
  return true
end
