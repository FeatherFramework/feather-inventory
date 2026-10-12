local callbacks={}
Config={CharacterAmmunitionEnabled=false}
RegisterNUICallback=function(name,fn) callbacks[name]=fn end
local state='started'
GetResourceState=function() return state end
local calls=0
local loose=1
local transfers=0
local afterCommitFailure=false
Feather={RPC={CallAsync=function() return {ok=true,value={characterId='jane',sessionId='s',
  items=loose==1 and {{id=112,name='weapon_revolver_cattleman'},{id=113,name='ammo_revolver_regular'}}
    or {{id=112,name='weapon_revolver_cattleman'}}}} end}}
exports={['feather-weapons']={
    GetNativeAmmunitionControls=function(_,name)
        assert(name==nil or name=='weapon_revolver_cattleman')
        calls=calls+1; return {ok=true,value={characterId='jane',sessionId='s',epoch='e',
          options={{id='ammo_revolver_regular',itemName='ammo_revolver_regular',carried=0}}}}
    end,
    TransferNativeAmmunition=function(_,id,quantity,direction)
        calls=calls+1
        transfers=transfers+1
        assert(id=='ammo_revolver_regular' and quantity==1 and direction=='load')
        loose=0
        if afterCommitFailure then exports['feather-weapons'].GetNativeAmmunitionControls=function() error('unavailable') end end
        return {ok=true,value={carried=1,revision=10}}
    end,
}}
dofile('client/services/nuicallbacks.lua')
local scope={characterId='jane',sessionId='s',epoch='e'}
local rawTransfer=callbacks['Feather:Inventory:NativeAmmoTransfer']
callbacks['Feather:Inventory:NativeAmmoTransfer']=function(args,cb)
    args.scope=args.scope or scope
    return rawTransfer(args,cb)
end
local result
local function reply(value) result=value end
callbacks['Feather:Inventory:NativeAmmoOptions']({},reply)
assert(not result.ok and calls==0)
Config.CharacterAmmunitionEnabled=true
callbacks['Feather:Inventory:NativeAmmoOptions']({itemId=112},reply)
assert(result.ok and calls==1 and result.value.options[1].loose==1)
callbacks['Feather:Inventory:NativeAmmoOptions']({itemId=999},reply)
assert(not result.ok and result.error.code=='ammunition_item_not_owned' and calls==1)
rawTransfer({ammunitionId='ammo_revolver_regular',quantity=1,direction='load'},reply)
assert(not result.ok and result.dispatched==false and transfers==0)
callbacks['Feather:Inventory:NativeAmmoTransfer']({ammunitionId='ammo_revolver_regular',quantity=1,direction='load'},reply)
assert(result.ok and result.value.revision==10 and result.value.options[1].loose==0)
callbacks['Feather:Inventory:NativeAmmoTransfer']({ammunitionId='ammo_revolver_regular',quantity=1,direction='load'},reply)
assert(not result.ok and result.dispatched==false and result.value.options[1].loose==0 and transfers==1)
state='stopped'
local before=calls
callbacks['Feather:Inventory:NativeAmmoOptions']({},reply)
assert(not result.ok and calls==before)
state='started'
local controls=exports['feather-weapons'].GetNativeAmmunitionControls
exports['feather-weapons'].GetNativeAmmunitionControls=function() error('unavailable') end
callbacks['Feather:Inventory:NativeAmmoOptions']({},reply)
assert(not result.ok and result.error.code=='ammunition_action_unavailable')
exports['feather-weapons'].GetNativeAmmunitionControls=controls
loose=1; afterCommitFailure=true
callbacks['Feather:Inventory:NativeAmmoTransfer']({ammunitionId='ammo_revolver_regular',quantity=1,direction='load'},reply)
assert(result.ok and result.value.revision==10 and result.value.options==nil,
  'post-commit preview failure cannot turn success into a retryable transfer failure')
print('native ammo NUI bridge PASS (gates, intent-only forwarding, unavailable export)')
