-- Bridges the inventory NUI's actions to the server RPCs that actually
-- perform them. Every callback here just forwards whatever the NUI sends
-- to the matching server/services/callbacks.lua RPC and relays the
-- response back -- the NUI itself is untrusted input (see MENU-01-style
-- reasoning); the real validation lives server-side.
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
  if not ped or tonumber(ped) == 0 then
    cb({ error = true, message = 'No one is close enough in front of you.' })
    return
  end

  local target = GetPlayerFromPed(ped)
  if target == -1 then
    cb({ error = true, message = 'That is not a player.' })
    return
  end

  local data = {
    target = target,
    item = args.item
  }

  -- (INV-06) Used to call 'Inventory:GiveItem', which the server never
  -- registered under that name (see callbacks.lua) -- GiveItem silently
  -- never reached the server via this NUI path. Fixed to call the RPC the
  -- server actually registers.
  --
  -- The response shape used to be a bare 'ok'/'error' string, which the
  -- NUI side never actually inspected -- a rejected give (no target, too
  -- far, can't hold it) surfaced nothing at all. Normalized to the same
  -- { error, message } shape DropItems already uses, so the UI has
  -- something to show.
  local result = Feather.RPC.CallAsync('Feather:Inventory:GiveItem', data)
  if not result or result.error then
    cb({ error = true, message = (result and result.message) or 'Unable to give item.' })
  else
    cb({ error = false, sourceItems = result.sourceItems })
  end
end)

RegisterNUICallback('Feather:Inventory:DropItems', function(args, cb)
  cb(DropItemsOnGround(args.items))
end)

RegisterNUICallback('Feather:Inventory:MoveItem', function(args, cb)
  local res = Feather.RPC.CallAsync('Feather:Inventory:MoveItem', args)

  cb(res)
end)