RegisterNUICallback('CloseUI', function(data, cb)
  -- Check if other invetory was ground
  -- Clear Ped Tasks
  -- Remove NUI Focus
  -- Toggle isInvOpen

  -- Check if near stash
  -- Save Stash
  -- Else
  -- Save Dropped Item Stash
end)

RegisterNUICallback('UseItem', function(data, cb)
  CreateThread(function()
    local res = Feather.RPC.CallAsync('Inventory:UseItem', data)

    cb(res)
  end)
end)

RegisterNUICallback('UpdateInventory', function(data, cb)
  CreateThread(function()
    local res = Feather.RPC.CallAsync('Inventory:UpdateInventory', data)

    cb(res)
  end)
end)

RegisterNUICallback('GiveItem', function(data, cb)
  -- Find closest player. Needs to be added to Core
  if data.sourceInventoryType ~= 'player' then
    -- Notify Error
    cb(false)
  end

  CreateThread(function()
    local res = Feather.RPC.CallAsync('Inventory:GiveItem', data)
    cb(res)
  end)
end)
