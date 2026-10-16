-- Dormant transaction body. The released-intent export/coordinator must own
-- authority before calling this; never a standalone player or fixture command.
NativeAttachmentCommit={}
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
local function integer(v,min) return type(v)=='number' and v>=min and v%1==0 and v<math.huge end
-- A same-transaction wear CAS serializes native floats through JSON before
-- this lock/read. Permit decimal roundoff only in the five unit wear fields;
-- the requested before/after attachment-only delta above remains exact.
local function storedEqual(a,b,path)
    if type(a)~=type(b) then return false end
    if type(a)~='table' then
        local wear={['maintenance.degradation']=true,['maintenance.permanentDegradation']=true,
            ['maintenance.damage']=true,['maintenance.dirt']=true,['maintenance.soot']=true}
        if wear[path] and type(a)=='number' and a==a and b==b and a>=0 and a<=1 and b>=0 and b<=1 then
            return math.abs(a-b)<=0.000000000001
        end
        return a==b
    end
    for key,value in pairs(a) do
        if not storedEqual(value,b[key],path and (path..'.'..tostring(key)) or tostring(key)) then return false end
    end
    for key in pairs(b) do if a[key]==nil then return false end end
    return true
end
local function denied(message) return Result.Err('native_attachment_refused',message) end
local function name(v) return type(v)=='string' and #v>0 and #v<=100 end
local function attachments(value)
    if type(value)~='table' then return nil end
    local count,slots,ids=0,{},{}
    for key,entry in pairs(value) do
        if not integer(key,1) or key>4 or type(entry)~='table' or not name(entry.definitionId)
            or not name(entry.slot) or slots[entry.slot] or ids[entry.definitionId] then return nil end
        for field in pairs(entry) do if field~='definitionId' and field~='slot' then return nil end end
        slots[entry.slot]=entry.definitionId; ids[entry.definitionId]=true; count=count+1
    end
    for index=1,count do if not value[index] then return nil end end
    return slots
