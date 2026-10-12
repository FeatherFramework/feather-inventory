Result={Codes={DENIED='denied',CONFLICT='conflict',NOT_FOUND='missing'},
    Ok=function(value) return {ok=true,value=value} end,Err=function(code,message) return {ok=false,error={code=code,message=message}} end}
Config={CharacterAmmunitionEnabled=false}
RegisterCommand=function() end
local current=true
exports={['feather-core']={IsSessionCurrent=function() return current end}}
json={decode=function(v) return v end}
dofile('server/services/character_ammunition.lua')
local row={equipped_slot='weapon',id=1,row_revision=5,itemName='weapon_pistol_m1899',owner_character='char',
    metadata={ammo={ownership='character',type='ammo_pistol_regular'}}}
local queries={}
local expire=false
local tx={query=function(sql)
    queries[#queries+1]=sql
    assert(sql:find('FOR UPDATE',1,true),'snapshot lock required')
    if sql:find('SELECT id FROM inventory',1,true) then return {{id=1}} end
    if sql:find('SELECT revision, pools',1,true) then return {{revision=2,pools={ammo_pistol_regular=7}}} end
    if sql:find('FROM character_equipment',1,true) then if expire then current=false end; return {row} end
    error(sql)
end}
TransactionAPI={Transaction=function(_,body) return body(tx) end}
local context={actorSource=1,characterId='char',sessionId='session'}
local limits={ammo_pistol_regular=200}
assert(not CharacterAmmunitionAPI.RuntimeSnapshot(context,limits,'feather-weapons').ok)
Config.CharacterAmmunitionEnabled=true
assert(not CharacterAmmunitionAPI.RuntimeSnapshot(context,limits,'foreign').ok)
local result=CharacterAmmunitionAPI.RuntimeSnapshot(context,limits,'feather-weapons')
assert(result.ok and result.value.pools.ammo_pistol_regular==7 and result.value.revision==2)
assert(result.value.equipment.primary.id==1 and result.value.equipment.primary.revision==5 and #queries==3)
row.owner_character='foreign'; assert(not CharacterAmmunitionAPI.RuntimeSnapshot(context,limits,'feather-weapons').ok)
row.owner_character='char'; row.metadata.ammo.loaded=0
assert(not CharacterAmmunitionAPI.RuntimeSnapshot(context,limits,'feather-weapons').ok,'even zero legacy clip forbidden')
row.metadata.ammo.loaded=nil; expire=true
assert(not CharacterAmmunitionAPI.RuntimeSnapshot(context,limits,'feather-weapons').ok,'session checked after all reads')
print('character_ammo_runtime_snapshot_spec PASS (gate, lock order, belt/equipment identity, ownership, strict ammo, session)')
