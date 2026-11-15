local root=arg and arg[1] or '.'
local file=assert(io.open(root..'/client/controllers/inventory.lua','r'))
local source=file:read('*a');file:close()
local start=assert(source:find("    local results = Feather.RPC.CallAsync('Feather:Inventory:GetInventoryItems'",1,true))
local finish=assert(source:find('    local player_display =',start,true))
local body=source:sub(start,finish-1)
local reply,notices,reached=nil,0,0
Feather={RPC={CallAsync=function() return reply end},Notify={RightNotify=function(message)
 assert(type(message)=='string' and #message>0);notices=notices+1
end}}
Translate=function(_,fallback) return fallback end
CanOpenInventory=function() return true end
local run=assert(load('return function() local generation,presentationGeneration=1,1\n'..body..'\nreturn true end'))()
for _,value in ipairs({false,1,'failed'}) do reply=value;assert(run()==nil) end
reply=nil;assert(run()==nil)
reply={error='Unavailable',errorCode='invalid_inventory'};assert(run()==nil)
assert(notices==5,'failed RPC must notify without indexing nil or opening UI')
reply={inventoryItems={}};assert(run()==true and notices==5)
print('Inventory open reply PASS: nil/non-table/server-error responses stay closed and notify; valid reply proceeds')
