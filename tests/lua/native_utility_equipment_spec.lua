Result={Ok=function(v) return {ok=true,value=v} end,Err=function(c,m) return {ok=false,error={code=c,message=m}} end}
InventoryIdentity={NormalizeCharacterId=function(v) return v=='john' and v or nil end}
local U=dofile('server/internal/native_utility_equipment.lua')
local function copy(v) if type(v)~='table' then return v end; local r={}; for k,x in pairs(v) do r[k]=copy(x) end; return r end
local alive,drop,rows,item,reads
local function reset()
 alive=true; drop=nil; reads=0
 rows={{slot='weapon',inventory_items_id=155,row_revision=3,owner_character='john'},
 {slot='weapon_utility',inventory_items_id=200,row_revision=0,owner_character='john'}}
 item={id=200,row_revision=0,itemName='weapon_lasso',metadata={schemaVersion=2,weaponDefinitionId='utility_lasso',serialNumber='L'}}
end
local tx={query=function(sql,args)
 reads=reads+1
 assert(sql:find('SELECT',1,true)==1 and sql:find('FOR UPDATE',1,true),'read only locked SQL')
 if drop==reads then alive=false end
 if reads==1 then assert(args[1]=='john'); return {{id=5}} end
 if reads==2 then return copy(rows) end
 assert(args[1]==200 and args[2]=='john'); return item and {copy(item)} or {}
end}
local function run() return U.Read(tx,'john',function() return alive end) end
reset(); local r=assert(run().value)
assert(r.equipment.utility.id==200 and r.expected.weapon.itemId==155 and reads==3)
r.equipment.utility.metadata.serialNumber='changed'; assert(item.metadata.serialNumber=='L')
reset(); rows={}; assert(run().ok and reads==2)
for _,mutate in ipairs({function() rows[2].owner_character='jane' end,
 function() rows[2].inventory_items_id=155 end,function() rows[2].row_revision=1 end,
 function() item=nil end,function() item.itemName='weapon_melee_knife' end,
 function() item.metadata.ammo={} end,function() item.metadata.maintenance={} end,
 function() item.metadata.weaponDefinitionId='utility_camera' end}) do
 reset(); mutate(); assert(not run().ok)
end
for i=1,3 do reset(); drop=i; assert(not run().ok) end
reset(); assert(not U.Read(tx,'jane',function() return true end).ok and reads==0)
reset(); local callable=setmetatable({__cfx_functionReference='test'},{__call=function() return true end})
assert(U.Read(tx,'john',callable).ok,'CFX callable authority must be accepted')
print('staged utility Inventory reader PASS: locked owned full assignment, no writes, authority/duplicate/model/revision refusal')
