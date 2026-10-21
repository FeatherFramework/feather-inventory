-- Internal knife composition only: no export, command or automatic admission.
-- Reuse ConditionalEquipment's full snapshot CAS and registered instance guards.
NativeKnifeEquipment={}
-- Internal extension only; no export/admission until Weapons composition is ready.
NativeMeleeEquipment={}
NativeThrowableEquipment={} -- internal first-model adapter, not public admission
local throwableSlots={weapon_throwable='throwable'}
local throwableItems={throwable_tomahawk='weapon_thrown_tomahawk'}
local knifeSlots={weapon_melee='melee'}
local meleeSlots={weapon_melee='melee',weapon_melee_secondary='melee_secondary',
    weapon_melee_tertiary='melee_tertiary',weapon_melee_quaternary='melee_quaternary',weapon_melee_quinary='melee_quinary'}
local knifeItems={melee_knife='weapon_melee_knife'}
local meleeItems={melee_knife='weapon_melee_knife',melee_machete='weapon_melee_machete',
    melee_hammer='weapon_melee_hammer',melee_cleaver='weapon_melee_cleaver',melee_hatchet='weapon_melee_hatchet'}
local function denied(message) return Result.Err('native_knife_equipment_refused',message) end
local function number(v,min) return type(v)=='number' and v>=min and v%1==0 and v<math.huge end
local function copy(v)
    if type(v)~='table' then return v end
    local out={}; for k,x in pairs(v) do out[k]=copy(x) end; return out
end
local function current(fn)
    local ok,value=pcall(fn); return ok and value==true
end
local function ammoDocument(metadata,ammoType)
    if not ammoType then return metadata.ammo==nil end
    local ammo=metadata.ammo
    if type(ammo)~='table' or ammo.ownership~='character' or ammo.type~=ammoType then return false end
    for key in pairs(ammo) do if key~='ownership' and key~='type' then return false end end
    return true
end
local function row(tx,characterId,id,items,ammoType,locked)
    local rows=locked and locked.ReadItem(tx,characterId,id)
    if locked and rows==nil then return nil end
    if not rows then rows=tx.query([[SELECT ii.id, ii.row_revision, ii.metadata, i.name AS itemName
        FROM inventory_items ii INNER JOIN inventory inv ON inv.id=ii.inventory_id
        INNER JOIN items i ON i.id=ii.item_id WHERE ii.id=? AND inv.character_id=? FOR UPDATE]],{id,characterId}) end
    if type(rows)~='table' or #rows~=1 then return nil end
    local item=rows[1]
    local ok,metadata=pcall(function() return type(item.metadata)=='table' and item.metadata or json.decode(item.metadata) end)
    local revision=tonumber(item.row_revision)
    if not ok or type(metadata)~='table' or tonumber(item.id)~=id or not number(revision,0)
        or not items[metadata.weaponDefinitionId] or item.itemName~=items[metadata.weaponDefinitionId]
        or metadata.schemaVersion~=2 or not ammoDocument(metadata,ammoType) or metadata.maintenance~=nil then return nil end
    return {id=id,revision=revision,itemName=item.itemName,metadata=copy(metadata)}
end
local function read(tx,characterId,itemId,authority,slots,items,ammoType,locked)
    if not InventoryIdentity.NormalizeCharacterId(characterId) or (itemId~=nil and not number(itemId,1))
        or not current(authority) then return denied('Current knife reader required.') end
    if not locked then
    local header=tx.query('SELECT id FROM inventory WHERE character_id=? LIMIT 1 FOR UPDATE',{characterId})
    if type(header)~='table' or #header~=1 then return denied('Character inventory missing.') end
    end
    local rows
    if locked then rows=locked.ReadEquipment(tx,characterId)
    else rows=tx.query([[SELECT ce.slot, ce.inventory_items_id, ii.row_revision, inv.character_id AS owner_character
        FROM character_equipment ce LEFT JOIN inventory_items ii ON ii.id=ce.inventory_items_id
        LEFT JOIN inventory inv ON inv.id=ii.inventory_id WHERE ce.character_id=? ORDER BY ce.slot FOR UPDATE]],{characterId}) end
    if type(rows)~='table' then return denied('Equipment unavailable.') end
    local expected,ids={},{}
    for _,item in ipairs(rows) do
        local id,revision=tonumber(item.inventory_items_id),tonumber(item.row_revision)
        if type(item.slot)~='string' or expected[item.slot] or not number(id,1) or ids[id]
            or not number(revision,0) or item.owner_character~=characterId then return denied('Equipment ownership changed.') end
        expected[item.slot]={itemId=id,revision=revision}; ids[id]=true
    end
    local equipment,models,byId={},{},{}
    -- Fixed ordering keeps lock acquisition deterministic across concurrent reads.
    for _,dbSlot in ipairs({'weapon_melee','weapon_melee_secondary','weapon_melee_tertiary','weapon_melee_quaternary','weapon_melee_quinary','weapon_throwable'}) do
        local slot,assigned=slots[dbSlot],expected[dbSlot]
        if slot and assigned then
            local item=row(tx,characterId,assigned.itemId,items,ammoType,locked)
            if not item or item.revision~=assigned.revision then return denied('Assigned melee item changed.') end
            if models[item.metadata.weaponDefinitionId] then return denied('Same-model melee assignments are not supported.') end
            models[item.metadata.weaponDefinitionId]=true
            equipment[slot]=item; byId[item.id]=item
        end
    end
    local candidate=itemId and (byId[itemId] and copy(byId[itemId]) or row(tx,characterId,itemId,items,ammoType,locked)) or nil
    if itemId and not candidate then return denied('Owned native knife required.') end
    if not current(authority) then return denied('Knife read authority changed.') end
    return Result.Ok({characterId=characterId,expected=expected,equipment=equipment,candidate=candidate})
