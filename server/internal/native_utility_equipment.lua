-- Internal primitives. Caller owns TX
-- and must roll back every refused result (including post-write authority loss).
local U={}
local function denied() return Result.Err('native_utility_equipment_refused','Current owned utility assignment required.') end
local function int(v,min) return type(v)=='number' and v>=min and v<math.huge and v%1==0 end
local function current(fn)
    local callable=type(fn)=='function' or (type(fn)=='table' and type(rawget(fn,'__cfx_functionReference'))=='string')
    if not callable then return false end
    local ok,v=pcall(fn); return ok and v==true
end
local function copy(v) if type(v)~='table' then return v end; local r={}; for k,x in pairs(v) do r[k]=copy(x) end; return r end
local function reinforcedEnabled()
    return type(GetConvarInt)=='function' and GetConvarInt('feather_native_lasso_reinforced',0)==1
end
local function davyEnabled()
    return type(GetConvarInt)=='function' and GetConvarInt('feather_native_davy_lantern',0)==1
end
local function binocularsEnabled()
    return davyEnabled() and type(GetConvarInt)=='function' and GetConvarInt('feather_native_binoculars',0)==1
end
local function cameraEnabled()
    return binocularsEnabled() and GetConvarInt('feather_native_camera',0)==1
end
local function family(metadata)
    return metadata.weaponDefinitionId=='utility_camera' and 'camera'
        or metadata.weaponDefinitionId=='utility_binoculars' and 'binoculars'
        or metadata.weaponDefinitionId=='utility_davy_lantern' and 'lantern' or 'lasso'
end
local function model(metadata,itemName,reinforced)
    return type(metadata)=='table' and metadata.schemaVersion==2 and metadata.ammo==nil and metadata.maintenance==nil
        and ((metadata.weaponDefinitionId=='utility_lasso' and itemName=='weapon_lasso')
            or (reinforced and metadata.weaponDefinitionId=='utility_lasso_reinforced' and itemName=='weapon_lasso_reinforced')
            or (davyEnabled() and metadata.weaponDefinitionId=='utility_davy_lantern' and itemName=='weapon_melee_davy_lantern')
            or (binocularsEnabled() and metadata.weaponDefinitionId=='utility_binoculars' and itemName=='weapon_kit_binoculars')
            or (cameraEnabled() and metadata.weaponDefinitionId=='utility_camera' and itemName=='weapon_kit_camera'))