end
function NativeAttachmentCommit.Apply(tx,spec,current)
    local callable=type(current)=='function' or type(current)=='table' and type(rawget(current,'__cfx_functionReference'))=='string'
    if not callable or current()~=true or type(spec)~='table' or type(spec.characterId)~='string' or spec.characterId==''
        or not integer(spec.itemId,1) or not integer(spec.itemRevision,0) or type(spec.before)~='table' or type(spec.after)~='table'
        or type(spec.expected)~='table' or type(spec.material)~='table' or not integer(spec.material.definitionId,1)
        or not name(spec.material.itemName) or spec.material.quantity~=1 or not name(spec.attachmentId)
        or (spec.action~='attachment-install' and spec.action~='attachment-remove') then return denied('Released canonical attachment intent required.') end
    spec=copy(spec)
    -- This descriptor is server-derived and part of the exact released intent
    -- validated by current(). Never accept it as a standalone client policy.
    local policy=spec.attachmentPolicy or {definitionId='carbine_wide_sight',slot='sight',itemName='carbine_wide_sight',
        weaponDefinitionId='repeater_carbine',weaponItemName='weapon_repeater_carbine'}
    if type(policy)~='table' then return denied('Invalid reserved attachment policy.') end
    for _,field in ipairs({'definitionId','slot','itemName','weaponDefinitionId','weaponItemName'}) do
        if not name(policy[field]) then return denied('Invalid reserved attachment policy.') end
    end
    if policy.definitionId~=spec.attachmentId or policy.itemName~=spec.material.itemName
        or policy.weaponDefinitionId~=spec.before.weaponDefinitionId then return denied('Reserved attachment policy mismatch.') end
    local ids={}
    for slot,row in pairs(spec.expected) do
        if type(slot)~='string' or slot=='' or type(row)~='table' or not integer(row.itemId,1)
            or not integer(row.revision,0) or ids[row.itemId] then return denied('Invalid expected equipment snapshot.') end
        ids[row.itemId]=true
    end
    local install=spec.action=='attachment-install'
    local prior,nextSlots=attachments(spec.before.attachments),attachments(spec.after.attachments)
    if spec.material.direction~=(install and 'consume' or 'return') or not prior or not nextSlots then return denied('Invalid attachment delta.') end
    if install then
        if prior[policy.slot]~=nil or nextSlots[policy.slot]~=spec.attachmentId then return denied('Invalid attachment install delta.') end
    elseif prior[policy.slot]~=spec.attachmentId or nextSlots[policy.slot]~=nil then return denied('Invalid attachment remove delta.') end
    prior[policy.slot]=nil; nextSlots[policy.slot]=nil
    if not equal(prior,nextSlots) then return denied('Unrelated attachments changed.') end
    local before,after=copy(spec.before),copy(spec.after)
    before.attachments=nil; after.attachments=nil
    if not equal(before,after) then return denied('Attachment transaction may only change attachment metadata.') end
    local header=tx.query('SELECT id FROM inventory WHERE character_id=? LIMIT 1 FOR UPDATE',{spec.characterId})
    local inventoryId=header and header[1] and tonumber(header[1].id)
    if not integer(inventoryId,1) or current()~=true then return denied('Current owned inventory required.') end
    local function assignment()
        return tx.query([[SELECT ce.slot, ce.inventory_items_id, ii.row_revision, inv.character_id AS owner_character
            FROM character_equipment ce LEFT JOIN inventory_items ii ON ii.id=ce.inventory_items_id
            LEFT JOIN inventory inv ON inv.id=ii.inventory_id WHERE ce.character_id=? ORDER BY ce.slot FOR UPDATE]],{spec.characterId})
    end
    local function unchanged(rows,committed)
        if type(rows)~='table' then return false end
        local seen,assigned={},false
        for _,row in ipairs(rows) do
            local expected=spec.expected[row.slot]
            if type(expected)~='table' or seen[row.slot] or row.owner_character~=spec.characterId
                or tonumber(row.inventory_items_id)~=expected.itemId
                or tonumber(row.row_revision)~=expected.revision+(committed and expected.itemId==spec.itemId and 1 or 0) then return false end
            seen[row.slot]=true; assigned=assigned or expected.itemId==spec.itemId
        end
        for slot in pairs(spec.expected) do if not seen[slot] then return false end end
        return assigned
    end
    if not unchanged(assignment(),false) or current()~=true then return denied('Equipment changed before attachment transaction.') end
    local locked=tx:GetItemForUpdate(spec.itemId)
    local item=locked and locked.ok and locked.value
    if not item or item.inventoryId~=inventoryId or item.revision~=spec.itemRevision or not storedEqual(item.metadata,spec.before)
        or not item.definition or item.definition.name~=policy.weaponItemName then return denied('Attachment item ownership/revision changed.') end
    local rows=tx.query('SELECT id, name FROM items WHERE id=? LIMIT 1',{spec.material.definitionId})
    if not rows or not rows[1] or tonumber(rows[1].id)~=spec.material.definitionId or rows[1].name~=spec.material.itemName
        or current()~=true then return denied('Attachment material definition changed.') end
    local payment
    if install then payment=tx:RemoveQuantity(inventoryId,spec.material.definitionId,1)
    else payment=tx:AddQuantity(inventoryId,spec.material.definitionId,1,{}) end
    if not payment or not payment.ok then return payment or denied('Attachment payment/return failed.') end
    if current()~=true then return denied('Attachment authority changed during payment; rollback required.') end
    local written=tx:SetMetadata(spec.itemId,spec.after,spec.itemRevision)
    if not written or not written.ok then return written or denied('Attachment metadata CAS failed.') end
    if current()~=true or not unchanged(assignment(),true) then return denied('Attachment authority/equipment changed; rollback required.') end
    return Result.Ok({itemId=spec.itemId,revision=spec.itemRevision+1,attachmentId=spec.attachmentId,
        installed=install,materialConsumed=install and 1 or 0,materialReturned=install and 0 or 1,noAmmoWrites=true})
end
