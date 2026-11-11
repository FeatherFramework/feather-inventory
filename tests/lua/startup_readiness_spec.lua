CharacterCollectionAPI={Start=function() end}
CollectionStorageAPI={Start=function() end}
local root = arg and arg[1] or '.'
Config = {}
Result = {Ok = function(value) return {ok = true, value = value} end}
exports = function() end
ItemsAPI = {RegisterInternalUseGuard = function() end}
TransactionAPI, InstancesAPI, EquipmentAPI, DiagnosticsAPI = {}, {}, {}, {}
local initialized, checkoutInitialized, reachable = 0, 0, true
local schemaInitialized,schemaFail=0,false
InventoryCharacterAmmoSchema={Start=function()
 assert(InventoryReadiness.state=='starting' and initialized==0 and checkoutInitialized==0)
 schemaInitialized=schemaInitialized+1
 if schemaFail then error('ammunition_schema_sentinel') end
 return true
end}
DB = {awaitReady = function(timeout) assert(timeout == 60000); coroutine.yield('waiting'); return reachable end}
GrantOnceAPI = {Start = function() initialized = initialized + 1 end}
ShopCheckoutAPI = {Start = function() checkoutInitialized=checkoutInitialized+1 end}
ConsumptionOnceAPI = {Start = function() end}
InventoryMoveRecovery = {Start = function() end}
RegisterCharacterStart, RegisterGroundInventory = function() end, function() end

dofile(root .. '/server/helpers/main.lua')
for _, result in ipairs({true, false}) do
  reachable, initialized, checkoutInitialized, schemaInitialized = result, 0, 0, 0
  dofile(root .. '/server/services/api.lua')
  local thread = coroutine.create(function() dofile(root .. '/server/main.lua') end)
  local ok, state = coroutine.resume(thread)
  assert(ok and state == 'waiting' and initialized == 0 and checkoutInitialized==0 and InventoryReadiness.state == 'starting')
  ok = coroutine.resume(thread)
  assert(ok)
  if result then assert(schemaInitialized==1 and initialized == 1 and checkoutInitialized==1 and InventoryReadiness.state == 'ready')
  else assert(schemaInitialized==0 and initialized == 0 and checkoutInitialized==0 and InventoryReadiness.state == 'failed' and InventoryReadiness.failure:find('database_unavailable')) end
end
-- Schema failure must never publish ready or start economic consumers.
reachable,initialized,checkoutInitialized,schemaInitialized,schemaFail=true,0,0,0,true
dofile(root..'/server/services/api.lua')
local failed=coroutine.create(function() dofile(root..'/server/main.lua') end)
assert(coroutine.resume(failed));assert(coroutine.resume(failed))
assert(InventoryReadiness.state=='failed' and InventoryReadiness.failure:find('ammunition_schema_sentinel',1,true)
 and schemaInitialized==1 and initialized==0 and checkoutInitialized==0)
schemaFail=false
local tasks, statements = {}, 0
CreateThread = function(callback) tasks[#tasks + 1] = callback end
DB.query = function() statements = statements + 1; return {{}} end
DB.exec = function() statements = statements + 1 end
reachable = true
dofile(root .. '/server/services/slots.lua')
dofile(root .. '/server/services/equipment.lua')
for _, callback in ipairs(tasks) do
  local before = statements
  local thread = coroutine.create(callback)
  local ok, state = coroutine.resume(thread)
  assert(ok and state == 'waiting' and statements == before)
  ok = coroutine.resume(thread)
  assert(ok and statements > before)
end
print('PASS Inventory API and background schemas wait before SQL; timeout fails startup')
