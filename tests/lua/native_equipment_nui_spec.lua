local callbacks={}
RegisterNUICallback=function(name,fn) callbacks[name]=fn end
Config={CharacterAmmunitionEnabled=false}
local started=true
GetResourceState=function() return started and 'started' or 'stopped' end
local calls=0
local scope={characterId='jane',sessionId='s',epoch='e'}
local result
local function reply(value) result=value end
exports={['feather-weapons']={GetNativeEquipmentControls=function(_,id)
 assert(id==112); calls=calls+1
 local nested
 callbacks['Feather:Inventory:NativeEquipmentOptions']({itemId=112},function(value) nested=value end)
 assert(not nested.ok and nested.error.code=='equipment_action_in_flight')
 return {ok=true,value={identity=scope,options={}}}
end,ChangeNativeEquipment=function(_,id,action,slot,expected)
 assert(id==112 and action=='unequip' and slot=='weapon' and expected==scope)
 calls=calls+1; return {ok=true}
end,ChangeNativeAttachment=function(_,id,action,expected,attachmentId)
 assert(id==135 and action=='install' and expected==scope and attachmentId=='carbine_wide_sight')
 calls=calls+1; return {ok=true}
end,RepairNativeEquipment=function(_,id,expected)
 assert(id==128 and expected==scope); calls=calls+1; return {ok=true}
end}}
dofile('client/services/nuicallbacks.lua')
callbacks['Feather:Inventory:NativeEquipmentOptions']({itemId=112},reply)
assert(not result.ok and calls==0)
callbacks['Feather:Inventory:NativeAttachmentChange']({itemId=135,action='install',scope=scope,attachmentId='carbine_wide_sight'},reply)
assert(not result.ok and calls==0)
Config.CharacterAmmunitionEnabled=true
callbacks['Feather:Inventory:NativeEquipmentOptions']({itemId=112},reply); assert(result.ok and calls==1)
callbacks['Feather:Inventory:NativeEquipmentChange']({itemId=112,action='unequip',slot='weapon',scope=scope},reply)
assert(result.ok and calls==2)
callbacks['Feather:Inventory:NativeAttachmentChange']({itemId=135,action='install',scope=scope,attachmentId='carbine_wide_sight'},reply)
assert(result.ok and calls==3)
callbacks['Feather:Inventory:NativeRepair']({itemId=128,scope=scope},reply)
assert(result.ok and calls==4)
started=false
callbacks['Feather:Inventory:NativeEquipmentChange']({itemId=112},reply); assert(not result.ok and calls==4)
started=true; exports['feather-weapons'].GetNativeEquipmentControls=function() error('unavailable') end
callbacks['Feather:Inventory:NativeEquipmentOptions']({itemId=112},reply); assert(not result.ok)
print('Native equipment NUI PASS (gates, intent only, overlap reservation, unavailable export)')
