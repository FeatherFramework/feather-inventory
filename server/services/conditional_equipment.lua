-- Internal transaction boundary only. No client mutation route/export. A future
-- native owner must prove released authority before invoking this helper.
ConditionalEquipment = {}
local function denied(message) return Result.Err('equipment_change_refused',message) end
local function integer(value) return type(value)=='number' and value>0 and value%1==0 and value<math.huge end
local function revision(value) return type(value)=='number' and value>=0 and value%1==0 and value<math.huge end
function ConditionalEquipment.Apply(tx,spec,current)
    if type(spec)~='table' or type(current)~='function' or current()~=true
        or not InventoryIdentity.NormalizeCharacterId(spec.characterId)
        or type(spec.slot)~='string' or #spec.slot>50 or not spec.slot:match('^[a-z][a-z0-9_]*$')
        or type(spec.expected)~='table' or (spec.action~='equip' and spec.action~='unequip') then
        return denied('Current identity and explicit conditional equipment intent required.')
    end
    if spec.action=='equip' and (not integer(spec.itemId) or not revision(spec.itemRevision)) then
        return denied('Expected owned item revision required.')
    end
    if spec.action=='unequip' and (spec.itemId~=nil or spec.itemRevision~=nil) then return denied('Unequip cannot replace an item.') end
    for slot,item in pairs(spec.expected) do
        if type(slot)~='string' or #slot>50 or type(item)~='table'
            or not integer(item.itemId) or not revision(item.revision) then return denied('Invalid expected equipment snapshot.') end
    end
    local safe={characterId=spec.characterId,slot=spec.slot,action=spec.action,itemId=spec.itemId,
        itemRevision=spec.itemRevision,expected={}}
    for slot,item in pairs(spec.expected) do safe.expected[slot]={itemId=item.itemId,revision=item.revision} end
    spec=safe -- caller data must not change while Inventory SQL yields
    local header=tx.query('SELECT id FROM inventory WHERE character_id=? LIMIT 1 FOR UPDATE',{spec.characterId})
    if not header or not header[1] then return denied('Character inventory missing.') end
    local rows=tx.query([[SELECT ce.slot, ce.inventory_items_id, ii.row_revision, inv.character_id AS owner_character
        FROM character_equipment ce LEFT JOIN inventory_items ii ON ii.id=ce.inventory_items_id
        LEFT JOIN inventory inv ON inv.id=ii.inventory_id
        WHERE ce.character_id=? ORDER BY ce.slot FOR UPDATE]],{spec.characterId})
    if type(rows)~='table' then return denied('Equipment snapshot unavailable.') end
    local ids,seen={},{}
    for _,row in ipairs(rows) do
        local expected=spec.expected[row.slot]
        local id,revision=tonumber(row.inventory_items_id),tonumber(row.row_revision)
        if seen[row.slot] or not expected or id~=expected.itemId or revision~=expected.revision
            or row.owner_character~=spec.characterId then return denied('Equipment changed before commit.') end
        seen[row.slot]=true; ids[id]=true
        if spec.action=='equip' and id==spec.itemId and row.slot~=spec.slot then
            return denied('Item already assigned to another slot; explicit move required.')
        end
    end
    for slot in pairs(spec.expected) do if not seen[slot] then return denied('Equipment changed before commit.') end end
    if spec.action=='equip' then
        local owned=tx.query([[SELECT ii.id, ii.row_revision FROM inventory_items ii
            INNER JOIN inventory inv ON inv.id=ii.inventory_id
            WHERE ii.id=? AND inv.character_id=? FOR UPDATE]],{spec.itemId,spec.characterId})
        if not owned or not owned[1] or tonumber(owned[1].row_revision)~=spec.itemRevision then
            return denied('Owned item revision changed.')
        end
        ids[spec.itemId]=true
    elseif not spec.expected[spec.slot] then return denied('Expected slot is not equipped.') end
    for id in pairs(ids) do
        local allowed,reason=GuardsAPI.CanChangeInstance(id,{operation='equipment_write'})
        if allowed~=true then return denied(reason or 'Equipment is still held by its native owner.') end
    end
    if current()~=true then return denied('Session/release authority changed during validation.') end
    tx.query('DELETE FROM character_equipment WHERE character_id=? AND slot=?',{spec.characterId,spec.slot})
    if spec.action=='equip' then
        tx.query('INSERT INTO character_equipment (character_id,slot,inventory_items_id) VALUES (?,?,?)',
            {spec.characterId,spec.slot,spec.itemId})
    end
    if current()~=true then return denied('Session/release authority changed before commit.') end
    return Result.Ok({slot=spec.slot,itemId=spec.action=='equip' and spec.itemId or nil})
end

-- Dev rollback probe: exercises the real Inventory transaction and guard path,
-- never dispatches a native copy or persists an equipment change.
RegisterCommand('InvConditionalEquipmentSmokeTest',function(source,args)
    if source~=0 or Config.DevMode~=true or Config.CharacterAmmunitionEnabled==true
        or GetResourceState('feather-weapons')~='stopped' or GetResourceState('feather-weapons-native-proof')~='stopped'
        or GuardsAPI.HasRegisteredGuard('feather-weapons') then return print('[InvConditionalEquipmentSmokeTest] BLOCKED stopped native owners required') end
    local target=tonumber(args and args[1])
    local session=target and InventoryIdentity.GetSession(target)
    local identity=session and session.ok and session.value
    if not identity or identity.characterId~='6a2fd060-c46f-11f1-9ae2-e0d55eaa2deb' then
        return print('[InvConditionalEquipmentSmokeTest] BLOCKED current Jane required')
    end
    local characterId,sessionId=identity.characterId,identity.sessionId
    local function current()
        return Config.DevMode==true and Config.CharacterAmmunitionEnabled~=true
            and GetResourceState('feather-weapons')=='stopped'
            and GetResourceState('feather-weapons-native-proof')=='stopped'
            and not GuardsAPI.HasRegisteredGuard('feather-weapons')
            and exports['feather-core']:IsSessionCurrent(target,sessionId,characterId)==true
    end
    local checks={}
    local called,result=pcall(function()
        return TransactionAPI.Transaction({resource='feather-inventory',reason='conditional_equipment_rollback_smoke'},function(tx)
            local expected={weapon={itemId=112,revision=1}}
            local stale=ConditionalEquipment.Apply(tx,{characterId=characterId,slot='weapon',action='unequip',expected={}},current)
            checks.staleRejected=not stale.ok
            local unequip=ConditionalEquipment.Apply(tx,{characterId=characterId,slot='weapon',action='unequip',expected=expected},current)
            checks.unequip=unequip.ok==true
            if not unequip.ok then return unequip end
            local equip=ConditionalEquipment.Apply(tx,{characterId=characterId,slot='weapon',action='equip',expected={},itemId=112,itemRevision=1},current)
            checks.equip=equip.ok==true
            if not equip.ok then return equip end
            return Result.Err('rollback_only','Deliberate conditional-equipment smoke rollback.')
        end)
    end)
    if not called or not result or result.ok or not result.error or result.error.code~='rollback_only'
        or not checks.staleRejected or not checks.unequip or not checks.equip then
        return print('[InvConditionalEquipmentSmokeTest] FAIL '..tostring(called and result and result.error and result.error.message or result))
    end
    print('[InvConditionalEquipmentSmokeTest] PASS staleRejected/unequip/equip; transaction deliberately rolled back; no native/ammo changes')
end,true)
