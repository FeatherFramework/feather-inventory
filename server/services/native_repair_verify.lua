-- Read-only durable-state audit. Baselines/specs are trusted server data, not
-- player payloads. Captured baselines must be retained for restart comparisons.
NativeRepairVerify={}
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
local function denied(message) return Result.Err('repair_verify_failed',message) end
function NativeRepairVerify.Read(tx,characterId)
    if type(characterId)~='string' or characterId=='' then return denied('Character required.') end
    local rows=tx.query([[SELECT ii.id, ii.item_id, ii.row_revision, ii.metadata, ii.slot_index, ii.inventory_id,
        i.name AS itemName FROM inventory_items ii INNER JOIN inventory inv ON inv.id=ii.inventory_id
        INNER JOIN items i ON i.id=ii.item_id WHERE inv.character_id=? ORDER BY ii.id]],{characterId})
    if type(rows)~='table' then return denied('Inventory unavailable.') end
    local items={}
    for _,row in ipairs(rows) do
        local ok,metadata=pcall(function() return type(row.metadata)=='table' and row.metadata or json.decode(row.metadata or '{}') end)
        local id,revision=tonumber(row.id),tonumber(row.row_revision)
        if not ok or type(metadata)~='table' or not id or id<1 or id%1~=0 or id==math.huge
            or not revision or revision<0 or revision%1~=0 or revision==math.huge or items[id] then
            return denied('Invalid durable item snapshot.')
        end
        items[id]={id=id,definitionId=tonumber(row.item_id),revision=revision,metadata=copy(metadata),
            itemName=row.itemName,slot=row.slot_index,inventoryId=tonumber(row.inventory_id)}
    end
    local equipment=tx.query('SELECT slot, inventory_items_id FROM character_equipment WHERE character_id=? ORDER BY slot',{characterId})
    local ledger=tx.query('SELECT * FROM feather_character_ammunition WHERE character_id=?',{characterId})
    local operations=tx.query('SELECT * FROM feather_ammunition_operations WHERE character_id=? ORDER BY operation_id',{characterId})
    local grants=tx.query([[SELECT * FROM inventory_grant_receipts
        WHERE SUBSTRING_INDEX(request_fingerprint,'|',1)=? ORDER BY source_resource, grant_id]],{characterId})
    if type(equipment)~='table' or type(ledger)~='table' or type(operations)~='table' or type(grants)~='table' then
        return denied('Durable economics unavailable.')
    end
    return Result.Ok({characterId=characterId,items=items,equipment=copy(equipment),ledger=copy(ledger),
        operations=copy(operations),grants=copy(grants)})
end
function NativeRepairVerify.Compare(before,after,spec)
    if type(before)~='table' or type(after)~='table' or type(spec)~='table'
        or before.characterId~=after.characterId or before.characterId~=spec.characterId
        or type(before.items)~='table' or type(after.items)~='table'
        or type(spec.material)~='table' or type(spec.material.quantity)~='number'
        or spec.material.quantity<1 or spec.material.quantity%1~=0 or spec.material.quantity==math.huge then
        return denied('Trusted before/after repair scope required.')
    end
    for _,key in ipairs({'equipment','ledger','operations','grants'}) do
        if type(before[key])~='table' or not equal(before[key],after[key]) then
            return denied('Repair changed '..key..'.')
        end
    end
    if type(spec.before)~='table' or type(spec.after)~='table' then return denied('Repair metadata required.') end
    local original,repaired=copy(spec.before),copy(spec.after)
    original.condition=nil; original.maintenance=nil; repaired.condition=nil; repaired.maintenance=nil
    if not equal(original,repaired) then return denied('Repair spec changed identity/ammo/unrelated metadata.') end
    local removed=0
    for id,row in pairs(before.items) do
        local now=after.items[id]
        if id==spec.itemId then
            if row.revision~=spec.itemRevision or not equal(row.metadata,spec.before) or not now then
                return denied('Repair baseline item changed.')
            end
            local expected=copy(row); expected.revision=expected.revision+1; expected.metadata=copy(spec.after)
            if not equal(expected,now) then return denied('Exact repaired metadata/revision required.') end
        elseif not now then
            if row.definitionId~=spec.material.definitionId or row.itemName~=spec.material.itemName then
                return denied('Unexpected item removal.')
            end
            removed=removed+1
        elseif not equal(row,now) then return denied('Unrelated item changed.') end
    end
    if not before.items[spec.itemId] or removed~=spec.material.quantity then return denied('Exact material payment required.') end
    for id in pairs(after.items) do if not before.items[id] then return denied('Unexpected item grant.') end end
    return Result.Ok({itemId=spec.itemId,revision=spec.itemRevision+1,materialConsumed=removed,
        equipmentUnchanged=true,ammoUnchanged=true})
