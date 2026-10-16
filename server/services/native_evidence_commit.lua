-- Native evidence-only transaction and trusted reservation export. No player route.
NativeEvidenceCommit={}
local function denied(message) return Result.Err('native_evidence_refused',message) end
local function integer(v,min) return type(v)=='number' and v>=min and v%1==0 and v<math.huge end
local function callable(v) return type(v)=='function' or type(v)=='table' and type(rawget(v,'__cfx_functionReference'))=='string' end
local function copy(v)
    if type(v)~='table' then return v end
    local out={}; for k,x in pairs(v) do out[k]=copy(x) end; return out
end

-- The transaction is owned here; Weapons supplies the exact one-use authority.
if type(GetInvokingResource)=='function' then
exports('CommitNativeEvidenceTransition',function(context,spec)
    if GetInvokingResource()~='feather-weapons' or Config.DevMode~=true
        or Config.CharacterAmmunitionEnabled~=true or type(context)~='table' or type(spec)~='table'
        or context.characterId~=spec.characterId then return denied('Trusted native evidence caller required.') end
    context,spec=copy(context),copy(spec)
    local function current()
        if Config.DevMode~=true or Config.CharacterAmmunitionEnabled~=true
            or GetResourceState('feather-weapons')~='started' then return false end
        local ok,allowed=pcall(function()
            return exports['feather-core']:IsSessionCurrent(context.actorSource,context.sessionId,context.characterId)==true
                and exports['feather-weapons']:ValidateNativeEvidenceCommit(context,spec)==true
        end)
        return ok and allowed==true
    end
    if not current() then return denied('Current reserved evidence authority required.') end
    return TransactionAPI.Transaction({resource='feather-inventory',reason=spec.held and 'native_evidence_hold' or 'native_evidence_release',
        actorSource=context.actorSource,characterId=context.characterId,sessionId=context.sessionId},function(tx)
        local result=NativeEvidenceCommit.Apply(tx,spec,current)
        if not result.ok then return result end
        if not current() then return denied('Evidence authority changed before commit; rollback required.') end
        return result
    end)
end)
end
local function equal(a,b)
    if type(a)~=type(b) then return false end
    if type(a)~='table' then return a==b end
    for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end
    return true
end
function NativeEvidenceCommit.Apply(tx,spec,current)
    if type(spec)~='table' or not callable(current) or current()~=true
        or type(spec.characterId)~='string' or spec.characterId==''
        or not integer(spec.itemId,1) or not integer(spec.itemRevision,0)
        or type(spec.serialNumber)~='string' or spec.serialNumber==''
        or type(spec.weaponDefinitionId)~='string' or spec.weaponDefinitionId==''
        or type(spec.itemName)~='string' or spec.itemName==''
        or type(spec.held)~='boolean' or type(spec.before)~='table'
        or type(spec.before.flags)~='table' or type(spec.before.flags.evidence)~='boolean'
        or spec.before.flags.evidence==spec.held
        or spec.before.serialNumber~=spec.serialNumber
        or spec.before.weaponDefinitionId~=spec.weaponDefinitionId then
        return denied('Exact authorized evidence reservation required.')
    end
    spec=copy(spec)
    local header=tx.query('SELECT id FROM inventory WHERE character_id=? LIMIT 1 FOR UPDATE',{spec.characterId})
    local inventoryId=header and header[1] and tonumber(header[1].id)
    if current()~=true or not integer(inventoryId,1) then return denied('Current owned inventory required.') end
    local function unequipped()
        local rows=tx.query([[SELECT slot, inventory_items_id FROM character_equipment
            WHERE character_id=? ORDER BY slot FOR UPDATE]],{spec.characterId})
        if current()~=true or type(rows)~='table' then return false end
        for _,row in ipairs(rows) do
            if tonumber(row.inventory_items_id)==spec.itemId then return false end
        end
        return true
    end
    if not unequipped() then return denied('Unequip the weapon before changing evidence state.') end
    local locked=tx:GetItemForUpdate(spec.itemId)
    local item=locked and locked.ok and locked.value
    if current()~=true or type(item)~='table' or item.id~=spec.itemId or item.inventoryId~=inventoryId
        or item.revision~=spec.itemRevision or type(item.definition)~='table'
        or item.definition.name~=spec.itemName or not equal(item.metadata,spec.before) then
        return denied('Weapon owner, definition, serial or revision changed.')
    end
    local after=copy(item.metadata)
    after.flags.evidence=spec.held -- sole permitted metadata delta, derived here
    local written=tx:SetMetadata(spec.itemId,after,spec.itemRevision)
    if current()~=true or not written or not written.ok then return denied('Evidence authority or revision changed; rollback required.') end
    if not unequipped() then return denied('Equipment changed during evidence mutation; rollback required.') end
    return Result.Ok({itemId=spec.itemId,revision=spec.itemRevision+1,held=spec.held,
        serialNumber=spec.serialNumber,inventoryId=inventoryId,metadata=copy(after),
        noAmmoOrMaterialWrites=true})
end
