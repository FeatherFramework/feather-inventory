local root = arg and arg[1] or '.'
Config = {}
Result = {Ok = function(value) return {ok = true, value = value} end}
exports = function() end
ItemsAPI = {RegisterInternalUseGuard = function() end}
TransactionAPI, InstancesAPI, EquipmentAPI, DiagnosticsAPI = {}, {}, {}, {}
local initialized, reachable = 0, true
DB = {awaitReady = function(timeout) assert(timeout == 60000); coroutine.yield('waiting'); return reachable end}
GrantOnceAPI = {Start = function() initialized = initialized + 1 end}
RegisterCharacterStart, RegisterGroundInventory = function() end, function() end

dofile(root .. '/server/helpers/main.lua')
for _, result in ipairs({true, false}) do
  reachable, initialized = result, 0
  dofile(root .. '/server/services/api.lua')
  local thread = coroutine.create(function() dofile(root .. '/server/main.lua') end)
  local ok, state = coroutine.resume(thread)
  assert(ok and state == 'waiting' and initialized == 0 and InventoryReadiness.state == 'starting')
  ok = coroutine.resume(thread)
  assert(ok)
  if result then assert(initialized == 1 and InventoryReadiness.state == 'ready')
  else assert(initialized == 0 and InventoryReadiness.state == 'failed' and InventoryReadiness.failure:find('database_unavailable')) end
end
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
