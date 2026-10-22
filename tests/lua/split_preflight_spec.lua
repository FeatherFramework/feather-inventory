-- Advisory split planning only; authoritative lock/race coverage is in slot_updates_spec.
local root = arg and arg[1] or '.'
Config = {maxItemSlots = 20}
local rows, calls = {}, 0
DB = {query = function(sql, id)
  assert(id == 7 and sql:find('LEFT JOIN', 1, true) and sql:find('GROUP BY', 1, true))
  calls = calls + 1
  return rows
end}
dofile(root .. '/server/controllers/inventory.lua')
rows = {{max_slots = 3, slot_index = 0, quantity = 5}, {max_slots = 3, slot_index = 2, quantity = 1}}
local result = InventoryControllers.GetSplitPreflight(7, 0)
assert(result.stackSize == 5 and result.freeSlot == 1 and calls == 1)
rows = {{max_slots = 1, slot_index = 0, quantity = 5}}
result = InventoryControllers.GetSplitPreflight(7, 0)
assert(result.stackSize == 5 and result.freeSlot == nil)
rows = {{max_slots = 2, quantity = 0}}
result = InventoryControllers.GetSplitPreflight(7, 0)
assert(result.stackSize == 0 and result.freeSlot == 0)
rows = {}
assert(InventoryControllers.GetSplitPreflight(7, 0) == nil)
print('PASS split preflight: one query, stack count, gap, full, empty and missing inventory')