end
function NativeRepairVerify.Diagnose(before,after,spec)
    local function target(snapshot,id)
        local row=snapshot.items[id]
        if not row then return {id=id,missing=true} end
        return {id=id,revision=row.revision,definitionId=row.definitionId,itemName=row.itemName,
            inventoryId=row.inventoryId,condition=row.metadata.condition,maintenance=copy(row.metadata.maintenance)}
    end
    local beforeOil,afterOil=0,0
    for _,row in pairs(before.items) do if row.definitionId==spec.material.definitionId then beforeOil=beforeOil+1 end end
    for _,row in pairs(after.items) do if row.definitionId==spec.material.definitionId then afterOil=afterOil+1 end end
    return Result.Ok({beforeEquipment=copy(before.equipment),currentEquipment=copy(after.equipment),
        beforeItem=target(before,spec.itemId),currentItem=target(after,spec.itemId),
        original112Unchanged=equal(before.items[112],after.items[112]),beforeOil=beforeOil,currentOil=afterOil,
        ledgerUnchanged=equal(before.ledger,after.ledger),operationsUnchanged=equal(before.operations,after.operations),
        grantsUnchanged=equal(before.grants,after.grants),noEconomicWrites=true})
end
function NativeRepairVerify.CompareWear(before,after,spec)
    if before.characterId~=after.characterId or before.characterId~=spec.characterId then return denied('Wear scope changed.') end
    for _,key in ipairs({'equipment','ledger','operations','grants'}) do
        if not equal(before[key],after[key]) then return denied('Wear changed '..key..'.') end
    end
    local saved,observed=before.items[spec.itemId],after.items[spec.itemId]
    if not saved or not observed or saved.revision~=spec.itemRevision or not equal(saved.metadata,spec.before)
        or (observed.revision~=saved.revision and observed.revision~=saved.revision+1) then return denied('Exact wear baseline/revision required.') end
    local expected=copy(saved); expected.revision=observed.revision; expected.metadata=copy(observed.metadata)
    if not equal(expected,observed) then return denied('Wear changed item identity/location.') end
    local old,new=copy(saved.metadata),copy(observed.metadata)
    local oldWear,newWear=old.maintenance,new.maintenance
    if type(oldWear)~='table' or type(newWear)~='table' then return denied('Wear metadata missing.') end
    for _,key in ipairs({'degradation','permanentDegradation','damage','dirt','soot'}) do
        local a,b=oldWear[key],newWear[key]
        if type(a)~='number' or type(b)~='number' or b~=b or b<a or a<0 or b>1 then return denied('Wear healed/invalid.') end
    end
    local maximum=spec.conditionMaximum
    if type(maximum)~='number' or maximum<=0 or maximum==math.huge then return denied('Canonical condition maximum required.') end
    local condition=math.min(old.condition,math.floor((1-math.max(newWear.degradation,newWear.damage,newWear.permanentDegradation))*maximum+0.5))
    if new.condition~=condition then return denied('Wear condition calculation mismatch.') end
    old.condition=nil; old.maintenance=nil; new.condition=nil; new.maintenance=nil
    if not equal(old,new) then return denied('Wear changed identity/ammo/unrelated metadata.') end
    for id,row in pairs(before.items) do if id~=spec.itemId and not equal(row,after.items[id]) then return denied('Wear changed unrelated items/materials.') end end
    for id in pairs(after.items) do if not before.items[id] then return denied('Wear granted items.') end end
    if observed.revision==saved.revision and not equal(saved,observed) then return denied('Wear metadata changed without revision.') end
    return Result.Ok({itemId=spec.itemId,revision=observed.revision,changed=observed.revision~=saved.revision,
        ammoUnchanged=true,equipmentUnchanged=true,materialConsumed=0})
