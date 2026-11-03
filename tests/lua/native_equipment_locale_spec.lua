local file=assert(io.open('client/controllers/inventory.lua','r'))
local source=file:read('*a'); file:close()
local boundary=assert(source:find('function CanOpenInventory()',1,true))
local handlers,messages={},{}
local lang='first'
Translate=function(key)
    if key=='ui_equipment_title' then return lang..'-equipment' end
    return nil -- missing locale/key must leave NUI's English fallback intact
end
AddEventHandler=function(event,fn) handlers[event]=fn end
SendNUIMessage=function(value) messages[#messages+1]=value end
assert(load(source:sub(1,boundary-1)))()
local changed=assert(handlers['feather-core:locale:changed'])
changed('ignored-event-language')
assert(#messages==1 and messages[1].type=='localeStrings')
assert(messages[1].strings.ui_equipment_title=='first-equipment')
assert(messages[1].strings.ui_equipment_help==nil)
assert(messages[1].items==nil and messages[1].visible==nil,'no ledger reopening or equipment intent on locale change')
lang='second'
changed()
assert(messages[2].strings.ui_equipment_title=='second-equipment')
assert(messages[1].strings.ui_equipment_title=='first-equipment','each refresh is a fresh player-resolved bundle')
print('Native equipment locale bridge PASS: actual controller event uses selected locale translator, missing-key fallback, labels only')
