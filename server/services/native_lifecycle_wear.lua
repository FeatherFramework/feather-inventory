-- Runs inside the SAME transaction as the following equipment write. No export.
NativeLifecycleWear={}
local function copy(v)
    if type(v)~='table' then return v end
    local out={}; for k,x in pairs(v) do out[k]=copy(x) end; return out
end
-- Released-owner or exact reserved death-observation path. Use guarded conditional equipment writes;
-- no item removal, ammo mutation or attachment changes. Healthy dependent offhand
-- promotion changes assignments only, inside the same transaction.
function NativeLifecycleWear.DetachBroken(tx,spec,current,guardContext)
    local working=copy(spec)
    if spec.brokenEquipment==nil then return Result.Ok(working) end
    if type(spec.brokenEquipment)~='table' or type(spec.expected)~='table' or current()~=true then
        return Result.Err('broken_equipment_refused','Reserved broken equipment plan required.')
    end
    local allowed={weapon=true,weapon_offhand=true,weapon_shoulder=true,weapon_back=true}
    if spec.action=='death' and next(spec.brokenEquipment)~=nil and (type(guardContext)~='table'
        or guardContext.resource~='feather-weapons' or guardContext.characterId~=spec.characterId
        or type(guardContext.runtimeEpoch)~='string' or type(guardContext.runtimeTicket)~='string') then
        return Result.Err('broken_equipment_refused','Reserved death equipment authority required.')
    end
    for slot,entry in pairs(spec.brokenEquipment) do
        local expected=working.expected[slot]
        if not allowed[slot] or type(entry)~='table' or not expected or entry.itemId~=expected.itemId then
            return Result.Err('broken_equipment_refused','Broken assignment changed.')
        end
        local read=tx:GetItemForUpdate(entry.itemId)
        local item=read and read.ok and read.value
        if not item or item.revision~=expected.revision or type(item.metadata)~='table' or current()~=true then
            return Result.Err('broken_equipment_refused','Broken item revision changed.')
        end
        if entry.reason=='broken' then
            local condition=item.metadata.condition
            if type(entry.minimum)~='number' or entry.minimum~=entry.minimum or entry.minimum<=0 or entry.minimum>100
                or type(condition)~='number' or condition~=condition or condition<0 or condition>=entry.minimum then
                return Result.Err('broken_equipment_refused','Item is not below its reserved equip minimum.')
            end
        elseif entry.reason~='primary_broken' or slot~='weapon_offhand'
            or not spec.brokenEquipment.weapon or spec.brokenEquipment.weapon.reason~='broken' then
            return Result.Err('broken_equipment_refused','Invalid dependent offhand removal.')
        end
        if entry.promote~=nil then
            if entry.promote~=true or entry.reason~='primary_broken' or slot~='weapon_offhand'
                or type(entry.minimum)~='number' or entry.minimum~=entry.minimum or entry.minimum<=0 or entry.minimum>100
                or type(item.metadata.condition)~='number' or item.metadata.condition~=item.metadata.condition
                or item.metadata.condition<entry.minimum or item.metadata.condition>100
                or (item.metadata.flags or {}).disabled or (item.metadata.flags or {}).evidence then
                return Result.Err('broken_equipment_refused','Invalid healthy offhand promotion.')
            end
        end
    end
    for _,slot in ipairs({'weapon_offhand','weapon','weapon_shoulder','weapon_back'}) do
        if spec.brokenEquipment[slot] then
            local result=ConditionalEquipment.Apply(tx,{characterId=spec.characterId,action='unequip',slot=slot,
                expected=working.expected},current,spec.action=='death' and guardContext or nil)
            if not result.ok then return result end
            working.expected[slot]=nil
        end
    end
    local promotion=spec.brokenEquipment.weapon_offhand
    if promotion and promotion.promote then
        local expected=spec.expected.weapon_offhand
        local result=ConditionalEquipment.Apply(tx,{characterId=spec.characterId,action='equip',slot='weapon',
            itemId=promotion.itemId,itemRevision=expected.revision,expected=working.expected},current,
            spec.action=='death' and guardContext or nil)
        if not result.ok then return result end
        working.expected.weapon={itemId=promotion.itemId,revision=expected.revision}
    end
    if current()~=true then return Result.Err('broken_equipment_refused','Broken equipment authority changed.') end
    return Result.Ok(working)
end
function NativeLifecycleWear.Apply(tx,spec,current,guardContext)
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
    return NativeLifecycleWear.DetachBroken(tx,working,current,guardContext)
end