end
function U.Read(tx,characterId,authority,locked)
    local reinforced=reinforcedEnabled()
    local davy=davyEnabled()
    local binoculars=binocularsEnabled()
    local camera=cameraEnabled()
    if not InventoryIdentity.NormalizeCharacterId(characterId) or not current(authority) then return denied() end
    if not locked then
    local headers=tx.query('SELECT id FROM inventory WHERE character_id=? LIMIT 1 FOR UPDATE',{characterId})
    if type(headers)~='table' or #headers~=1 or not current(authority) then return denied() end
    end
    local rows
    if locked then rows=locked.ReadEquipment(tx,characterId)
    else rows=tx.query([[SELECT ce.slot, ce.inventory_items_id, ii.row_revision, inv.character_id AS owner_character
        FROM character_equipment ce LEFT JOIN inventory_items ii ON ii.id=ce.inventory_items_id
        LEFT JOIN inventory inv ON inv.id=ii.inventory_id WHERE ce.character_id=? ORDER BY ce.slot FOR UPDATE]],{characterId}) end
    if type(rows)~='table' or not current(authority) then return denied() end
    local expected,ids={},{}
    for _,r in ipairs(rows) do
        local id,revision=tonumber(r.inventory_items_id),tonumber(r.row_revision)
        if type(r.slot)~='string' or expected[r.slot] or not int(id,1) or ids[id]
            or not int(revision,0) or r.owner_character~=characterId then return denied() end
        expected[r.slot]={itemId=id,revision=revision}; ids[id]=true
    end
    local equipment={}
    if not reinforced and not davy and expected.weapon_utility_secondary then return denied() end
    local slots=(reinforced or davy) and {'weapon_utility','weapon_utility_secondary'} or {'weapon_utility'}
    if binoculars then slots[#slots+1]='weapon_utility_tertiary' end
    if camera then slots[#slots+1]='weapon_utility_quaternary' end
    local admitted={}
    for _,slot in ipairs(slots) do admitted[slot]=true end
    for slot in pairs(expected) do
        if slot:match('^weapon_utility') and not admitted[slot] then return denied() end
    end
    local families={}
    for _,slot in ipairs(slots) do
      local assigned=expected[slot]
      if assigned then
        local items=locked and locked.ReadItem(tx,characterId,assigned.itemId)
        if locked and items==nil then return denied() end
        if not items then items=tx.query([[SELECT ii.id, ii.row_revision, ii.metadata, i.name AS itemName
            FROM inventory_items ii INNER JOIN inventory inv ON inv.id=ii.inventory_id
            INNER JOIN items i ON i.id=ii.item_id WHERE ii.id=? AND inv.character_id=? FOR UPDATE]],
            {assigned.itemId,characterId}) end
        if type(items)~='table' or #items~=1 or not current(authority) then return denied() end
        local r=items[1]
        local ok,m=pcall(function() return type(r.metadata)=='table' and r.metadata or json.decode(r.metadata) end)
        if not ok or type(m)~='table' or tonumber(r.id)~=assigned.itemId
            or tonumber(r.row_revision)~=assigned.revision or not model(m,r.itemName,reinforced) then return denied() end
        local itemFamily=family(m)
        if (slot=='weapon_utility_tertiary')~=(itemFamily=='binoculars') or families[itemFamily] then return denied() end
        if (slot=='weapon_utility_quaternary')~=(itemFamily=='camera') then return denied() end
        families[itemFamily]=true
        equipment[slot:sub(8)]={id=assigned.itemId,revision=assigned.revision,itemName=r.itemName,metadata=copy(m)}
      end
    end
    if reinforcedEnabled()~=reinforced or davyEnabled()~=davy or binocularsEnabled()~=binoculars
        or cameraEnabled()~=camera or not current(authority) then return denied() end
    return Result.Ok({characterId=characterId,expected=expected,equipment=equipment})
end
function U.Apply(tx,spec,authority)
    local reinforced=reinforcedEnabled()
    local davy=davyEnabled()
    local binoculars=binocularsEnabled()
    local camera=cameraEnabled()
    if type(spec)~='table' or (spec.slot~='weapon_utility' and not ((reinforced or davy) and spec.slot=='weapon_utility_secondary')
        and not (binoculars and spec.slot=='weapon_utility_tertiary') and not (camera and spec.slot=='weapon_utility_quaternary'))
        or (spec.action~='equip' and spec.action~='unequip')
        or not int(spec.utilityId,1) or not int(spec.utilityRevision,0)
        or type(spec.before)~='table' or type(spec.expected)~='table'
        or not current(authority) then return denied() end
    spec=copy(spec)
    local read=U.Read(tx,spec.characterId,authority)
    if not read.ok then return read end
    local snapshot=read.value
    if not InventoryMetadata.DocumentsEqual(snapshot.expected,spec.expected) then return denied() end
    local item=snapshot.equipment[spec.slot:sub(8)]
    if spec.action=='equip' then
        if snapshot.expected[spec.slot] then return denied() end -- never implicitly replace
        for _,entry in pairs(snapshot.expected) do if entry.itemId==spec.utilityId then return denied() end end
        local rows=tx.query([[SELECT ii.id, ii.row_revision, ii.metadata, i.name AS itemName
            FROM inventory_items ii INNER JOIN inventory inv ON inv.id=ii.inventory_id
            INNER JOIN items i ON i.id=ii.item_id WHERE ii.id=? AND inv.character_id=? FOR UPDATE]],
            {spec.utilityId,spec.characterId})
        if type(rows)~='table' or #rows~=1 or not current(authority) then return denied() end
        local r=rows[1]
        local ok,m=pcall(function() return type(r.metadata)=='table' and r.metadata or json.decode(r.metadata) end)
        if not ok or type(m)~='table' or tonumber(r.id)~=spec.utilityId
            or tonumber(r.row_revision)~=spec.utilityRevision or not model(m,r.itemName,reinforced)
            or type(m.condition)~='number' or not (m.condition>=1 and m.condition<=100)
            or type(m.flags)~='table' or m.flags.disabled~=false or m.flags.evidence~=false then return denied() end
        if (spec.slot=='weapon_utility_tertiary')~=(family(m)=='binoculars') then return denied() end
        if (spec.slot=='weapon_utility_quaternary')~=(family(m)=='camera') then return denied() end
        for _,existing in pairs(snapshot.equipment) do
            local a,b=family(m),family(existing.metadata)
            if a==b then return denied() end
        end
        item={id=spec.utilityId,revision=spec.utilityRevision,metadata=copy(m)}
    end
    if not item or item.id~=spec.utilityId or item.revision~=spec.utilityRevision
        or not InventoryMetadata.DocumentsEqual(item.metadata,spec.before) or not current(authority) then return denied() end
    local intent={characterId=spec.characterId,slot=spec.slot,action=spec.action,expected=copy(snapshot.expected)}
    if spec.action=='equip' then intent.itemId=item.id; intent.itemRevision=item.revision end
    -- Local wrapper preserves CFX callable-table support; never forward arbitrary
    -- client guard context or bypass the registered native instance hold.
    return ConditionalEquipment.Apply(tx,intent,function() return reinforcedEnabled()==reinforced and davyEnabled()==davy
        and binocularsEnabled()==binoculars and cameraEnabled()==camera and current(authority) end)
end
NativeUtilityEquipment=U
return U
