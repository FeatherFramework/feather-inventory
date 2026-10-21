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
current=true; expire=false; Config.DevMode=true
local knifeFlag,knifeReads,meleeFlag,throwableFlag,utilityFlag=1,0,0,0,0
GetConvarInt=function(name)
 if name=='feather_native_utility' then return utilityFlag end
 if name=='feather_native_throwable' then return throwableFlag end
 if name=='feather_native_melee' then return meleeFlag end
 assert(name=='feather_native_knife'); return knifeFlag
end
NativeKnifeEquipment={Read=function(transaction,cid,itemId,authority)
 assert(transaction==tx and cid=='char' and itemId==nil and authority(),'knife must share locked firearm snapshot transaction')
 knifeReads=knifeReads+1
 return Result.Ok({characterId=cid,expected={},equipment={}})
end}
result=CharacterAmmunitionAPI.RuntimeSnapshot(context,limits,'feather-weapons')
assert(result.ok and result.value.knifeEquipment.characterId=='char' and knifeReads==1)
knifeFlag=0
result=CharacterAmmunitionAPI.RuntimeSnapshot(context,limits,'feather-weapons')
assert(result.ok and result.value.knifeEquipment==nil and knifeReads==1,'default-off keeps original snapshot graph')
knifeFlag=1; NativeKnifeEquipment=nil
assert(not CharacterAmmunitionAPI.RuntimeSnapshot(context,limits,'feather-weapons').ok,'partial deployment fails before dispatch')
print('knife atomic snapshot seam PASS (same Inventory transaction, default-off no extra read, missing component refusal)')
local meleeReads=0
meleeFlag=1
NativeMeleeEquipment={Read=function(transaction,cid,itemId,authority)
 assert(transaction==tx and cid=='char' and itemId==nil and authority())
 meleeReads=meleeReads+1
 return Result.Ok({characterId=cid,expected={},equipment={}})
end}
result=CharacterAmmunitionAPI.RuntimeSnapshot(context,limits,'feather-weapons')
assert(result.ok and result.value.meleeEquipment.characterId=='char' and result.value.knifeEquipment==nil
 and meleeReads==1 and knifeReads==1,'aggregate snapshot replaces single knife, never double ownership')
NativeMeleeEquipment=nil
assert(not CharacterAmmunitionAPI.RuntimeSnapshot(context,limits,'feather-weapons').ok)
print('aggregate melee atomic snapshot PASS (same transaction, exclusive companion snapshot, partial deployment refusal)')
meleeFlag=0; knifeFlag=0; throwableFlag=1
assert(not CharacterAmmunitionAPI.RuntimeSnapshot(context,limits,'feather-weapons').ok,'throwable limit must be explicit')
limits.ammo_tomahawk_regular=1
local throwableReads=0
NativeThrowableEquipment={Read=function(transaction,cid,itemId,authority)
 assert(transaction==tx and cid=='char' and itemId==nil and authority())
 throwableReads=throwableReads+1
 return Result.Ok({characterId=cid,expected={},equipment={}})
end}
result=CharacterAmmunitionAPI.RuntimeSnapshot(context,limits,'feather-weapons')
assert(result.ok and throwableReads==1 and result.value.throwableEquipment.revision==2
 and result.value.throwableEquipment.pools.ammo_tomahawk_regular==0)
assert(result.value.throwableEquipment.pools~=result.value.pools,'private child ledger projection')
NativeThrowableEquipment=nil
assert(not CharacterAmmunitionAPI.RuntimeSnapshot(context,limits,'feather-weapons').ok)
print('throwable atomic snapshot PASS: explicit policy, same locked transaction/revision/balances, missing component refusal')
throwableFlag=0; utilityFlag=1
assert(not CharacterAmmunitionAPI.RuntimeSnapshot(context,limits,'feather-weapons').ok,'missing utility reader refuses partial deployment')
local utilityReads=0
NativeUtilityEquipment={Read=function(transaction,cid,authority)
 assert(transaction==tx and cid=='char' and authority(),'utility shares the locked ledger transaction')
 utilityReads=utilityReads+1
 return Result.Ok({characterId=cid,expected={},equipment={}})
end}
result=CharacterAmmunitionAPI.RuntimeSnapshot(context,limits,'feather-weapons')
assert(result.ok and utilityReads==1 and result.value.utilityEquipment.characterId=='char')
utilityFlag=0
result=CharacterAmmunitionAPI.RuntimeSnapshot(context,limits,'feather-weapons')
assert(result.ok and result.value.utilityEquipment==nil and utilityReads==1,'utility default-off bypasses reader')
print('utility atomic snapshot PASS: same transaction, missing component refusal and disabled gate isolation')
