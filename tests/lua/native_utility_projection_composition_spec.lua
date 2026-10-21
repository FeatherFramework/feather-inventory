-- Actual Inventory reader plus actual Weapons projection; only SQL is mocked.
Config={AmmunitionPools={enabled=false}}
dofile('../feather-weapons/shared/constants.lua')
dofile('../feather-weapons/shared/definitions/weapons.lua')
dofile('../feather-weapons/shared/native_utility_catalog.lua')
dofile('../feather-weapons/shared/native_utility_item.lua')
Result={Ok=function(v) return {ok=true,value=v} end,Err=function(c,m) return {ok=false,error={code=c,message=m}} end}
InventoryIdentity={NormalizeCharacterId=function(v) return v=='john' and v or nil end}
local reader=dofile('server/internal/native_utility_equipment.lua')
local function copy(v) if type(v)~='table' then return v end; local r={}; for k,x in pairs(v) do r[k]=copy(x) end; return r end
local def=WeaponDefinitionCatalog.weapons.utility_lasso
local bound={characterId='john',sessionId='session',epoch='epoch'}
local mode,alive,queries,item
local function reset(m)
 mode=m; alive=true; queries=0
 item={id=200,row_revision=0,itemName='weapon_lasso',metadata={schemaVersion=2,
 weaponDefinitionId='utility_lasso',serialNumber='LASSO-TEST',condition=100,quality=100,
 flags={stolen=false,disabled=false,evidence=false},attachments={},cosmetics={},provenance={}}}
end
local tx={query=function(sql,args)
 queries=queries+1; assert(sql:find('SELECT',1,true)==1,'no equipment/ammo/material writes')
 if queries==1 then return {{id=5}} end
 if queries==2 then
  local rows={{slot='weapon',inventory_items_id=155,row_revision=3,owner_character='john'}}
  if mode~='empty' then rows[#rows+1]={slot='weapon_utility',inventory_items_id=200,row_revision=0,owner_character='john'} end
  return rows
 end
 assert(args[1]==200 and args[2]=='john')
 if mode=='session_left' then alive=false end
 if mode=='revision_changed' then item.row_revision=1 end
 if mode=='disabled' then item.metadata.flags.disabled=true end
 if mode=='evidence' then item.metadata.flags.evidence=true end
 if mode=='broken' then item.metadata.condition=0 end
 if mode=='ammo' then item.metadata.ammo={} end
 if mode=='customized' then item.metadata.attachments.barrel='foreign' end
 return {copy(item)}
end}
local function compose()
 local read=reader.Read(tx,'john',function() return alive end)
 if not read.ok then return nil end
 return WeaponNativeUtilityItem.Assigned(read.value,def,bound)
end
reset(); local approval=assert(compose())
local validated=assert(WeaponNativeUtilityItem.ValidateApproval(approval,def,bound))
assert(validated.row.id==200 and validated.equipmentSlot=='weapon_utility')
assert(validated.row.metadata.serialNumber=='LASSO-TEST')
validated.row.metadata.condition=0
assert(item.metadata.condition==100 and approval.row.metadata.condition==100)
reset('empty'); assert(compose()==false and queries==2)
for _,m in ipairs({'session_left','revision_changed','disabled','evidence','broken','ammo','customized'}) do
 reset(m); assert(compose()==nil,m..' must not produce native approval')
end
print('staged utility composition PASS: real locked reader + real Weapons projection, no SQL writes; native ownership not exercised')
