-- Real storage, ledger-reader, collection resolver and MoveInstance bodies;
-- transactional SQL/access/guard ports are mocked. No live MariaDB/native claim.
local root=arg and arg[1] or '.'
local function copy(v) if type(v)~='table' then return v end;local r={};for k,x in pairs(v) do r[k]=copy(x) end;return r end
local function equal(a,b)
 if type(a)~=type(b) then return false end;if type(a)~='table' then return a==b end
 for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
 for k in pairs(b) do if a[k]==nil then return false end end;return true
end
local documents,sequence={},0
json={encode=function(v) sequence=sequence+1;documents[tostring(sequence)]=copy(v);return tostring(sequence) end,
 decode=function(s) return copy(assert(documents[s])) end}
Result={Codes={CONFLICT='conflict',DENIED='denied',INVALID_INPUT='invalid'},
 Ok=function(v) return {ok=true,value=v} end,Err=function(c,m) return {ok=false,code=c,message=m} end}
InventoryIdentity={NormalizeCharacterId=function(s) return s=='john' and s or nil end}
InventoryMetadata={DocumentsEqual=equal}
InventoryAPI={AccessModes={REMOVE='remove',INSERT='insert'}}
RegisterCommand=function() end
Config={CharacterAmmunitionEnabled=true}
local db,live,mode,moves
local function unit(id)
 return {id=id,inventory_id=5,row_revision=0,slot_index=id-1,item_id=10,itemName='weapon_thrown_tomahawk',
  type='item_weapon',instance_mode='unique',metadata={schemaVersion=2,weaponDefinitionId='throwable_tomahawk',
  serialNumber='T-'..id,condition=100,flags={disabled=false,evidence=false,stolen=false},
  ammo={ownership='character',type='ammo_tomahawk_regular'}}}
end
local function reset()
 live=true;mode=nil;moves=0
 db={revision=0,pools={ammo_tomahawk_regular=0,ammo_revolver_regular=7},receipts={},items={},bound={},
  inventory={id=99,location='character_collection',is_public=0,max_slots=3},collection=false}
 for id=1,4 do db.items[id]=unit(id) end
