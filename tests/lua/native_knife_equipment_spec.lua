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
local metadata={schemaVersion=2,weaponDefinitionId='melee_knife',serialNumber='KNIFE',condition=100,
 quality=100,flags={disabled=false,evidence=false,stolen=false},attachments={},cosmetics={},provenance={}}
local assigned={weapon=155}
local revision,authority,held,writes,foreign,lose=0,true,false,0,false,false
local itemName='weapon_melee_knife'
local guards={}
GuardsAPI={CanChangeInstance=function(id,ctx) guards[id]=true; assert(ctx.operation=='equipment_write'); return not held end}
local tx={query=function(sql,args)
 assert(not sql:find('ammunition',1,true) and not sql:find('grant_receipts',1,true),'knife never writes economics')
 if sql:find('SELECT id FROM inventory',1,true)==1 then return {{id=5}} end
 if sql:find('SELECT ce.slot',1,true)==1 then
  local rows={}; for slot,id in pairs(assigned) do rows[#rows+1]={slot=slot,inventory_items_id=id,
   row_revision=id==90 and revision or 3,owner_character=foreign and 'other' or 'john'} end; return rows
 end
 if sql:find('SELECT ii.id',1,true)==1 then
  if args[1]~=90 or foreign then return {} end
  return {{id=90,row_revision=revision,metadata=metadata,itemName=itemName}}
 end
 assert(sql:find('character_equipment',1,true),'no item/material/ammo writes')
 if sql:find('DELETE',1,true)==1 then writes=writes+1; assigned[args[2]]=nil
 elseif sql:find('INSERT',1,true)==1 then writes=writes+1; assigned[args[2]]=args[3]
 else error(sql) end
 if lose then authority=false end
 return {}
end}
local function current() return authority end
local snapshot=assert(NativeKnifeEquipment.Read(tx,'john',90,current).value)
assert(snapshot.candidate.id==90 and snapshot.equipment.melee==nil and writes==0)
snapshot.candidate.metadata.flags.disabled=true; assert(not metadata.flags.disabled,'reader returns private copy')
local spec={characterId='john',action='equip',slot='weapon_melee',knifeId=90,knifeRevision=0,
 expected={weapon={itemId=155,revision=3}},before=copy(metadata)}
local function run(intent)
 local before=copy(assigned)
 local result=NativeKnifeEquipment.Apply(tx,intent,current)
 if not result.ok then assigned=before end -- existing transaction caller rolls back
 return result
end
assert(run(spec).ok and assigned.weapon_melee==90 and assigned.weapon==155 and guards[155] and guards[90])
assert(equal(metadata,spec.before) and revision==0,'equipment-only mutation')
local equipped=assert(NativeKnifeEquipment.Read(tx,'john',nil,current).value)
assert(equipped.equipment.melee.id==90 and equipped.expected.weapon_melee.revision==0)
local unequip={characterId='john',action='unequip',slot='weapon_melee',knifeId=90,knifeRevision=0,
 expected=equipped.expected,before=copy(metadata)}
held=true; local count=writes; assert(not run(unequip).ok and writes==count); held=false
assert(run(unequip).ok and assigned.weapon_melee==nil and assigned.weapon==155)
for _,change in ipairs({
 function(s) s.slot='weapon' end,
 function(s) s.expected={} end,
 function(s) s.knifeRevision=1 end,
 function(s) s.before.serialNumber='other' end,
 function(s) s.characterId='foreign' end,
 function() foreign=true end,
 function() itemName='weapon_melee_machete' end,
 function() metadata.ammo={} end,
 function() metadata.condition=0 end,
 function() metadata.flags.evidence=true end,
 function() held=true end,
 function() authority=false end,
}) do
 local bad=copy(spec); change(bad); local count=writes
 assert(not run(bad).ok and writes==count,'invalid intent never mutates equipment')
 foreign=false; itemName='weapon_melee_knife'; metadata=copy(spec.before); held=false; authority=true
end
lose=true; assert(not run(spec).ok and assigned.weapon_melee==nil and assigned.weapon==155,'post-write authority loss rolls back')
print('knife Inventory seam PASS (owned SELECT snapshot, full CAS, actual registered guards, no economics, stale/foreign/held rollback; no public route)')
