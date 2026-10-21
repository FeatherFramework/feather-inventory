Result={Ok=function(v) return {ok=true,value=v} end,Err=function(c,m) return {ok=false,error={code=c,message=m}} end}
InventoryIdentity={NormalizeCharacterId=function(v) return v=='john' and v or nil end}
RegisterCommand=function() end
local function copy(v) if type(v)~='table' then return v end; local r={}; for k,x in pairs(v) do r[k]=copy(x) end; return r end
local function equal(a,b)
 if type(a)~=type(b) then return false end; if type(a)~='table' then return a==b end
 for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
 for k in pairs(b) do if a[k]==nil then return false end end; return true
end
InventoryMetadata={DocumentsEqual=equal}
local gate,davy,binoculars,camera=1,0,0,0
GetConvarInt=function(name) return name=='feather_native_lasso_reinforced' and gate or name=='feather_native_davy_lantern' and davy or name=='feather_native_binoculars' and binoculars or name=='feather_native_camera' and camera or 0 end
dofile('server/services/conditional_equipment.lua')
local U=dofile('server/internal/native_utility_equipment.lua')
local assigned,writes={weapon=155},0
local items={}
for id,name in pairs({[200]='utility_lasso',[201]='utility_lasso_reinforced'}) do
 items[id]={id=id,row_revision=0,itemName=name=='utility_lasso' and 'weapon_lasso' or 'weapon_lasso_reinforced',
 metadata={schemaVersion=2,weaponDefinitionId=name,serialNumber='L'..id,condition=100,flags={disabled=false,evidence=false}}}
end
GuardsAPI={CanChangeInstance=function() return true end}
local tx={query=function(sql,args)
 if sql:find('SELECT id FROM inventory',1,true)==1 then return {{id=5}} end
 if sql:find('SELECT ce.slot',1,true)==1 then
  local rows={}; for slot,id in pairs(assigned) do rows[#rows+1]={slot=slot,inventory_items_id=id,
   row_revision=id==155 and 3 or 0,owner_character='john'} end; return rows
 end
 if sql:find('SELECT ii.id',1,true)==1 then return items[args[1]] and {copy(items[args[1]])} or {} end
 assert(sql:find('character_equipment',1,true),'no ammo/material/item metadata writes')
 writes=writes+1
 if sql:find('DELETE',1,true)==1 then assigned[args[2]]=nil
 elseif sql:find('INSERT',1,true)==1 then assigned[args[2]]=args[3] else error(sql) end
 return {}
end}
local function intent(action,slot,id)
 local read=assert(U.Read(tx,'john',function() return true end).value)
 return {characterId='john',action=action,slot=slot,utilityId=id,utilityRevision=0,
  expected=read.expected,before=copy(items[id].metadata)}
end
local function run(spec) return U.Apply(tx,spec,function() return true end) end
assert(run(intent('equip','weapon_utility',200)).ok)
local before=writes
assert(not run(intent('equip','weapon_utility_secondary',201)).ok and writes==before)
assert(not run(intent('equip','weapon_utility',201)).ok and writes==before,'replacement also requires explicit unequip')
assert(run(intent('unequip','weapon_utility',200)).ok)
assert(run(intent('equip','weapon_utility_secondary',201)).ok)
local snapshot=assert(U.Read(tx,'john',function() return true end).value)
assert(snapshot.equipment.utility_secondary.id==201 and snapshot.expected.weapon.itemId==155)
before=writes
assert(not run(intent('equip','weapon_utility',200)).ok and writes==before)
assigned.weapon_utility=200
assert(not U.Read(tx,'john',function() return true end).ok and writes==before,'invalid saved dual lasso is refused without reconciliation')
assigned.weapon_utility=nil
gate=0
assert(not U.Read(tx,'john',function() return true end).ok,'disabled secondary assignment must not silently disappear from loadout')
assert(not run({characterId='john',action='unequip',slot='weapon_utility_secondary',utilityId=201,utilityRevision=0,
 expected=snapshot.expected,before=items[201].metadata}).ok and writes==before)
assert(items[200].metadata.serialNumber=='L200' and items[201].metadata.serialNumber=='L201' and assigned.weapon==155)
print('reinforced lasso Inventory PASS: exact two-slot ownership, one-family refusal, explicit switching, no owned-item deletion or ammo writes; mocked SQL')
gate,davy=1,1
items[202]={id=202,row_revision=0,itemName='weapon_melee_davy_lantern',
 metadata={schemaVersion=2,weaponDefinitionId='utility_davy_lantern',serialNumber='D202',condition=100,flags={disabled=false,evidence=false}}}
