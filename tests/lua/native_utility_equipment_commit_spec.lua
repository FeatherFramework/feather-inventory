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
dofile('server/services/conditional_equipment.lua')
local U=dofile('server/internal/native_utility_equipment.lua')
local assigned,held,alive,lose,writes,guards={weapon=155},false,true,false,0,{}
local metadata={schemaVersion=2,weaponDefinitionId='utility_lasso',serialNumber='L',condition=100,
 flags={disabled=false,evidence=false}}
GuardsAPI={CanChangeInstance=function(id) guards[id]=true; return not held end}
local tx={query=function(sql,args)
 if sql:find('SELECT id FROM inventory',1,true)==1 then return {{id=5}} end
 if sql:find('SELECT ce.slot',1,true)==1 then
  local rows={}; for slot,id in pairs(assigned) do rows[#rows+1]={slot=slot,inventory_items_id=id,
   row_revision=id==155 and 3 or 0,owner_character='john'} end; return rows
 end
 if sql:find('SELECT ii.id',1,true)==1 then return args[1]==200 and {{id=200,row_revision=0,itemName='weapon_lasso',metadata=copy(metadata)}} or {} end
 assert(sql:find('character_equipment',1,true),'no ammo/material/metadata writes')
 writes=writes+1
 if sql:find('DELETE',1,true)==1 then assigned[args[2]]=nil
 elseif sql:find('INSERT',1,true)==1 then assigned[args[2]]=args[3] else error(sql) end
 if lose then alive=false end
 return {}
end}
local function spec(action)
 local read=assert(U.Read(tx,'john',function() return true end).value)
 return {characterId='john',action=action,slot='weapon_utility',utilityId=200,utilityRevision=0,
  expected=read.expected,before=copy(metadata)}
end
local function run(s)
 local before=copy(assigned)
 local r=U.Apply(tx,s,function() return alive end)
 if not r.ok then assigned=before end
 return r
end
local equip=spec('equip')
assert(run(equip).ok and assigned.weapon_utility==200 and assigned.weapon==155 and guards[155] and guards[200])
local unequip=spec('unequip'); local before=writes
held=true; assert(not run(unequip).ok and writes==before); held=false
local stale=copy(unequip); stale.expected.weapon.revision=4; assert(not run(stale).ok and writes==before)
stale=copy(unequip); stale.before.serialNumber='other'; assert(not run(stale).ok and writes==before)
assert(run(unequip).ok and assigned.weapon_utility==nil and assigned.weapon==155)
lose=true; assert(not run(equip).ok and assigned.weapon_utility==nil and assigned.weapon==155)
print('staged utility commit PASS: full equipment CAS/guards, exact serial/revision, sibling preservation and post-write rollback; mocked transaction')
