-- Bridges the inventory NUI's actions to the server RPCs that actually
-- perform them. Every callback here just forwards whatever the NUI sends
-- to the matching server/services/callbacks.lua RPC and relays the
-- response back -- the NUI itself is untrusted input (see MENU-01-style
-- reasoning); the real validation lives server-side.
local function CallTimedMutation(name, args)
  local started = GetGameTimer()
  local result = Feather.RPC.CallAsync(name, args)
  if result and type(result.mutationTiming) == 'table' then
    result.mutationTiming.clientRpcMs = (GetGameTimer() - started) % 4294967296
  end
  return result
end

RegisterNUICallback('Feather:Inventory:NuiCloseInventory', function(args, cb)
  cb('ok')
  TriggerEvent('Feather:Inventory:CloseInventory')
end)

RegisterNUICallback('Feather:Inventory:UseItem', function(args, cb)
  local res = Feather.RPC.CallAsync('Feather:Inventory:UseItem', args)

  cb(res)
end)

-- UI supplies intent only; Weapons' existing server-authorized transfer owns
-- inventory conservation, lifecycle validation and exact native restore ack.
local function NativeAmmoCall(method,...)
  if Config.CharacterAmmunitionEnabled~=true or GetResourceState('feather-weapons')~='started' then
    return {ok=false,error={code='native_ammunition_disabled'},message='Native ammunition controls are unavailable.'}
  end
  local called,result=pcall(method,...)
  if not called or type(result)~='table' then
    return {ok=false,error={code='ammunition_action_unavailable'},message='Ammunition action unavailable; do not retry an uncertain transfer.'}
  end
  return result
end
local function AmmoPreview(itemId)
  local inventory=Feather.RPC.CallAsync('Feather:Inventory:NativeAmmoInventory',{})
  if type(inventory)~='table' or inventory.ok~=true then return inventory or {ok=false,error={code='ammunition_preview_unavailable'}} end
  local selected,counts=nil,{}
  for _,item in ipairs(inventory.value.items or {}) do
    counts[item.name]=(counts[item.name] or 0)+1
    if tonumber(item.id)==tonumber(itemId) then selected=item.name end
  end
  if itemId~=nil and not selected then return {ok=false,error={code='ammunition_item_not_owned'}} end
  local controls=exports['feather-weapons']:GetNativeAmmunitionControls(selected)
  if controls.ok~=true then return controls end
  if controls.value.characterId~=inventory.value.characterId or controls.value.sessionId~=inventory.value.sessionId then
    return {ok=false,error={code='ammunition_preview_context_changed'}}
  end
  for _,option in ipairs(controls.value.options) do option.loose=counts[option.itemName] or 0 end
  return controls
end
RegisterNUICallback('Feather:Inventory:NativeAmmoOptions',function(args,cb)
  cb(NativeAmmoCall(function() return AmmoPreview(type(args)=='table' and args.itemId or nil) end))
end)
local ammoTransferBusy=false
local equipmentBusy=false
local function EquipmentCall(method,args,cb)
  if equipmentBusy then return cb({ok=false,error={code='equipment_action_in_flight'}}) end
  equipmentBusy=true
  local result=NativeAmmoCall(function()
    if type(args)~='table' then return {ok=false,error={code='invalid_equipment_request'}} end
    if method=='options' then return exports['feather-weapons']:GetNativeEquipmentControls(args.itemId) end
    return exports['feather-weapons']:ChangeNativeEquipment(args.itemId,args.action,args.slot,args.scope)
  end)
  equipmentBusy=false
  cb(result)
