-- Internal transaction body only: exported composition lives in equipment commit.
-- Weapons must supply a reserved, released intent; Inventory owns rollback.
NativeRepairCommit={}
local function integer(v,min) return type(v)=='number' and v>=min and v%1==0 and v<math.huge end
local function copy(v)
    if type(v)~='table' then return v end
    local out={}; for k,x in pairs(v) do out[k]=copy(x) end; return out
end
local function equal(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~='table' then return a==b end
    for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
local function callable(v)
    return type(v)=='function' or (type(v)=='table' and type(rawget(v,'__cfx_functionReference'))=='string')
end
local function denied(message) return Result.Err('native_repair_refused',message) end
function NativeRepairCommit.Apply(tx,spec,current)
    local observing=type(spec)=='table' and spec.action=='maintenance'
    if type(spec)~='table' or not callable(current) or current()~=true
        or type(spec.characterId)~='string' or spec.characterId==''
        or not integer(spec.itemId,1) or not integer(spec.itemRevision,0)
        or type(spec.before)~='table' or type(spec.after)~='table'
        or (not observing and (type(spec.material)~='table' or not integer(spec.material.definitionId,1)
        or not integer(spec.material.quantity,1) or type(spec.material.itemName)~='string')) then
        return denied('Reserved repair intent required.')
    end
    spec=copy(spec)
    -- Economic/identity fields cannot be altered even by a malformed reservation.
    local before,after=copy(spec.before),copy(spec.after)
    before.condition=nil; before.maintenance=nil; after.condition=nil; after.maintenance=nil
    if not equal(before,after) or type(spec.after.condition)~='number'
        or spec.after.condition~=spec.after.condition or math.abs(spec.after.condition)==math.huge
        or type(spec.after.maintenance)~='table' then return denied('Repair may only change maintenance/condition.') end
    if observing then
        if type(spec.before.condition)~='number' or spec.before.condition~=spec.before.condition
            or math.abs(spec.before.condition)==math.huge or type(spec.before.maintenance)~='table'
            or spec.material~=nil or spec.after.condition>spec.before.condition then return denied('Wear cannot heal or consume material.') end
        for _,key in ipairs({'degradation','permanentDegradation','damage','dirt','soot'}) do
            local saved,reported=spec.before.maintenance[key],spec.after.maintenance[key]
            if type(saved)~='number' or saved~=saved or type(reported)~='number' or reported~=reported
                or reported<saved or reported>1 or saved<0 then return denied('Wear must only worsen within unit bounds.') end
        end
    end
    local header=tx.query('SELECT id FROM inventory WHERE character_id=? LIMIT 1 FOR UPDATE',{spec.characterId})
    if current()~=true or not header or not header[1] then return denied('Current inventory required.') end
    local inventoryId=tonumber(header[1].id)
    if not integer(inventoryId,1) then return denied('Invalid inventory.') end
    if type(spec.expected)~='table' then return denied('Expected equipment snapshot required.') end
    local rows=tx.query([[SELECT ce.slot, ce.inventory_items_id, ii.row_revision, inv.character_id AS owner_character
        FROM character_equipment ce LEFT JOIN inventory_items ii ON ii.id=ce.inventory_items_id
        LEFT JOIN inventory inv ON inv.id=ii.inventory_id WHERE ce.character_id=? ORDER BY ce.slot FOR UPDATE]],{spec.characterId})
    if current()~=true or type(rows)~='table' then return denied('Equipment unavailable.') end
    local seen={}
    for _,row in ipairs(rows) do
        local expected=spec.expected[row.slot]
        if seen[row.slot] or type(expected)~='table' or row.owner_character~=spec.characterId
            or tonumber(row.inventory_items_id)~=expected.itemId or tonumber(row.row_revision)~=expected.revision then
            return denied('Equipment changed before repair.')
        end
        seen[row.slot]=true
    end
    for slot in pairs(spec.expected) do if not seen[slot] then return denied('Equipment changed before repair.') end end
    local locked=tx:GetItemForUpdate(spec.itemId)
    if current()~=true or not locked or not locked.ok then return denied('Owned item unavailable.') end
    local item=locked.value
    if type(item)~='table' or item.inventoryId~=inventoryId or item.revision~=spec.itemRevision
        or not equal(item.metadata,spec.before) then return denied('Item ownership or revision changed.') end
    if not observing then
    local definition=tx.query('SELECT id, name FROM items WHERE id=? LIMIT 1',{spec.material.definitionId})
    if current()~=true or not definition or not definition[1]
        or tonumber(definition[1].id)~=spec.material.definitionId
        or definition[1].name~=spec.material.itemName then return denied('Repair material definition changed.') end
    local removed=tx:RemoveQuantity(inventoryId,spec.material.definitionId,spec.material.quantity)
    if current()~=true then return denied('Repair authority changed during payment.') end
    if not removed or not removed.ok then return removed or denied('Repair material unavailable.') end
    end
    local written=tx:SetMetadata(spec.itemId,spec.after,spec.itemRevision)
    if current()~=true then return denied('Repair authority changed during metadata write.') end
    if not written or not written.ok then return written or denied('Repair revision changed.') end
    local final=tx.query([[SELECT slot, inventory_items_id FROM character_equipment
        WHERE character_id=? ORDER BY slot FOR UPDATE]],{spec.characterId})
    if current()~=true or type(final)~='table' then return denied('Post-repair equipment unavailable.') end
    local finalSeen={}
    for _,row in ipairs(final) do
        local expected=spec.expected[row.slot]
        if finalSeen[row.slot] or not expected or tonumber(row.inventory_items_id)~=expected.itemId then
            return denied('Equipment changed during repair; rollback required.')
        end
        finalSeen[row.slot]=true
    end
    for slot in pairs(spec.expected) do
        if not finalSeen[slot] then return denied('Equipment lost during repair; rollback required.') end
    end
    return Result.Ok({itemId=spec.itemId,condition=spec.after.condition,materialConsumed=observing and 0 or spec.material.quantity})
end
