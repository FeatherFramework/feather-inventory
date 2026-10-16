-- Runs inside the SAME transaction as the following equipment write. No export.
NativeLifecycleWear={}
local function copy(v)
    if type(v)~='table' then return v end
    local out={}; for k,x in pairs(v) do out[k]=copy(x) end; return out
end
function NativeLifecycleWear.Apply(tx,spec,current)
    local working=copy(spec)
    if type(spec.lifecycleWear)~='table' or #spec.lifecycleWear>4 or type(spec.expected)~='table' then
        return Result.Err('lifecycle_wear_refused','Reserved final wear plan required.')
    end
    if current()~=true then return Result.Err('lifecycle_wear_refused','Final wear authority changed.') end
    local header=tx.query('SELECT id FROM inventory WHERE character_id=? LIMIT 1 FOR UPDATE',{spec.characterId})
    if not header or not header[1] or current()~=true then return Result.Err('lifecycle_wear_refused','Current inventory required.') end
    local equipment=tx.query([[SELECT ce.slot, ce.inventory_items_id, ii.row_revision, inv.character_id AS owner_character
        FROM character_equipment ce LEFT JOIN inventory_items ii ON ii.id=ce.inventory_items_id
        LEFT JOIN inventory inv ON inv.id=ii.inventory_id WHERE ce.character_id=? ORDER BY ce.slot FOR UPDATE]],{spec.characterId})
    if type(equipment)~='table' or current()~=true then return Result.Err('lifecycle_wear_refused','Current equipment required.') end
    local slots={}
    for _,row in ipairs(equipment) do
        local expected=working.expected[row.slot]
        if slots[row.slot] or not expected or tonumber(row.inventory_items_id)~=expected.itemId
            or tonumber(row.row_revision)~=expected.revision or row.owner_character~=spec.characterId then
            return Result.Err('lifecycle_wear_refused','Final wear equipment snapshot changed.')
        end
        slots[row.slot]=true
    end
    for slot in pairs(working.expected) do if not slots[slot] then return Result.Err('lifecycle_wear_refused','Final wear assignment missing.') end end
    local seen,count={},0
    for index,change in pairs(spec.lifecycleWear) do
        if type(index)~='number' or index<1 or index>4 or index%1~=0 or type(change)~='table'
            or type(change.itemId)~='number' or seen[change.itemId] then
            return Result.Err('lifecycle_wear_refused','Invalid final wear changes.')
        end
        seen[change.itemId]=true
        count=count+1
    end
    for index=1,count do if not spec.lifecycleWear[index] then return Result.Err('lifecycle_wear_refused','Sparse final wear changes.') end end
    for index=1,#spec.lifecycleWear do
        local change=spec.lifecycleWear[index]
        local assigned=false
        for _,row in pairs(working.expected) do
            if row.itemId==change.itemId and row.revision==change.itemRevision then assigned=true end
        end
        if not assigned then return Result.Err('lifecycle_wear_refused','Expected equipped revision required.') end
        local result=NativeRepairCommit.Apply(tx,{action='maintenance',characterId=spec.characterId,
            itemId=change.itemId,itemRevision=change.itemRevision,before=change.before,after=change.after,
            expected=working.expected},current)
        if not result.ok then return result end
        for _,row in pairs(working.expected) do if row.itemId==change.itemId then row.revision=row.revision+1 end end
    end
    if current()~=true then return Result.Err('lifecycle_wear_refused','Final wear authority changed.') end
    return Result.Ok(working)
end