end
RegisterNUICallback('Feather:Inventory:NativeEquipmentOptions',function(args,cb) EquipmentCall('options',args,cb) end)
RegisterNUICallback('Feather:Inventory:NativeEquipmentChange',function(args,cb) EquipmentCall('change',args,cb) end)
RegisterNUICallback('Feather:Inventory:NativeAmmoTransfer',function(args,cb)
  args=type(args)=='table' and args or {}
  if ammoTransferBusy then return cb({ok=false,dispatched=false,error={code='ammunition_action_in_flight'}}) end
  ammoTransferBusy=true -- reserve before the preview RPC yields
  local result=NativeAmmoCall(function()
    if type(args.quantity)~='number' or args.quantity%1~=0 or args.quantity<1 or args.quantity>1000
      or type(args.ammunitionId)~='string' or (args.direction~='load' and args.direction~='unload') then
      return {ok=false,dispatched=false,error={code='invalid_ammunition_action'}}
    end
    local preview=AmmoPreview()
    if preview.ok~=true then preview.dispatched=false; return preview end
    local scope=args.scope
    if type(scope)~='table' or type(scope.epoch)~='string' or scope.epoch==''
      or scope.characterId~=preview.value.characterId or scope.sessionId~=preview.value.sessionId
      or scope.epoch~=preview.value.epoch then
      return {ok=false,dispatched=false,error={code='ammunition_panel_expired_reopen'},
        message='This ammunition panel expired. Close it and open it again.'}
    end
    local expected={characterId=scope.characterId,sessionId=scope.sessionId,epoch=scope.epoch}
    local selected
    for _,option in ipairs(preview.value.options) do if option.id==args.ammunitionId then selected=option end end
    local available=selected and (args.direction=='load' and selected.loose or selected.carried)
    if type(available)~='number' or args.quantity>available then
      return {ok=false,dispatched=false,error={code='ammunition_availability_changed'},
        message='Available rounds changed. Nothing was transferred.',value={options=preview.value.options}}
    end
    local result=exports['feather-weapons']:TransferNativeAmmunition(args.ammunitionId,args.quantity,args.direction,expected)
    if result.ok then
      -- A failed preview must not turn a committed transfer into a retryable
      -- economic failure. Preserve success; mark counts unavailable instead.
      local called,preview=pcall(AmmoPreview)
      if called and type(preview)=='table' and preview.ok and preview.value.characterId==expected.characterId
        and preview.value.sessionId==expected.sessionId and preview.value.epoch==expected.epoch then
        result.value.options=preview.value.options
      end
    end
    return result
  end)
  ammoTransferBusy=false
  cb(result)
end)

RegisterNUICallback('Feather:Inventory:Hotbar:Set', function(args, cb)
  local result = Feather.RPC.CallAsync('Feather:Inventory:Hotbar:Set', {
    slot = args.slot,
    itemId = args.itemId,
  })
  if result and result.value then ApplyHotbarPayload(result.value, true) end
  cb(result or { error=true, message='The hotbar could not be updated.' })
end)

RegisterNUICallback('Feather:Inventory:UpdateInventory', function(args, cb)
  -- TODO: Test what happens if two players open an inventory at the same time. (OR add system to lock the ability to open an inventory if someone else has it open)

  local data = {
    sourceInventory = args.sourceInventory,
    targetInventory = args.targetInventory,
    items = args.items,
    traceId = args.traceId,
  }

  local result = CallTimedMutation('Feather:Inventory:UpdateInventory', data)

  -- (Rejection surfacing) This used to forward only sourceItems/targetItems,
  -- dropping error/message/code entirely -- so a rejected bulk transfer
  -- (weight, capacity, restricted item) looked to the UI exactly like a
  -- successful one that happened to change nothing. Same bug GiveItem had.
  cb({
    error = result and result.error or false,
    code = result and result.code,
    message = result and result.message,
    sourceItems = result and result.sourceItems,
    targetItems = result and result.targetItems,
    mutationTiming = result and result.mutationTiming,
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
    item = args.item,
    items = args.items,
    traceId = args.traceId
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
  local result = CallTimedMutation('Feather:Inventory:GiveItem', data)
  if not result or result.error then
    cb({ error = true, message = (result and result.message) or 'Unable to give item.' })
  else
    cb({ error = false, sourceItems = result.sourceItems, movedCount = result.movedCount,
      skippedCount = result.skippedCount, mutationTiming = result.mutationTiming })
  end
end)

RegisterNUICallback('Feather:Inventory:DropItems', function(args, cb)
  cb(DropItemsOnGround(args.items, args.traceId))
end)

RegisterNUICallback('Feather:Inventory:MoveItem', function(args, cb)
  local res = CallTimedMutation('Feather:Inventory:MoveItem', args)

  cb(res)
end)

RegisterNUICallback('Feather:Inventory:TakeAll', function(args, cb)
  -- The RPC returns its final fresh pair after commit and access validation.
  local res = CallTimedMutation('Feather:Inventory:TakeAll', args)
  cb(res)
end)

RegisterNUICallback('Feather:Inventory:SplitStack', function(args, cb)
  local res = CallTimedMutation('Feather:Inventory:SplitStack', args)

  cb(res)
end)
