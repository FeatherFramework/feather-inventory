-- Actual read projections/export with mocked SQL: compare legacy query layout
-- against the installed transaction-local shared read, not a cached response.
local function copy(v) if type(v)~='table' then return v end; local r={}; for k,x in pairs(v) do r[k]=copy(x) end; return r end
local function equal(a,b)
 if type(a)~=type(b) then return false end; if type(a)~='table' then return a==b end
 for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
 for k in pairs(b) do if a[k]==nil then return false end end; return true
end
Result={Codes={DENIED='denied',CONFLICT='conflict',NOT_FOUND='missing'},Ok=function(v) return {ok=true,value=v} end,
 Err=function(c,m) return {ok=false,error={code=c,message=m}} end}
Config={DevMode=true,CharacterAmmunitionEnabled=true}
InventoryIdentity={NormalizeCharacterId=function(v) return v=='john' and v or nil end}
RegisterCommand=function() end
json={decode=function(v) return copy(v) end}
local active,drop,queries=true,nil,{}
local flags={feather_native_melee=1,feather_native_throwable=1,feather_native_utility=1,feather_native_lasso_reinforced=1}
GetConvarInt=function(n,default) return flags[n] or default end
GetInvokingResource=function() return 'feather-weapons' end
local registered={}
exports=setmetatable({['feather-core']={IsSessionCurrent=function() return active end}},
 {__call=function(_,name,fn) registered[name]=fn end})
