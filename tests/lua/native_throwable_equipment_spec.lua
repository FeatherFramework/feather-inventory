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
local metadata={schemaVersion=2,weaponDefinitionId='throwable_tomahawk',serialNumber='T',condition=100,
 ammo={ownership='character',type='ammo_tomahawk_regular'},flags={disabled=false,evidence=false}}
local assigned={weapon=155,weapon_melee=160}
local authority,held,lose,writes=true,false,false,0
local guards={}
GuardsAPI={CanChangeInstance=function(id) guards[id]=true; return not held end}
local tx={query=function(sql,args)
 if sql:find('SELECT id FROM inventory',1,true)==1 then return {{id=5}} end
 if sql:find('SELECT ce.slot',1,true)==1 then
  local rows={}; for slot,id in pairs(assigned) do rows[#rows+1]={slot=slot,inventory_items_id=id,
   row_revision=id==170 and 0 or 3,owner_character='john'} end; return rows
 end
 if sql:find('SELECT ii.id',1,true)==1 then
  return args[1]==170 and {{id=170,row_revision=0,itemName='weapon_thrown_tomahawk',metadata=copy(metadata)}} or {}
 end
 assert(sql:find('character_equipment',1,true),'no item/ammo/material economic writes')
 writes=writes+1
 if sql:find('DELETE',1,true)==1 then assigned[args[2]]=nil
 elseif sql:find('INSERT',1,true)==1 then assigned[args[2]]=args[3] else error(sql) end
 if lose then authority=false end; return {}
end}
local function current() return authority end
local snapshot=assert(NativeThrowableEquipment.Read(tx,'john',170,current).value)
local spec={characterId='john',action='equip',slot='weapon_throwable',throwableId=170,throwableRevision=0,
 expected=snapshot.expected,before=copy(metadata)}
local function run(intent)
 local before=copy(assigned); local result=NativeThrowableEquipment.Apply(tx,intent,current)
 if not result.ok then assigned=before end; return result
end
assert(run(spec).ok and assigned.weapon_throwable==170 and assigned.weapon_melee==160 and assigned.weapon==155)
assert(guards[170] and guards[160] and guards[155])
snapshot=assert(NativeThrowableEquipment.Read(tx,'john',nil,current).value)
assert(snapshot.equipment.throwable.id==170 and snapshot.equipment.throwable.metadata.ammo.quantity==nil)
local unequip={characterId='john',action='unequip',slot='weapon_throwable',throwableId=170,throwableRevision=0,
 expected=snapshot.expected,before=copy(metadata)}
held=true; local count=writes; assert(not run(unequip).ok and writes==count); held=false
assert(run(unequip).ok and not assigned.weapon_throwable)
for _,key in ipairs({'quantity','loaded','reserve','pools'}) do
 metadata.ammo[key]=0; count=writes
 assert(not run(spec).ok and writes==count); metadata.ammo[key]=nil
end
local bad=copy(spec); bad.slot='weapon_melee'; assert(not run(bad).ok)
bad=copy(spec); bad.throwableRevision=1; assert(not run(bad).ok)
bad=copy(spec); bad.before.serialNumber='foreign'; assert(not run(bad).ok)
lose=true; assert(not run(spec).ok and not assigned.weapon_throwable and assigned.weapon_melee==160)
print('throwable Inventory internal seam PASS: exact item/type/full equipment CAS/guards, no item quantities/economics, authority rollback')
