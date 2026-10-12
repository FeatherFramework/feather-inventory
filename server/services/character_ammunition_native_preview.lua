-- Console read-only gate: simulate new item shape locally, never enroll/credit.
CharacterAmmoNativePreview={}
function CharacterAmmoNativePreview.Load()
    local env={Config={},assert=assert,pairs=pairs,ipairs=ipairs,next=next,type=type,
        tonumber=tonumber,tostring=tostring,math=math,table=table,string=string}
    for _,path in ipairs({'shared/constants.lua','shared/definitions/ammunition.lua','shared/definitions/weapons.lua',
        'shared/validation.lua','shared/character_ammunition_catalog.lua','shared/character_ammunition_policy.lua','shared/character_ammunition_item.lua',
        'shared/character_ammunition_materialization.lua','shared/character_ammunition_loadout_lease.lua'}) do
        local text=assert(LoadResourceFile('feather-weapons',path),'Missing trusted Weapons source: '..path)
        local chunk,reason=load(text,'@feather-weapons/'..path,'t',env)
        assert(chunk,reason); chunk()
    end
    return env.WeaponDefinitionCatalog,env.WeaponCharacterAmmoCatalog,env.WeaponCharacterAmmoItem,
        env.WeaponCharacterAmmoMaterialization,env.WeaponCharacterAmmoLoadoutLease,env.WeaponCharacterAmmoPolicy
end
local function copy(v)
    if type(v)~='table' then return v end
    local out={}; for k,x in pairs(v) do out[k]=copy(x) end; return out
end
function CharacterAmmoNativePreview.Build(rows,catalog,registry,itemContract,strict)
    local slots={weapon='primary',weapon_offhand='offhand',weapon_shoulder='shoulder',weapon_back='back'}
    local selected={}
    for _,row in ipairs(rows) do
        local slot=slots[row.equipped_slot]
        if slot then
            if selected[slot] or row.owned~=true then return nil,'invalid_equipment_ownership' end
            local ok,metadata=true,row.metadata
            if type(metadata)~='table' then ok,metadata=pcall(json.decode,metadata or '') end
            if not ok or type(metadata)~='table' or type(metadata.ammo)~='table' then return nil,'invalid_weapon_metadata' end
            local converted=copy(metadata)
            -- Quantity conservation/enrollment is a separate already-tested transaction.
            -- This preview gives NO credit and changes no source metadata.
            if not strict then converted.ammo={ownership='character',type=metadata.ammo.type} end
            selected[slot]={id=tonumber(row.id),revision=tonumber(row.row_revision),itemName=row.itemName,metadata=converted}
        end
    end
    return itemContract.Loadout(selected,catalog,registry)
end
RegisterCommand('InvCharacterAmmoNativePlanPreview',function(source,args)
    if source~=0 or not Config.DevMode then return end
    local prefix='[InvCharacterAmmoNativePlanPreview] '
    if GetResourceState('feather-weapons')~='stopped' then print(prefix..'BLOCKED: keep Weapons stopped'); return end
    local target=tonumber(args and args[1]); local session=target and InventoryIdentity.GetSession(target)
    if not session or not session.ok then print(prefix..'Connected character required'); return end
    local loaded,catalog,catalogContract,itemContract,materialization,lease,policyContract=pcall(CharacterAmmoNativePreview.Load)
    if not loaded then print(prefix..'FAIL '..tostring(catalog)); return end
    local registry,reason=policyContract.Build(catalog)
    if not registry then print(prefix..'FAIL '..tostring(reason)); return end
    local character=session.value.characterId
    -- One joined query is a consistent statement snapshot; no locks/writes/repair.
    local rows=DB.raw([[SELECT ce.slot AS equipped_slot, ii.id, ii.row_revision, ii.metadata,
        i.name AS itemName, inv.character_id AS owner_character
        FROM character_equipment ce LEFT JOIN inventory_items ii ON ii.id=ce.inventory_items_id
        LEFT JOIN items i ON i.id=ii.item_id LEFT JOIN inventory inv ON inv.id=ii.inventory_id
        WHERE ce.character_id=? ORDER BY ce.slot]],character)
    if type(rows)~='table' then print(prefix..'FAIL reading equipment'); return end
    if exports['feather-core']:IsSessionCurrent(target,session.value.sessionId,character)~=true then
        print(prefix..'BLOCKED: session changed'); return
    end
    for _,row in ipairs(rows) do row.owned=row.owner_character==character end
    local plan
    plan,reason=CharacterAmmoNativePreview.Build(rows,catalog,registry,itemContract)
    if not plan then print(prefix..'BLOCKED '..tostring(reason)); return end
    local count=0
    for _,slot in ipairs({'primary','offhand','shoulder','back'}) do
        local item=plan.slots[slot]
        if item then
            count=count+1
            print(prefix..('slot=%s item=%s revision=%s definition=%s point=%d attachments=%d preferred=%s'):format(
                slot,item.itemInstanceId,item.itemRevision,item.definitionId,item.point,#item.attachments,item.preferredAmmoType))
        end
    end
    print(prefix..('PASS firearms=%d dual=%s sameModel=%s; simulated character ownership only; no rows/native/ammo credits changed; caps=approved_native_readback_policy; productionReady=false'):format(
        count,tostring(plan.dual),tostring(plan.sameModel)))
end,true)