local rows,items={},{}
local function add(slot,id,name,definition,ammo)
 local metadata={schemaVersion=2,weaponDefinitionId=definition,serialNumber='S'..id}
 if ammo then metadata.ammo={ownership='character',type=ammo} end
 local r={slot=slot,equipped_slot=slot,inventory_items_id=id,id=id,row_revision=0,metadata=metadata,itemName=name,owner_character='john'}
 rows[#rows+1]=r; items[id]=r
end
add('weapon',155,'weapon_revolver_cattleman','revolver_cattleman','ammo_revolver_regular')
add('weapon_offhand',158,'weapon_revolver_cattleman','revolver_cattleman','ammo_revolver_regular')
for n,name in ipairs({'knife','hatchet','machete','hammer','cleaver'}) do
 add(({'weapon_melee','weapon_melee_secondary','weapon_melee_tertiary','weapon_melee_quaternary','weapon_melee_quinary'})[n],
  159+n,'weapon_melee_'..name,'melee_'..name)
end
add('weapon_throwable',165,'weapon_thrown_tomahawk','throwable_tomahawk','ammo_tomahawk_regular')
add('weapon_utility_secondary',172,'weapon_lasso_reinforced','utility_lasso_reinforced')
items[171]={id=171,row_revision=0,itemName='weapon_lasso',metadata={schemaVersion=2,weaponDefinitionId='utility_lasso',serialNumber='S171'}}
local tx={query=function(sql,args)
 queries[#queries+1]=sql
 assert(sql:find('SELECT',1,true)==1 and sql:find('FOR UPDATE',1,true),'read-only locked queries required')
 if #queries==drop then active=false end
 if sql:find('SELECT id FROM inventory',1,true)==1 then return {{id=5}} end
 if sql:find('SELECT revision, pools',1,true)==1 then return {{revision=16,pools={ammo_revolver_regular=0,ammo_tomahawk_regular=1}}} end
 if sql:find('FROM character_equipment',1,true) then
  if sql:find('ce.slot IN',1,true) then return {copy(rows[1]),copy(rows[2])} end
  return copy(rows)
 end
 if sql:find('SELECT ii.id',1,true)==1 then return items[args[1]] and {copy(items[args[1]])} or {} end
 error(sql)
end}
TransactionAPI={Transaction=function(_,body) return body(tx) end}
dofile('server/services/character_ammunition.lua'); dofile('server/services/native_knife_equipment.lua')
dofile('server/internal/native_utility_equipment.lua'); dofile('server/services/native_equipment_commit.lua')
local context={actorSource=12,characterId='john',sessionId='s'}
local limits={ammo_revolver_regular=200,ammo_tomahawk_regular=1}
local old=assert(CharacterAmmunitionAPI.RuntimeSnapshot(context,limits,'feather-weapons').value)
assert(#queries==16,'unoptimized current companion layout should issue16 queries')
queries={}; local oldPreflight=assert(registered.ReadNativeEquipmentTransition(context,171).value)
assert(#queries==17)
dofile('server/internal/native_equipment_snapshot.lua')
queries={}; local optimized=assert(CharacterAmmunitionAPI.RuntimeSnapshot(context,limits,'feather-weapons').value)
assert(equal(old,optimized) and #queries==3,'same projections with3 queries, not16')
queries={}; local preflight=assert(registered.ReadNativeEquipmentTransition(context,171).value)
assert(equal(oldPreflight,preflight) and #queries==3,'unassigned candidate preflight3 queries, not17')
queries={}; assert(registered.ReadNativeEquipmentTransition(context,172).ok and #queries==2,'assigned candidate reuses locked row')
local captured
queries={}; assert(NativeEquipmentSnapshot.With(tx,'john',function() return active end,false,function(cap)
 captured=cap; assert(cap.ReadEquipment({},'john')==nil and cap.ReadEquipment(tx,'jane')==nil)
 local a=cap.ReadEquipment(tx,'john'); a[1].metadata.serialNumber='mutated'
 assert(cap.ReadEquipment(tx,'john')[1].metadata.serialNumber=='S155')
 return Result.Ok(true)
end).ok)
assert(captured.ReadEquipment(tx,'john')==nil and captured.ReadItem(tx,'john',155)==nil,'scope expires, even in same transaction handle')
local expiredQueries=#queries
assert(not NativeMeleeEquipment.Read(tx,'john',nil,function() return true end,captured).ok)
assert(not NativeUtilityEquipment.Read(tx,'john',function() return true end,captured).ok)
assert(not CharacterAmmunitionAPI.ReadRuntimeEquipment(tx,'john',captured).ok)
assert(#queries==expiredQueries,'expired capabilities refuse rather than silently fetching or reusing data')
queries={}; local ok=pcall(NativeEquipmentSnapshot.With,tx,'john',function() return true end,false,function(cap)
 captured=cap; error('body failed')
end)
assert(not ok and captured.ReadEquipment(tx,'john')==nil,'exception also expires scope')
for i=1,3 do
 active=true; drop=i; queries={}
 assert(not CharacterAmmunitionAPI.RuntimeSnapshot(context,limits,'feather-weapons').ok,'authority loss after any SQL refuses')
end
drop=nil; active=true
rows[1].owner_character='foreign'; queries={}
assert(not CharacterAmmunitionAPI.RuntimeSnapshot(context,limits,'feather-weapons').ok)
rows[1].owner_character='john'; rows[1].row_revision=1; queries={}
assert(CharacterAmmunitionAPI.RuntimeSnapshot(context,limits,'feather-weapons').value.equipment.primary.revision==1,'new transaction reads fresh revision')
for _,change in ipairs({
 {row=rows[1],key='metadata',value={ammo={ownership='character',type='ammo_revolver_regular',loaded=0}}},
 {row=rows[3],key='itemName',value='foreign'},
 {row=rows[8],key='metadata',value={schemaVersion=2,weaponDefinitionId='throwable_tomahawk',ammo={ownership='character',type='ammo_tomahawk_regular',quantity=1}}},
 {row=rows[9],key='itemName',value='weapon_lasso'},
}) do
 local previous=change.row[change.key]; change.row[change.key]=change.value; queries={}
 assert(not CharacterAmmunitionAPI.RuntimeSnapshot(context,limits,'feather-weapons').ok,'shared read preserves per-family metadata refusal')
 change.row[change.key]=previous
end
print('shared locked native snapshots PASS: runtime16->3/preflight17->3 queries, identical data, scoped expiry/exception/current ownership checks; mocked SQL')
