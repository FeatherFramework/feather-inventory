-- Read-only admin preview while Weapons remains stopped. Fixed trusted source
-- files are loaded from the Weapons resource; no client-supplied code or SQL.
CharacterAmmoCutoverPreview = {}
function CharacterAmmoCutoverPreview.LoadRuntime()
    local environment={assert=assert,pairs=pairs,ipairs=ipairs,next=next,type=type,
        tonumber=tonumber,tostring=tostring,math=math,table=table}
    for _,path in ipairs({'shared/character_ammunition.lua','shared/character_ammunition_runtime.lua'}) do
        local source=LoadResourceFile('feather-weapons',path)
        assert(source,'Missing Weapons runtime source: '..path)
        local chunk,failure=load(source,'@feather-weapons/'..path,'t',environment)
        assert(chunk,failure); chunk()
    end
    return environment.WeaponCharacterAmmoRuntime
end
function CharacterAmmoCutoverPreview.Load()
    local environment={Config={},assert=assert,next=next,pairs=pairs,ipairs=ipairs,type=type,tonumber=tonumber,
        tostring=tostring,math=math,table=table}
    for _,path in ipairs({'shared/definitions/ammunition.lua','shared/definitions/weapons.lua',
        'shared/ammunition_migration_preview.lua','shared/character_ammunition_catalog.lua',
        'shared/character_ammunition_policy.lua'}) do
        local source=LoadResourceFile('feather-weapons',path)
        assert(source,'Missing Weapons preview source: '..path)
        local chunk,failure=load(source,'@feather-weapons/'..path,'t',environment)
        assert(chunk,failure); chunk()
    end
    local registry,reason=environment.WeaponCharacterAmmoPolicy.Build(environment.WeaponDefinitionCatalog)
    assert(registry,reason)
    return environment.WeaponDefinitionCatalog,environment.WeaponAmmoMigrationPreview,registry.limits
end
RegisterCommand('InvCharacterAmmoMigrationPreview',function(source,args)
    if source~=0 or not Config.DevMode then return end
    local prefix='[InvCharacterAmmoMigrationPreview] '
    if GetResourceState('feather-weapons')=='started' then
        print(prefix..'BLOCKED: keep production Weapons stopped during preview'); return
    end
    local target=tonumber(args and args[1])
    local session=target and InventoryIdentity.GetSession(target)
    if not session or not session.ok then print(prefix..'Connected target character required'); return end
    local characterId=session.value.characterId
    if args[2]~=nil and args[2]~=characterId then
        print(prefix..'BLOCKED: expected character UUID does not match active player'); return
    end
    print(prefix..('identity serverId=%s characterId=%s; read-only'):format(target,characterId))
    local ok,catalog,planner,limits=pcall(CharacterAmmoCutoverPreview.Load)
    if not ok then print(prefix..'FAIL '..tostring(catalog)); return end
    -- Exact trusted policy, validated against the full firearm catalog.
    local rows,ledger
    local queried,committed=pcall(DB.transaction,function(tx)
        rows=tx.raw([[SELECT ii.id, ii.row_revision, ii.metadata, i.name, i.type
            FROM inventory_items ii INNER JOIN items i ON i.id=ii.item_id
            INNER JOIN inventory inv ON inv.id=ii.inventory_id
            WHERE inv.character_id=? ORDER BY ii.id]],characterId)
        local tables=tx.raw([[SELECT TABLE_NAME FROM information_schema.TABLES
            WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='feather_character_ammunition']])
        if tables and #tables>0 then
            local found=tx.raw('SELECT revision, pools FROM feather_character_ammunition WHERE character_id=?',characterId)
            ledger=found and found[1]
        end
        return true
    end)
    if not queried or committed~=true or type(rows)~='table' then print(prefix..'FAIL reading snapshot '..tostring(committed)); return end
    if exports['feather-core']:IsSessionCurrent(target,session.value.sessionId,characterId)~=true then
        print(prefix..'BLOCKED: session changed during read'); return
    end
    local items={}
    for _,row in ipairs(rows or {}) do
        local parsed,metadata=true,row.metadata
        if type(metadata)~='table' then parsed,metadata=pcall(json.decode,row.metadata or '') end
        items[#items+1]={id=tonumber(row.id),name=row.name,type=row.type,
            revision=tonumber(row.row_revision),metadata=parsed and metadata or nil}
    end
    local built,plan=pcall(planner.Build,items,catalog,limits)
    if not built then print(prefix..'FAIL preview calculation '..tostring(plan)); return end
    plan.characterId=characterId
    plan.alreadyEnrolled=ledger~=nil
    if ledger then plan.validationPassed=false end
    print(prefix..('READ ONLY firearms=%d accepted=%d issues=%d overflow=%d enrolled=%s validation=%s'):format(
        plan.firearmCount,#plan.items,#plan.issues,#plan.overflow,tostring(plan.alreadyEnrolled),
        plan.validationPassed and 'PASS' or 'BLOCKED'))
    for _,item in ipairs(plan.items) do print(prefix..'item '..json.encode(item)) end
    for _,problem in ipairs(plan.issues) do print(prefix..'issue '..json.encode(problem)) end
    for _,overflow in ipairs(plan.overflow) do print(prefix..'overflow '..json.encode(overflow)) end
    print(prefix..'carried '..json.encode(plan.pools))
    print(prefix..'native '..json.encode(plan.nativePools))
    print(prefix..'loose inventory (NOT credited) '..json.encode(plan.loose))
    print(prefix..'excluded non-firearms '..json.encode(plan.excluded))
    print(prefix..'No rows/metadata/native state changed; caps=approved_native_readback_policy; productionReady=false')
end,true)
