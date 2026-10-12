Config={DevMode=true}
local commands={}
RegisterCommand=function(name,fn) commands[name]=fn end
LoadResourceFile=function(resource,path)
    assert(resource=='feather-weapons')
    local f=assert(io.open('../feather-weapons/'..path)); local text=f:read('*a'); f:close(); return text
end
dofile('server/services/character_ammunition_native_preview.lua')
local catalog,contract,item,materialization,lease,policy=CharacterAmmoNativePreview.Load()
local registry=assert(policy.Build(catalog))
assert(registry.limits.ammo_pistol_regular==100 and registry.limits.ammo_rifle_split_point==50
    and registry.limits.ammo_shotgun_slug==60)
dofile('server/services/character_ammunition_preview.lua')
local cutoverCatalog,planner,limits=CharacterAmmoCutoverPreview.Load()
assert(limits.ammo_pistol_regular==registry.limits.ammo_pistol_regular
    and limits.ammo_varmint_tranquilizer==200)
limits.ammo_pistol_regular=999
local _,_,fresh=CharacterAmmoCutoverPreview.Load()
assert(fresh.ammo_pistol_regular==100)
local originalLoader=LoadResourceFile
LoadResourceFile=function(resource,path)
    if path=='shared/character_ammunition_policy.lua' then return nil end
    return originalLoader(resource,path)
end
assert(not pcall(CharacterAmmoCutoverPreview.Load),'missing policy must fail closed')
assert(not pcall(CharacterAmmoNativePreview.Load),'native preview must not fallback')
LoadResourceFile=originalLoader
local function row(id,slot,weapon)
    local def=catalog.weapons[weapon]
    return {id=id,row_revision=3,itemName=def.itemName,equipped_slot=slot,owned=true,owner_character='character',
        metadata={schemaVersion=2,weaponDefinitionId=weapon,serialNumber='serial-'..id,condition=100,quality=100,
        maintenance={degradation=0,permanentDegradation=0,damage=0,dirt=0,soot=0},
        ammo={type=def.ammunitionType,loaded=3,reserve=2},attachments={},cosmetics={},
        flags={stolen=false,evidence=false,disabled=false},provenance={}}}
end
local rows={row(1,'weapon','pistol_m1899'),row(12,'weapon_offhand','pistol_semiauto'),
    row(52,'weapon_shoulder','repeater_carbine'),row(53,'weapon_back','repeater_lancaster')}
local plan=assert(CharacterAmmoNativePreview.Build(rows,catalog,registry,item))
assert(plan.dual and not plan.sameModel and plan.slots.shoulder.point==10 and plan.slots.back.point==9)
assert(plan.slots.primary.ammo==nil and rows[1].metadata.ammo.loaded==3 and rows[1].metadata.ammo.ownership==nil)
assert(not CharacterAmmoNativePreview.Build(rows,catalog,registry,item,true),'strict mode cannot fabricate enrollment')
rows[2].owned=false; assert(not CharacterAmmoNativePreview.Build(rows,catalog,registry,item)); rows[2].owned=true
rows[2].id=1; assert(not CharacterAmmoNativePreview.Build(rows,catalog,registry,item)); rows[2].id=12
GetResourceState=function() return 'stopped' end
InventoryIdentity={GetSession=function() return {ok=true,value={characterId='character',sessionId='session'}} end}
exports={['feather-core']={IsSessionCurrent=function() return true end}}
local reads=0
DB={raw=function(sql,character) assert(sql:match('^SELECT') and character=='character'); reads=reads+1; return rows end}
local output={}; print=function(line) output[#output+1]=line end
commands.InvCharacterAmmoNativePlanPreview(0,{'1'})
assert(reads==1 and output[#output]:find('PASS firearms=4 dual=true sameModel=false',1,true))
exports['feather-core'].IsSessionCurrent=function() return false end
commands.InvCharacterAmmoNativePlanPreview(0,{'1'})
assert(output[#output]:find('session changed',1,true))
io.write('character_ammo_native_preview_spec PASS (trusted loader, four slots, immutable metadata, ownership and session checks)\n')
exports['feather-core'].IsSessionCurrent=function() return true end
local previewReads=0
json={encode=function() return '{}' end}
DB.transaction=function(body)
    return body({raw=function(sql)
        assert(sql:find('SELECT',1,true)); previewReads=previewReads+1; return {}
    end})
end
commands.InvCharacterAmmoMigrationPreview(0,{'1','other-character'})
assert(previewReads==0 and output[#output]:find('UUID does not match',1,true),
    'source reuse must not inspect a different character for dedicated gate')
commands.InvCharacterAmmoMigrationPreview(0,{'1','character'})
assert(previewReads==2 and output[#output]:find('No rows/metadata/native state changed',1,true))
io.write('migration preview expected-character binding PASS (wrong identity refused before SQL)\n')
