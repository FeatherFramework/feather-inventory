local function scenario(devMode)
 local events,commands,messages={},{},{}
 local listeners,focus=0,false
 Config={DevMode=devMode,hotkey='I'}
 RegisterNetEvent=function(name,fn) events[name]=fn end
 AddEventHandler=function(name,fn) events[name]=fn end
 RegisterCommand=function(name,fn) commands[name]=fn end
 SendNUIMessage=function(message) messages[#messages+1]=message end
 SetNuiFocus=function(value) focus=value end
 PlayerPedId=function() return 1 end
 IsEntityDead=function() return false end
 IsPauseMenuActive=function() return false end
 GetResourceState=function() return 'stopped' end
 GetCurrentResourceName=function() return 'feather-inventory' end
 Translate=function(key) return key end
 TriggerEvent=function() end
 local yielded
 local closeCalls=0
 Feather={Keys={RegisterListener=function() listeners=listeners+1; return {} end},
  Notify={RightNotify=function() end},RPC={CallAsync=function(name)
   if name=='Feather:Inventory:Server:CloseInventory' then closeCalls=closeCalls+1 end
   if name==yielded then coroutine.yield('read'); yielded=nil end
   if name=='Feather:Inventory:GetInventoryItems' then return {inventory=1,inventoryItems={}} end
   if name=='Feather:Inventory:GetCharacterInfoForDisplay' then return {id='jane',firstName='Jane',lastName='Doe'} end
   return {}
  end}}
 dofile('client/controllers/inventory.lua')
 dofile('client/services/commands.lua')
 assert(listeners==(devMode and 1 or 0))
 events['Feather:Character:Spawned']()
 InventoryAction.Open()
 assert(focus and messages[#messages].type=='toggleInventory')
 events['Feather:Character:Logout']()
 assert(not focus and messages[#messages].type=='closeInventory' and not InventoryCharacterActive)
 assert(not CanOpenInventory(),'DevMode cannot reopen Inventory in character selection')
 events['Feather:Character:Spawned']()
 InventoryAction.Open()
 events['feather-medical:client:condition-changed.v1']({lifeState='dead'})
 assert(not focus and messages[#messages].type=='closeInventory')
 for _,name in ipairs({'Feather:Inventory:GetInventoryItems','Feather:Inventory:GetCharacterInfoForDisplay','Feather:Inventory:GetCategories'}) do
  yielded=name
  local thread=coroutine.create(function() InventoryAction.Open() end)
  local ok,why=coroutine.resume(thread)
  assert(ok and why=='read')
  events['Feather:Character:Logout']()
  events['Feather:Character:Spawned']() -- a new character route must not revive old read
  local count=#messages
  assert(coroutine.resume(thread))
  assert(#messages==count and not focus,'late RPC response cannot reopen old Inventory')
 end
 InventoryAction.Open()
 local previous=closeCalls
 events.onResourceStop('unrelated-resource')
 assert(focus and closeCalls==previous)
 events.onResourceStop('feather-weapons')
 assert(focus and messages[#messages].type=='ammoPanelInvalidated' and closeCalls==previous)
 events.onResourceStop('feather-inventory')
 assert(not focus and messages[#messages].type=='closeInventory' and closeCalls==previous)
 events['Feather:Character:Spawned'](); InventoryAction.Open()
 previous=closeCalls
 events.onResourceStop('feather-character')
 assert(not focus and not InventoryCharacterActive and closeCalls==previous)
end
scenario(false); scenario(true)
print('Inventory client lifecycle PASS (dev/normal logout/death, late reads, resource-stop local cleanup)')
