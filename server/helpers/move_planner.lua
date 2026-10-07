-- Pure placement/capacity planning over transaction-locked snapshots.
-- Only accepted candidates reserve weight, quantity and slots.
InventoryMovePlanner = {}

local function SnapshotState(targetRows)
  local occupied, buckets, held, weight = {}, {}, {}, 0
  for _, row in ipairs(targetRows) do
    local key, slot = tostring(row.item_id), tonumber(row.slot_index)
    held[key] = (held[key] or 0) + 1
    weight = weight + (tonumber(row.weight) or 0)
    if slot then
      occupied[slot] = true
      buckets[key] = buckets[key] or {}
      buckets[key][slot] = buckets[key][slot] or {}
      table.insert(buckets[key][slot], { metadata = row.metadata })
    end
  end
  return occupied, buckets, held, weight
end

function InventoryMovePlanner.ValidateArrivals(policy, targetRows, arriving, restricted)
  local _, _, held, weight = SnapshotState(targetRows)
  for _, row in ipairs(arriving) do
    local key = tostring(row.item_id)
    if restricted[key] then return false, 'item_restricted', 'Item is restricted.' end
    held[key] = (held[key] or 0) + 1
    if Boolean[policy.ignore_item_limit] ~= true and held[key] > (tonumber(row.max_quantity) or 0) then
      return false, 'item_limit', 'Max Quantity Exceeded.'
    end
    weight = weight + (tonumber(row.weight) or 0)
  end
  local limit = tonumber(policy.max_weight) or tonumber(Config.maxWeight) or 0
  if limit > 0 and weight > limit then return false, 'weight_limit', 'Max Weight Exceeded.' end
  return true
end

function InventoryMovePlanner.Plan(policy, targetRows, candidates, restricted, greedy)
  local capacity = tonumber(policy.max_slots) or tonumber(Config.maxItemSlots) or 0
  local weightLimit = tonumber(policy.max_weight) or tonumber(Config.maxWeight) or 0
  local ignoreQuantity = Boolean[policy.ignore_item_limit] == true
  local occupied, buckets, held, weight = SnapshotState(targetRows)
  local plan = { groups = {}, ids = {}, skipped = 0, skipReasons = {} }
  for _, row in ipairs(candidates) do
    local key, slot, code, message = tostring(row.item_id)
    local stackSize = math.max(tonumber(row.max_stack_size) or 1, 1)
    if restricted[key] then
      code, message = 'item_restricted', 'Item is restricted.'
    elseif not ignoreQuantity and (held[key] or 0) + 1 > (tonumber(row.max_quantity) or 0) then
      code, message = 'item_limit', 'Max Quantity Exceeded.'
    elseif weightLimit > 0 and weight + (tonumber(row.weight) or 0) > weightLimit then
      code, message = 'weight_limit', 'Max Weight Exceeded.'
    else
      local metadata = InventoryMetadata.Decode(row.metadata)
      if row.instance_mode ~= 'unique' and metadata then
        local slots = {}
        for index in pairs(buckets[key] or {}) do slots[#slots + 1] = index end
        table.sort(slots)
        for _, index in ipairs(slots) do
          local bucket = buckets[key][index]
          if index >= 0 and index < capacity and #bucket < stackSize
            and InventoryMetadata.RowsCompatible(bucket)
            and InventoryMetadata.DocumentsEqual(InventoryMetadata.Decode(bucket[1].metadata), metadata) then
            slot = index
            break
          end
        end
      end
      if slot == nil then
        for index = 0, capacity - 1 do
          if not occupied[index] then slot = index; break end
        end
      end
      if slot == nil then code, message = 'inventory_full', 'Inventory has no available slots.' end
    end
    if code then
      if not greedy then return nil, code, message end
      plan.skipped = plan.skipped + 1
      plan.skipReasons[code] = (plan.skipReasons[code] or 0) + 1
    else
      plan.ids[#plan.ids + 1] = tonumber(row.id)
      plan.groups[slot] = plan.groups[slot] or {}
      table.insert(plan.groups[slot], row)
      held[key] = (held[key] or 0) + 1
      weight = weight + (tonumber(row.weight) or 0)
      occupied[slot] = true
      buckets[key] = buckets[key] or {}
      buckets[key][slot] = buckets[key][slot] or {}
      table.insert(buckets[key][slot], { metadata = row.metadata })
    end
  end
  return plan
end