-- Swap placement: reinforced already secondary, Davy uses primary.
assert(run(intent('equip','weapon_utility',202)).ok)
snapshot=assert(U.Read(tx,'john',function() return true end).value)
assert(snapshot.equipment.utility.id==202 and snapshot.equipment.utility_secondary.id==201)
before=writes
assert(not run(intent('equip','weapon_utility',200)).ok and writes==before)
local stale=intent('unequip','weapon_utility',202); stale.expected.weapon_utility_secondary.revision=9
assert(not run(stale).ok and writes==before)
assert(run(intent('unequip','weapon_utility',202)).ok)
assert(assigned.weapon_utility_secondary==201 and assigned.weapon==155)
assert(run(intent('equip','weapon_utility',202)).ok)
davy=0
before=writes
assert(not U.Read(tx,'john',function() return true end).ok and writes==before,'gate off retains assignment without omission or cleanup')
davy=1
items[202].itemName='weapon_melee_lantern'
assert(not U.Read(tx,'john',function() return true end).ok,'retired Standard cannot masquerade as Davy')
items[202].itemName='weapon_melee_davy_lantern'
assert(not U.Read(tx,'john',function() return false end).ok)
assert(items[202].metadata.serialNumber=='D202')
print('Davy Inventory coexistence/CAS/isolated cleanup/gate-off/retired model refusal PASS; no economics')
binoculars=1
items[203]={id=203,row_revision=0,itemName='weapon_kit_binoculars',
 metadata={schemaVersion=2,weaponDefinitionId='utility_binoculars',serialNumber='B203',condition=100,flags={disabled=false,evidence=false}}}
assert(run(intent('equip','weapon_utility_tertiary',203)).ok)
snapshot=assert(U.Read(tx,'john',function() return true end).value)
assert(snapshot.equipment.utility_tertiary.id==203 and snapshot.equipment.utility.id==202 and snapshot.equipment.utility_secondary.id==201)
before=writes
local staleThird=intent('unequip','weapon_utility_tertiary',203); staleThird.expected.weapon_utility.revision=9
assert(not run(staleThird).ok and writes==before)
assert(run(intent('unequip','weapon_utility_tertiary',203)).ok)
assert(assigned.weapon_utility==202 and assigned.weapon_utility_secondary==201 and assigned.weapon==155)
assert(not run(intent('equip','weapon_utility',203)).ok)
assert(run(intent('equip','weapon_utility_tertiary',203)).ok)
binoculars=0
assert(not U.Read(tx,'john',function() return true end).ok)
binoculars=1
items[203].itemName='weapon_kit_binoculars_improved'
assert(not U.Read(tx,'john',function() return true end).ok)
items[203].itemName='weapon_kit_binoculars'
print('Binoculars Inventory three-child read/commit PASS: exact slot, isolated cleanup, stale sibling/gate/improved-model refusal')
camera=1
items[204]={id=204,row_revision=0,itemName='weapon_kit_camera',
 metadata={schemaVersion=2,weaponDefinitionId='utility_camera',serialNumber='C204',condition=100,flags={disabled=false,evidence=false}}}
assert(run(intent('equip','weapon_utility_quaternary',204)).ok)
snapshot=assert(U.Read(tx,'john',function() return true end).value)
assert(snapshot.equipment.utility_quaternary.id==204 and snapshot.equipment.utility_tertiary.id==203)
before=writes
local staleFourth=intent('unequip','weapon_utility_quaternary',204); staleFourth.expected.weapon_utility_tertiary.revision=1
assert(not run(staleFourth).ok and writes==before)
assert(run(intent('unequip','weapon_utility_quaternary',204)).ok)
assert(assigned.weapon_utility==202 and assigned.weapon_utility_secondary==201 and assigned.weapon_utility_tertiary==203 and assigned.weapon==155)
assert(not run(intent('equip','weapon_utility',204)).ok)
assert(run(intent('equip','weapon_utility_quaternary',204)).ok)
camera=0
assert(not U.Read(tx,'john',function() return true end).ok)
camera=1
items[204].itemName='weapon_kit_camera_advanced'
assert(not U.Read(tx,'john',function() return true end).ok)
items[204].itemName='weapon_kit_camera'
print('Camera Inventory four-child read/commit PASS: slot/CAS/sibling preservation/gate/Advanced refusal; no photography')
