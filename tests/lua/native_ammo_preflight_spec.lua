Config={CharacterAmmunitionEnabled=true}
GetResourceState=function() return 'started' end
local callbacks={}
RegisterNUICallback=function(name,fn) callbacks[name]=fn end
local loose,carried,transfers=1,0,0
local onRead
Feather={RPC={CallAsync=function()
  if onRead then local fn=onRead; onRead=nil; fn() end
  local items={{id=112,name='weapon_revolver_cattleman'}}
  for n=1,loose do items[#items+1]={id=112+n,name='ammo_revolver_regular'} end
  return {ok=true,value={characterId='jane',sessionId='s',items=items}}
end}}
exports={['feather-weapons']={
 GetNativeAmmunitionControls=function() return {ok=true,value={characterId='jane',sessionId='s',epoch='e',
  options={{id='regular',itemName='ammo_revolver_regular',carried=carried}}}} end,
 TransferNativeAmmunition=function(_,id,quantity,direction)
  assert(id=='regular' and quantity==1)
  transfers=transfers+1
  local delta=direction=='load' and 1 or -1
  loose,carried=loose-delta,carried+delta
  return {ok=true,value={carried=carried,revision=9+transfers}}
 end,
}}
dofile('client/services/nuicallbacks.lua')
local rawTransfer=callbacks['Feather:Inventory:NativeAmmoTransfer']
local function transfer(args,cb)
 args.scope=args.scope or {characterId='jane',sessionId='s',epoch='e'}
 return rawTransfer(args,cb)
end
local load={ammunitionId='regular',quantity=1,direction='load'}
local result,overlap
transfer({ammunitionId='regular',quantity=1,direction='load',scope={characterId='jane',sessionId='old',epoch='e'}},function(v) result=v end)
assert(not result.ok and result.dispatched==false and transfers==0)
transfer({ammunitionId='regular',quantity=1,direction='load',scope={characterId='jane',sessionId='s',epoch='old'}},function(v) result=v end)
assert(not result.ok and result.dispatched==false and transfers==0)
onRead=function() transfer(load,function(v) overlap=v end) end
transfer(load,function(v) result=v end)
assert(not overlap.ok and overlap.dispatched==false and overlap.error.code=='ammunition_action_in_flight')
assert(result.ok and result.value.options[1].loose==0 and result.value.carried==1 and transfers==1)
transfer({ammunitionId='regular',quantity=1,direction='unload'},function(v) result=v end)
assert(result.ok and result.value.options[1].loose==1 and result.value.carried==0 and transfers==2)
transfer({ammunitionId='regular',quantity=1,direction='unload'},function(v) result=v end)
assert(not result.ok and result.dispatched==false and transfers==2)
for _,quantity in ipairs({0,-1,1.5,'1',math.huge}) do
 transfer({ammunitionId='regular',quantity=quantity,direction='load'},function(v) result=v end)
 assert(not result.ok and result.dispatched==false and transfers==2)
end
print('native ammo preflight PASS (yielded overlap, load/unload count refresh, stale availability, invalid quantity)')
