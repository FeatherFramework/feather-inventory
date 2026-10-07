local root = arg and arg[1] or '.'
CreateThread = function() end
AddEventHandler = function() end
GetGameTimer = function() return 100 end
Config = { Access = { RobberyDistance = 5 }, Dropped = { PromptViewDistance = 5 } }
Result = { Ok = function(value) return {ok = true, value = value} end,
  Err = function() return {ok = false} end, IsOk = function(result) return result.ok end, Codes = {} }
local ownReads, positionReads, near, lootable, targetPresent = 0, 0, true, true, true
InventoryIdentity = { GetCharacter = function(src)
  if tostring(src) == '1' then return {char = {id = 'self'}} end
  if targetPresent then return {char = {id = 'target'}} end
end, GetPosition = function(src)
  if tostring(src) == '1' and not near then return 100, 100, 100 end
  return 0, 0, 0
end }
InventoryControllers = {
  GetInventoryByCharacter = function() ownReads = ownReads + 1; return 1 end,
  GetInventoryLocationById = function(id) return id == 2 and 'ground' or 'character' end,
}
dofile(root .. '/server/services/inventory.lua')
dofile(root .. '/server/services/inventory_access.lua')
GetCharacterPosition = function() return 0, 0, 0 end
IsWithinDistance = function() return near end
CanBeLootedDueToStatus = function() return lootable end
local opened
for index = 1, 20 do
  local name, value = debug.getupvalue(InventoryAPI.IsInventoryAccessibleBySrc, index)
  if name == 'OpenInventories' then opened = value; break end
end
assert(opened)
opened['2'] = {src = '1', uuid = 'ground-uuid'}
local function groundQuery(sql, params)
  assert(sql:find('INNER JOIN `ground`', 1, true) and params[1] == 2)
  positionReads = positionReads + 1
  return {{x = 1, y = 1, z = 1}}
end
assert(InventoryAPI.CanAccessInventory(1, 2, InventoryAPI.AccessModes.REMOVE, {}, groundQuery).ok)
assert(ownReads == 0 and positionReads == 1)
near = false
assert(not InventoryAPI.CanAccessInventory(1, 2, InventoryAPI.AccessModes.INSERT, {}, groundQuery).ok)
near = true
assert(not IsWithinGroundPickupDistance(1, 2, function() return {} end))
opened['2'] = nil
assert(not InventoryAPI.Accessible(1, 2))
opened['2'] = {src = '99', uuid = 'ground-uuid'}
assert(not InventoryAPI.Accessible(1, 2))
assert(InventoryAPI.Accessible(1, 1))
opened['3'] = {src = '1', uuid = 2}
assert(InventoryAPI.Accessible(1, 3))
lootable = false
assert(not InventoryAPI.Accessible(1, 3))
lootable, near = true, false
assert(not InventoryAPI.Accessible(1, 3))
near, targetPresent = true, false
assert(not InventoryAPI.Accessible(1, 3))
print('PASS real access APIs: fewer reads, ground proximity, missing pile, closed/foreign session, own inventory, robbery status/distance/identity')
