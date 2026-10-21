Result={Ok=function(v) return {ok=true,value=v} end,Err=function(c,m) return {ok=false,error={code=c,message=m}} end}
local function copy(v) if type(v)~='table' then return v end; local r={}; for k,x in pairs(v) do r[k]=copy(x) end; return r end
local function equal(a,b)
 if type(a)~=type(b) then return false end; if type(a)~='table' then return a==b end
 for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
 for k in pairs(b) do if a[k]==nil then return false end end; return true
end
InventoryMetadata={DocumentsEqual=equal}
InventoryIdentity={NormalizeCharacterId=function(v) return v=='john' and v or nil end}
RegisterCommand=function() end
dofile('server/services/conditional_equipment.lua')
dofile('server/services/native_knife_equipment.lua')
local slots={'weapon_melee','weapon_melee_secondary','weapon_melee_tertiary','weapon_melee_quaternary','weapon_melee_quinary'}
local definitions={'melee_knife','melee_machete','melee_hammer','melee_cleaver','melee_hatchet'}
local items,assigned={}, {weapon=155}
for n,id in ipairs(definitions) do
 items[n]={id=n,row_revision=0,itemName='weapon_'..id,metadata={schemaVersion=2,weaponDefinitionId=id,
 serialNumber='M-'..n,condition=100,flags={disabled=false,evidence=false}}}
end
local authority,held,lose,writes=true,false,false,0
local guarded={}
GuardsAPI={CanChangeInstance=function(id) guarded[id]=true; return not held end}
local tx={query=function(sql,args)
 if sql:find('SELECT id FROM inventory',1,true)==1 then return {{id=5}} end
 if sql:find('SELECT ce.slot',1,true)==1 then
  local rows={}; for slot,id in pairs(assigned) do rows[#rows+1]={slot=slot,inventory_items_id=id,
   row_revision=items[id] and items[id].row_revision or 3,owner_character='john'} end; return rows
 end
 if sql:find('SELECT ii.id',1,true)==1 then return items[args[1]] and {copy(items[args[1]])} or {} end
 assert(sql:find('character_equipment',1,true),'no item/ammo/material mutations')
 writes=writes+1
 if sql:find('DELETE',1,true)==1 then assigned[args[2]]=nil
 elseif sql:find('INSERT',1,true)==1 then assigned[args[2]]=args[3] else error(sql) end
 if lose then authority=false end; return {}
end}
local function current() return authority end
local function spec(n,action)
 local s=assert(NativeMeleeEquipment.Read(tx,'john',n,current).value)
 return {characterId='john',action=action or 'equip',slot=slots[n],knifeId=n,knifeRevision=0,
 expected=s.expected,before=copy(items[n].metadata)}
end
local function run(s)
 local before=copy(assigned); local result=NativeMeleeEquipment.Apply(tx,s,current)
 if not result.ok then assigned=before end -- TransactionAPI rollback boundary
 return result
end
for n=1,5 do assert(run(spec(n)).ok and assigned[slots[n]]==n) end
for n=1,5 do assert(guarded[n]) end; assert(guarded[155])
local snapshot=assert(NativeMeleeEquipment.Read(tx,'john',nil,current).value)
for n=1,5 do assert(snapshot.equipment[slots[n]:sub(8)].id==n) end
local intent=spec(3,'unequip')
held=true; local count=writes; assert(not run(intent).ok and writes==count); held=false
intent.expected.weapon.revision=4; assert(not run(intent).ok and writes==count)
intent=spec(3,'unequip'); items[3].metadata.serialNumber='changed'
assert(not run(intent).ok and writes==count); items[3].metadata.serialNumber=intent.before.serialNumber
assert(run(intent).ok and not assigned.weapon_melee_tertiary and assigned.weapon_melee_quinary==5)
intent=spec(3); lose=true
assert(not run(intent).ok and not assigned.weapon_melee_tertiary,'post-write authority loss rolls back')
lose=false; authority=true
items[3].metadata.weaponDefinitionId='melee_knife'; items[3].itemName='weapon_melee_knife'
intent=spec(3); assert(not run(intent).ok,'same-model sibling refused')
items[3].metadata.weaponDefinitionId='melee_hammer'; items[3].itemName='weapon_melee_hammer'
intent=spec(3); intent.slot='weapon_offhand'; count=writes
assert(not run(intent).ok and writes==count)
items[3].metadata.ammo={}; assert(not NativeMeleeEquipment.Read(tx,'john',3,current).ok)
print('native melee Inventory adapter PASS: existing five slots/full CAS/guards, metadata mismatch, duplicate model, rollback and no economics')