end
-- Separate SELECT-audit policy: never weaken ordinary unchanged-equipment wear.
function NativeRepairVerify.ComparePromotionWear(before,after,spec)
    if type(before)~='table' or type(after)~='table' or type(spec)~='table'
        or type(before.items)~='table' or type(after.items)~='table'
        or type(spec.itemRevision)~='number' or spec.itemRevision<0 or spec.itemRevision%1~=0
        or spec.itemRevision==math.huge then return denied('Promotion snapshots required.') end
    local function assignments(rows)
        if type(rows)~='table' then return nil end
        local slots,ids,count={},{},0
        for index,row in pairs(rows) do
            if type(index)~='number' or index%1~=0 or index<1 or index>#rows or type(row)~='table'
                or type(row.slot)~='string' or slots[row.slot] then return nil end
            local id=tonumber(row.inventory_items_id)
            if not id or id<1 or id%1~=0 or id==math.huge or ids[id] then return nil end
            ids[id]=true
            for key in pairs(row) do if key~='slot' and key~='inventory_items_id' then return nil end end
            slots[row.slot]=id; count=count+1
        end
        if count~=#rows then return nil end
        return slots
    end
    local oldSlots,newSlots=assignments(before.equipment),assignments(after.equipment)
    if not oldSlots or not newSlots or oldSlots.weapon~=spec.itemId
        or not oldSlots.weapon_offhand or oldSlots.weapon_offhand==spec.itemId then return denied('Exact primary/offhand baseline required.') end
    local siblingId=oldSlots.weapon_offhand
    local primary,sibling=after.items[spec.itemId],before.items[siblingId]
    if not primary or not sibling or type(primary.metadata)~='table' or primary.metadata.condition~=0
        or primary.revision~=spec.itemRevision+1 or type(sibling.metadata)~='table'
        or type(sibling.metadata.condition)~='number' or not (sibling.metadata.condition>0)
        or not equal(sibling,after.items[siblingId]) then return denied('Broken primary and unchanged healthy offhand required.') end
    local wear=sibling.metadata.maintenance
    if type(wear)~='table' then return denied('Healthy offhand wear required.') end
    for _,key in ipairs({'degradation','damage','permanentDegradation'}) do
        local value=wear[key]
        if type(value)~='number' or not (value>=0 and value<1) then return denied('Healthy offhand wear required.') end
    end
    local flags=sibling.metadata.flags
    if type(flags)~='table' or flags.disabled~=false or flags.evidence~=false then return denied('Equippable offhand flags required.') end
    local expected=copy(oldSlots); expected.weapon=siblingId; expected.weapon_offhand=nil
    for slot,id in pairs(expected) do if id==spec.itemId then return denied('Broken primary remains assigned.') end end
    if not equal(expected,newSlots) then return denied('Exact offhand-to-primary promotion required.') end
    -- Equipment has been checked independently. Reuse all strict conservation,
    -- canonical condition and monotonic wear checks without mutating snapshots.
    local normalized=copy(after); normalized.equipment=copy(before.equipment)
    local result=NativeRepairVerify.CompareWear(before,normalized,spec)
    if not result.ok then return result end
    result.value.equipmentUnchanged=false
    result.value.promotionVerified=true
    result.value.promotedItemId=siblingId
    result.value.noEconomicWrites=true
    return result
end