end
local function apply(tx,spec,authority,slots,items,ammoType)
    if type(spec)~='table' or not slots[spec.slot]
        or (spec.action~='equip' and spec.action~='unequip') or not number(spec.knifeId,1)
        or not number(spec.knifeRevision,0) or type(spec.expected)~='table'
        or type(spec.before)~='table' or not current(authority) then return denied('Reserved knife intent required.') end
    spec=copy(spec) -- trusted internal data, frozen across SQL yields
    local snapshot=read(tx,spec.characterId,spec.knifeId,authority,slots,items,ammoType)
    if not snapshot.ok then return snapshot end
    local value=snapshot.value
    if not InventoryMetadata.DocumentsEqual(value.expected,spec.expected) then return denied('Full equipment snapshot changed.') end
    local item=value.candidate
    if not item or item.revision~=spec.knifeRevision or not InventoryMetadata.DocumentsEqual(item.metadata,spec.before) then
        return denied('Knife metadata/revision changed.')
    end
    if spec.action=='equip' then
        local metadata=item.metadata
        if type(metadata.condition)~='number' or not (metadata.condition>=1 and metadata.condition<=100)
            or type(metadata.flags)~='table' or metadata.flags.disabled~=false or metadata.flags.evidence~=false then
            return denied('Knife is not equippable.')
        end
        for _,entry in pairs(value.expected) do if entry.itemId==item.id then return denied('Knife is already assigned.') end end
        for slot,entry in pairs(value.equipment) do
            if slot~=slots[spec.slot] and entry.metadata.weaponDefinitionId==item.metadata.weaponDefinitionId then
                return denied('Same-model melee assignments are not supported.')
            end
        end
    elseif not value.expected[spec.slot] or value.expected[spec.slot].itemId~=item.id then
        return denied('Exact assigned knife required.')
    end
    -- Authority must represent the existing Weapons released reservation, not
    -- just a current character. No bypass context is supplied to instance guards.
    if not current(authority) then return denied('Released knife authority changed.') end
    local intent={characterId=spec.characterId,action=spec.action,slot=spec.slot,expected=copy(value.expected)}
    if spec.action=='equip' then intent.itemId=item.id; intent.itemRevision=item.revision end
    return ConditionalEquipment.Apply(tx,intent,function() return current(authority) end)
end
function NativeKnifeEquipment.Read(tx,characterId,itemId,authority,locked)
    return read(tx,characterId,itemId,authority,knifeSlots,knifeItems,nil,locked)
end
function NativeKnifeEquipment.Apply(tx,spec,authority)
    return apply(tx,spec,authority,knifeSlots,knifeItems)
end
function NativeMeleeEquipment.Read(tx,characterId,itemId,authority,locked)
    return read(tx,characterId,itemId,authority,meleeSlots,meleeItems,nil,locked)
end
function NativeMeleeEquipment.Apply(tx,spec,authority)
    return apply(tx,spec,authority,meleeSlots,meleeItems)
end
function NativeThrowableEquipment.Read(tx,characterId,itemId,authority,locked)
    return read(tx,characterId,itemId,authority,throwableSlots,throwableItems,'ammo_tomahawk_regular',locked)
end
function NativeThrowableEquipment.Apply(tx,spec,authority)
    if type(spec)~='table' or spec.knifeId~=nil or spec.knifeRevision~=nil then return denied('Throwable intent required.') end
    local translated=copy(spec)
    translated.knifeId=spec.throwableId; translated.knifeRevision=spec.throwableRevision
    return apply(tx,translated,authority,throwableSlots,throwableItems,'ammo_tomahawk_regular')
end