end
InventoryControllers={AcceptanceInTransaction=function() return mode~='capacity' end}
GuardsAPI={CanMoveInstance=function() return mode~='guard','guard refused' end}
Tx={}
local file=assert(io.open(root..'/server/services/transactions.lua'));local source=file:read('*a');file:close()
local first=assert(source:find('function Tx:MoveInstance(',1,true))
local last=assert(source:find('function Tx:AssertAccess(',first,true))
assert(load(source:sub(first,last-1)))()
local tx=setmetatable({context={resource='feather-weapons'}},{__index=Tx})
function tx:RequireAccess() if mode=='access' then return Result.Err('denied') end end
function tx.query(sql,p)
 if sql:find('FROM character_equipment ce',1,true) then
  local rows={};for id in pairs(db.bound) do rows[#rows+1]={slot='weapon_throwable',inventory_items_id=id,
   row_revision=db.items[id].row_revision,owner_character='john'} end;return rows
 end
 if sql:find('SELECT character_id FROM inventory WHERE id=',1,true) then
  assert(p[1]==5);return {{character_id='john'}}
 end
 if sql:find('FROM inventory_character_collections c',1,true) then
  assert(p[1]=='john' and not sql:find('source.character_id',1,true))
  if not db.collection then return {} end
  local rows={}
  for _,r in pairs(db.items) do if r.inventory_id==99 then
   local row=copy(r);row.weight=2;row.custody_id=99;row.location=db.inventory.location
   row.character_id=db.inventory.character_id;row.owner_character_id=db.inventory.owner_character_id
   row.is_public=db.inventory.is_public;row.max_slots=db.inventory.max_slots;rows[#rows+1]=row
  end end
  table.sort(rows,function(a,b) return a.id<b.id end)
  if #rows==0 then return {{custody_id=99,location='character_collection',is_public=0,max_slots=3}} end
  return rows
 end
 if sql:find('SELECT id, max_slots FROM inventory',1,true) then
  if db.headerNull then return {{id=5}} end
  return {{id=5,max_slots=db.headerMax or 10}}
 end
 if sql:find('SELECT id FROM inventory',1,true) then return {{id=5}} end
 if sql:find('SELECT revision, pools',1,true) then return {{revision=db.revision,pools=json.encode(db.pools)}} end
 if sql:find('SELECT result FROM feather_ammunition_operations',1,true) then return db.receipts[p[2]] and {{result=db.receipts[p[2]]}} or {} end
 if sql:find('SELECT inventory_id FROM inventory_character_collections',1,true) then
  if p[2]=='native_throwable_spent_v1' then return db.spent and {{inventory_id=100}} or {} end
  return db.collection and {{inventory_id=99}} or {}
 end
 if sql:find('SELECT id,location',1,true) then
  if p[1]==100 then return {{id=100,location='character_collection',is_public=0,max_slots=500}} end
  return {copy(db.inventory)}
 end
 if sql:find('INSERT INTO inventory\n',1,true) then return {{id=p[1]=='native_throwable_spent_v1' and 100 or 99}} end
 if sql:find('INSERT INTO inventory_character_collections',1,true) then
  if p[2]=='native_throwable_spent_v1' then db.spent=true else db.collection=true end;return {affectedRows=1}
 end
 if sql:find('WHERE ii.inventory_id=? ORDER BY',1,true) then
  local rows={};for _,r in pairs(db.items) do if r.inventory_id==p[1] then rows[#rows+1]=copy(r) end end
  table.sort(rows,function(a,b) return a.id<b.id end);return rows
 end
 if sql:find('WHERE ii.id=? AND ii.inventory_id=?',1,true) then
  local r=db.items[p[1]];return r and r.inventory_id==p[2] and {copy(r)} or {}
 end
 if sql:find('WHERE ii.id=? AND inv.character_id=?',1,true) then
  local r=db.items[p[1]];return r and r.inventory_id==5 and p[2]=='john' and {copy(r)} or {}
 end
 if sql:find('SELECT slot FROM character_equipment',1,true) then return db.bound[p[1]] and {{slot='weapon_throwable'}} or {} end
 if sql:find('SELECT slot_index FROM inventory_items',1,true) then
  local rows={};for _,r in pairs(db.items) do if r.inventory_id==p[1] then rows[#rows+1]={slot_index=r.slot_index} end end;return rows
 end
 if sql:find('SELECT `inventory_id`',1,true) then return db.items[p[1]] and {copy(db.items[p[1]])} or {} end
 if sql:find('SELECT inventory_id,row_revision FROM inventory_items',1,true) then return {copy(db.items[p[1]])} end
 if sql:find('UPDATE `inventory_items`',1,true) then
  if mode=='move-no-write' then return {affectedRows=0} end
  moves=moves+1;if mode=='move' and moves==2 then error('simulated disconnect') end
  local r=db.items[p[3]];r.inventory_id=p[1];r.slot_index=p[2];r.row_revision=r.row_revision+1
  if mode=='authority' then live=false end;return {affectedRows=1}
 end
 if sql:find('DELETE FROM `character_equipment`',1,true) then db.bound[p[1]]=nil;return {affectedRows=0} end
 if sql:find('UPDATE feather_character_ammunition',1,true) then
  if mode=='cas' then return {affectedRows=0} end
  assert(db.revision==p[4]);db.pools=json.decode(p[1]);db.revision=p[2];return {affectedRows=1}
 end
 if sql:find('INSERT INTO feather_ammunition_operations',1,true) then
  if mode=='receipt' then return {affectedRows=0} end
  db.receipts[p[2]]=p[3];return {affectedRows=1}
 end
 error('Unhandled SQL: '..sql)
end
dofile(root..'/server/services/character_ammunition.lua')
dofile(root..'/server/services/character_collections.lua')
dofile(root..'/server/services/native_throwable_unit_storage.lua')
local context={characterId='john',sessionId='s',epoch='e'}
local function spec(action,ids,key)
 local items={};for _,id in ipairs(ids) do local r=db.items[id];items[#items+1]={id=id,revision=r.row_revision,metadata=copy(r.metadata)} end
 return {version=1,action=action,operationId=key,expectedRevision=db.revision,expectedPools=copy(db.pools),
  limits={ammo_tomahawk_regular=3,ammo_revolver_regular=200},items=items}
end
local function commit(s,authority)
 tx.moved={}
 local before=copy(db);local ok,result=pcall(NativeThrowableUnitStorage.Apply,tx,context,s,authority or function() return live end)
 if not ok or not result.ok then db=before end
 return ok and result or Result.Err('unknown')
end
reset()
Config.maxItemSlots=10
assert(commit(spec('carry',{1},'null-slots-carry')).ok)
db.headerNull=true
assert(commit(spec('return',{1},'null-slots-return')).ok and db.items[1].inventory_id==5
 and db.pools.ammo_tomahawk_regular==0,'NULL capacity returns the same unit using configured public slots')
assert(commit(spec('carry',{1},'zero-slots-carry')).ok)
db.headerNull=false;db.headerMax=0
local capacityBefore=copy(db)
assert(not commit(spec('return',{1},'zero-slots-return')).ok and equal(db,capacityBefore),
 'explicit zero capacity cannot silently use the default')
db.headerNull=true;Config.maxItemSlots=nil;capacityBefore=copy(db)
assert(not commit(spec('return',{1},'missing-default-return')).ok and equal(db,capacityBefore),
 'missing capacity and missing default must fail closed')
Config.maxItemSlots=10
reset()
for _,failure in ipairs({'access','guard','move','move-no-write','authority','cas','receipt'}) do
 reset();mode=failure;local before=copy(db)
 assert(not commit(spec('carry',{1,2},'fail')).ok and equal(db,before),'rollback '..failure)
end
for _,failure in ipairs({'access','guard','move','move-no-write','authority','cas','receipt','capacity'}) do
 reset();assert(commit(spec('carry',{1,2},'initial')).ok)
 mode=failure;moves=0;local before=copy(db)
 assert(not commit(spec('return',{1,2},'failed-return')).ok and equal(db,before),'return rollback '..failure)
end
for _,failure in ipairs({'guard','move','move-no-write','authority','cas','receipt'}) do
 reset();assert(commit(spec('carry',{1,2},'initial')).ok)
 mode=failure;moves=0;local before=copy(db)
 assert(not commit(spec('spend',{1,2},'failed-spend')).ok and equal(db,before),'spend rollback '..failure)
end
reset();assert(commit(spec('carry',{1,2,3},'initial')).ok)
local spentRequest=spec('spend',{2},'throw-2')
local spent=commit(spentRequest)
assert(spent.ok and spent.value.custody=='spent' and spent.value.inventoryDelta==0)
assert(equal(spent.value.spendIdentity,{characterId='john',sessionId='s',epoch='e'}),'spend retains server session identity')
assert(db.pools.ammo_tomahawk_regular==2 and db.items[2].inventory_id==100)
local spentBefore=copy(db)
assert(commit(spentRequest).value.replayed and equal(db,spentBefore),'spend replay cannot spend another unit')
context.epoch='replacement'
assert(not commit(spentRequest).ok and equal(db,spentBefore),'replacement epoch cannot reuse a spend receipt')
context.epoch='e'
assert(not commit(spec('return',{2},'return-spent')).ok and equal(db,spentBefore),'spent unit cannot be unloaded')
assert(commit(spec('return',{1,3},'unload-remainder')).ok and db.pools.ammo_tomahawk_regular==0)
assert(db.items[2].inventory_id==100 and db.items[2].metadata.serialNumber=='T-2')
reset()
local original=spec('carry',{2,1},'carry')
local carried=commit(original)
assert(carried.ok and db.items[1].inventory_id==99 and db.items[2].inventory_id==99)
assert(#tx.moved==0,'private custody must not emit generic ownership transfer facts')
assert(db.items[1].metadata.serialNumber=='T-1' and db.items[1].row_revision==1)
local snapshot=NativeThrowableUnitStorage.Read(tx,context,original.limits,function() return live end)
assert(snapshot.ok and snapshot.value.contract==2 and #snapshot.value.units==2)
assert(snapshot.value.units[1].id==1 and snapshot.value.units[2].id==2)
assert(snapshot.value.identity.epoch=='e' and snapshot.value.pools.ammo_revolver_regular==7)
assert(db.pools.ammo_tomahawk_regular==2 and db.pools.ammo_revolver_regular==7 and db.revision==1)
local before=copy(db);assert(commit(original).value.replayed and equal(before,db),'lost reply readback has no writes')
local changed=copy(original);changed.items[1].id=3
assert(not commit(changed).ok and equal(before,db),'receipt input conflict')
local returning=spec('return',{1,2},'return')
mode='capacity';assert(not commit(returning).ok and equal(before,db));mode=nil
local result=commit(returning)
assert(result.ok and db.pools.ammo_tomahawk_regular==0 and db.revision==2)
assert(db.items[1].inventory_id==5 and db.items[2].inventory_id==5 and db.items[1].row_revision==2)
assert(db.items[1].metadata.serialNumber=='T-1' and db.items[2].metadata.serialNumber=='T-2')
assert(#NativeThrowableUnitStorage.Read(tx,context,original.limits,function() return live end).value.units==0)
before=copy(db);assert(commit(original).value.replayed and equal(before,db),'old receipt never re-carries returned items')
assert(commit(spec('carry',{1,2,3},'three')).ok)
before=copy(db);assert(not commit(spec('carry',{4},'overfill')).ok and equal(before,db))
for _,failure in ipairs({'foreign','revision','metadata','bound','ledger','private','archived'}) do
 reset();local s=spec('carry',{1},failure)
 if failure=='foreign' then db.items[1].inventory_id=7
 elseif failure=='revision' then db.items[1].row_revision=9
 elseif failure=='metadata' then db.items[1].metadata.serialNumber='changed'
 elseif failure=='bound' then db.bound[1]=true
 elseif failure=='ledger' then db.pools.ammo_tomahawk_regular=1
 elseif failure=='private' then db.collection=true;db.inventory.is_public=1
 elseif failure=='archived' then db.items[1].archived_at='now' end
 before=copy(db);assert(not commit(s).ok and equal(before,db),'snapshot refusal '..failure)
end
reset();local s=spec('carry',{1},'callable')
local ref=setmetatable({__cfx_functionReference='trusted'},{__call=function() return live end})
assert(commit(s,ref).ok,'CFX callable table authority')
reset();db.items[2].metadata.serialNumber='T-1'
local before=copy(db)
assert(not commit(spec('carry',{1,2},'duplicate-serial')).ok and equal(before,db))
reset();assert(commit(spec('carry',{1},'initial')).ok)
db.items[2].metadata.serialNumber='T-1';before=copy(db)
assert(not commit(spec('carry',{2},'held-serial')).ok and equal(before,db))
reset();assert(commit(spec('carry',{1,2},'initial')).ok)
db.headerMax=1;db.items[3].slot_index=0;before=copy(db)
assert(not commit(spec('return',{1},'no-slot')).ok and equal(before,db),'slot exhaustion despite optimistic acceptance')
local function observe(spec)
 tx.moved={}
 local before=copy(db)
 local ctx=copy(context);ctx.runtimeEpoch='e';ctx.runtimeTicket='reserved'
 local ok,result=pcall(CharacterAmmunitionAPI.ApplyObservation,tx,ctx,spec,function() return live end)
 if not ok or not result.ok then db=before end
 return ok and result or Result.Err('unknown')
end
for _,failure in ipairs({'move','authority','cas','receipt'}) do
 reset();assert(commit(spec('carry',{1,2,3},'initial')).ok)
 local request={expectedRevision=1,limits={ammo_tomahawk_regular=3,ammo_revolver_regular=200},
  pools={ammo_tomahawk_regular=1,ammo_revolver_regular=6}}
 mode=failure;moves=0;before=copy(db)
 assert(not observe(request).ok and equal(before,db),'combined observation rollback '..failure)
end
reset();assert(commit(spec('carry',{1,2,3},'initial')).ok)
local request={expectedRevision=1,limits={ammo_tomahawk_regular=3,ammo_revolver_regular=200},
 pools={ammo_tomahawk_regular=1,ammo_revolver_regular=6}}
local observed=observe(request)
assert(observed.ok and observed.value.revision==2 and observed.value.consumed.ammo_tomahawk_regular==2)
assert(db.items[1].inventory_id==99 and db.items[2].inventory_id==100 and db.items[3].inventory_id==100)
assert(db.pools.ammo_revolver_regular==6 and db.pools.ammo_tomahawk_regular==1)
local custody=observed.value.throwableUnitsSnapshot
assert(custody.contract==2 and #custody.units==1 and custody.units[1].id==1 and custody.identity.epoch=='e')
before=copy(db);assert(not observe(request).ok and equal(before,db),'stale observation never spends twice')
request.expectedRevision=2;request.pools.ammo_tomahawk_regular=0
assert(observe(request).ok and db.items[1].inventory_id==100 and db.revision==3)
before=copy(db);local idle=observe({expectedRevision=3,limits=request.limits,pools=request.pools})
assert(idle.ok and idle.value.changed==false and equal(before,db),'idle zero quantity does not write')
local registered,caller,reserved={},'feather-weapons'
GetInvokingResource=function() return caller end
GetResourceState=function() return 'started' end
exports=setmetatable({['feather-core']={IsSessionCurrent=function() return live end},
 ['feather-weapons']={ValidateNativeEquipmentCommit=function(_,ctx,s)
  return live and ctx.ticket=='released' and reserved and equal(reserved,s)
 end}}, {__call=function(_,name,fn) registered[name]=fn end})
TransactionAPI={Transaction=function(ctx,fn)
 tx.context=ctx;tx.moved={};local before=copy(db);local ok,result=pcall(fn,tx)
 if not ok or not result.ok then db=before end
 return ok and result or Result.Err('unknown')
end}
dofile(root..'/server/services/native_lifecycle_wear.lua')
dofile(root..'/server/services/native_equipment_commit.lua')
local released={actorSource=7,characterId='john',sessionId='s',epoch='e',ticket='released'}
local function equipmentSpec(action,id,key)
 return {characterId='john',action=action,slot='weapon_throwable',throwable=true,throwableUnits=true,
  expected={},lifecycleSnapshot={},lifecycleWear={},unitStorage=spec(action=='equip' and 'carry' or 'return',{id},key)}
end
reset();reserved=equipmentSpec('equip',1,'released-equip')
local unsealed=copy(released);unsealed.ticket='active'
before=copy(db);assert(not registered.CommitNativeThrowableUnits(unsealed,reserved).ok and equal(before,db))
caller='foreign';assert(not registered.CommitNativeThrowableUnits(released,reserved).ok and equal(before,db));caller='feather-weapons'
assert(registered.CommitNativeThrowableUnits(released,reserved).ok and db.items[1].inventory_id==99 and #tx.moved==0)
local read=registered.ReadNativeEquipmentTransition(released,1,reserved.unitStorage.limits)
assert(read.ok and read.value.candidateCustody=='carried' and read.value.candidate.id==1
 and read.value.throwableEquipment.units[1].id==1,'read-only carried candidate uses private identity')
local missingEpoch=copy(released);missingEpoch.epoch=nil
before=copy(db)
assert(not registered.ReadNativeEquipmentTransition(missingEpoch,nil,reserved.unitStorage.limits).ok
 and equal(before,db),'physical preflight without native epoch must refuse without changing custody')
reserved=equipmentSpec('unequip',1,'released-return')
mode='receipt';before=copy(db)
assert(not registered.CommitNativeThrowableUnits(released,reserved).ok and equal(before,db),'released equipment rollback includes custody and ledger')
mode=nil;assert(registered.CommitNativeThrowableUnits(released,reserved).ok and db.items[1].inventory_id==5)
read=registered.ReadNativeEquipmentTransition(released,1,reserved.unitStorage.limits)
assert(read.ok and read.value.candidateCustody=='inventory' and #read.value.throwableEquipment.units==0)
print('Throwable unit storage PASS: real collection/ledger/move composition, identity conservation, private custody, rollback/replay/capacity/authority; mocked SQL')
