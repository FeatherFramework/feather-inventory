RegisterNUICallback('Feather:Inventory:NuiCloseInventory', function(args, cb)
  cb('ok')
  TriggerEvent('Feather:Inventory:CloseInventory')
end)

RegisterNUICallback('Feather:Inventory:UseItem', function(args, cb)
  local res = Feather.RPC.CallAsync('Feather:Inventory:UseItem', args)

  cb(res)
end)

RegisterNUICallback('Feather:Inventory:UpdateInventory', function(args, cb)
  -- TODO: Test what happens if two players open an inventory at the same time. (OR add system to lock the ability to open an inventory if someone else has it open)

  local data = {
    sourceInventory = args.sourceInventory,
    targetInventory = args.targetInventory,
    items = args.items
  }

  local result = Feather.RPC.CallAsync('Feather:Inventory:UpdateInventory', data)

  cb({
    sourceItems = result.sourceItems,
    targetItems = result.targetItems
  })
end)

RegisterNUICallback('Feather:Inventory:GiveItem', function(args, cb)
  local ped = GetPedInFront()
  if ped == 0 then
    cb({ status = 'error', message = 'Unable to find player' })
    return
  end

  local data = {
    target = GetPlayerFromPed(ped),
    item = args.item
  }

  Feather.RPC.CallAsync('Inventory:GiveItem', data)
  cb('ok')
end)

RegisterNUICallback('Feather:Inventory:DropItems', function(args, cb)
  cb(DropItemsOnGround(args.items))
end)