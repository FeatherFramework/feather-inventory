-- Real guard/equipment APIs with a deterministic locked-query model.
local root = arg and arg[1] or '.'
warn = function() end
CreateThread = function() end
local fallbackReads, lockedReads = 0, 0
DB = { query = function() fallbackReads = fallbackReads + 1; return {} end }
Result = { Ok = function(value) return { ok = true, value = value } end,
  Err = function() return { ok = false } end, Codes = {} }
dofile(root .. '/server/services/guards.lua')
dofile(root .. '/server/services/equipment.lua')
local function query(sql, ids)
  assert(sql:find('FOR UPDATE', 1, true))
  assert(#ids <= 200)
  lockedReads = lockedReads + 1
  local result = {}
  for _, id in ipairs(ids) do
    if id == 2 then result[#result + 1] = { inventory_items_id = id } end
  end
  return result
end
local rows = {}
for id = 1, 30 do rows[id] = { id = id } end
assert(GuardsAPI.PrepareMoveSnapshots(query, rows) and lockedReads == 0)
GuardsAPI.RegisterMoveGuard('weapons', function(instance)
  local equipped = EquipmentAPI.IsInstanceEquipped(instance.id)
  if equipped.value then return false, 'Unequip first' end
  return instance.id ~= 3, 'Administrative hold'
end)
assert(GuardsAPI.PrepareMoveSnapshots(query, rows))
assert(lockedReads == 1)
for _, row in ipairs(rows) do
  local allowed = GuardsAPI.CanMoveInstanceSnapshot({ id = row.id,
    equipmentSnapshot = { equipped = row._equipmentEquipped } })
  assert(allowed == (row.id ~= 2 and row.id ~= 3))
  local _, verified = GuardsAPI.GetLockedEquipmentState(row.id)
  assert(not verified, 'Snapshot leaked beyond guard evaluation')
end
assert(fallbackReads == 0, 'Per-item equipment reads were not eliminated')
EquipmentAPI.IsInstanceEquipped(1)
assert(fallbackReads == 1, 'Ordinary equipment reads must retain DB path')
for id = 31, 201 do rows[id] = { id = id } end
assert(GuardsAPI.PrepareMoveSnapshots(query, rows) and lockedReads == 3)
assert(not GuardsAPI.PrepareMoveSnapshots(function() return nil end, rows))
GuardsAPI.RegisterMoveGuard('weapons', function() error('consumer failed') end)
assert(not GuardsAPI.CanMoveInstanceSnapshot({ id = 1, equipmentSnapshot = { equipped = false } }))
local _, verified = GuardsAPI.GetLockedEquipmentState(1)
assert(not verified, 'Error leaked snapshot')
GuardsAPI.RegisterMoveGuard('weapons', function(instance, context)
  assert(EquipmentAPI.IsInstanceEquipped(instance.id).value == false)
  if not context.nested then
    assert(GuardsAPI.CanMoveInstanceSnapshot(instance, { nested = true }))
    assert(EquipmentAPI.IsInstanceEquipped(instance.id).value == false)
  end
  return true
end)
assert(GuardsAPI.CanMoveInstanceSnapshot({ id = 1, equipmentSnapshot = { equipped = false } }, {}))
assert(fallbackReads == 1)
print('PASS equipment guard snapshots: bulk reads, equipped/admin vetoes, fallback, cleanup, nested guards')
