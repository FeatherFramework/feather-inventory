-- Real shared-claim and MoveInstance bodies. SQL, custody reader, capacity and
-- authority ports are modeled; this does not supply live projectile proof.
local function copy(v) if type(v)~='table' then return v end;local r={};for k,x in pairs(v) do r[k]=copy(x) end;return r end
local function equal(a,b)
 if type(a)~=type(b) then return false end;if type(a)~='table' then return a==b end
 for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
 for k in pairs(b) do if a[k]==nil then return false end end;return true
end
local docs,n={},0
json={encode=function(v) n=n+1;docs[tostring(n)]=copy(v);return tostring(n) end,decode=function(v) return copy(assert(docs[v])) end}
Result={Codes={DENIED='denied',INVALID_INPUT='invalid',NOT_FOUND='missing'},
 Ok=function(v) return {ok=true,value=v} end,Err=function(c,m) return {ok=false,code=c,message=m} end}
InventoryMetadata={DocumentsEqual=equal}
InventoryIdentity={NormalizeCharacterId=function(v) return (v=='jane' or v=='john') and v or nil end}
InventoryAPI={AccessModes={INSERT='insert'}}
local claim=dofile('server/internal/native_throwable_shared_claim.lua')
local metadata={schemaVersion=2,weaponDefinitionId='throwable_tomahawk',serialNumber='PAID-42',condition=100,
 flags={disabled=false,evidence=false,stolen=false},ammo={type='ammo_tomahawk_regular',ownership='character'}}
local context={resource='feather-weapons',characterId='jane',sessionId='collector-session',epoch='collector-epoch'}
local plan={version=2,kind='physical_throwable_shared_claim',projectileInstanceId='boot:world-1',spendOperationId='observe:10',
 originEventId='boot:throw-1',networkId=77,
 itemId=42,itemRevision=4,metadata=copy(metadata),expectedRevision=20,
 expectedPools={ammo_tomahawk_regular=0,ammo_revolver_regular=7},
 origin={characterId='john',sessionId='old-donor-session',epoch='old-donor-epoch'},
 collector={characterId='jane',sessionId='collector-session',epoch='collector-epoch'}}
local limits={ammo_tomahawk_regular=3,ammo_revolver_regular=100}
local db,authority,mode,queries,failAt,loseAt,headerOrder,activeCollector
local tx={}
Tx={}
local f=assert(io.open('server/services/transactions.lua'));local source=f:read('*a');f:close()
local first=assert(source:find('function Tx:MoveInstance(',1,true))
local last=assert(source:find('function Tx:AssertAccess(',first,true))
assert(load(source:sub(first,last-1)))()
setmetatable(tx,{__index=Tx})
GuardsAPI={CanMoveInstance=function() return mode~='guard' end}
function tx:RequireAccess(inv,action) assert(inv==(activeCollector=='jane' and 5 or 6) and action=='insert');if mode=='access' then return Result.Err('access') end end
InventoryControllers={AcceptanceInTransaction=function(_,inv,items)
 assert(inv==(activeCollector=='jane' and 5 or 6) and #items==1 and items[1].item=='weapon_thrown_tomahawk' and items[1].quantity==1)
 return mode~='capacity'
end}
CharacterCollectionAPI={Resolve=function(_,p)
 assert(p.characterId==activeCollector and p.resource=='feather-weapons' and p.key=='native_throwable_units_v1' and p.maxItems==3)
 return Result.Ok({id=mode=='bad-destination' and 100 or (activeCollector=='jane' and 99 or 98)})
end}
local function reset()
 authority=true;mode=nil;queries=0;failAt=nil;loseAt=nil;headerOrder={};tx.moved={};tx.context=copy(context);activeCollector='jane'
 db={aliases={},revision=20,pools=copy(plan.expectedPools),items={
 [42]={id=42,inventory_id=100,row_revision=4,slot_index=0,item_id=9,metadata=copy(metadata),
 itemName='weapon_thrown_tomahawk',type='item_weapon',instance_mode='unique'}},
 binding={version=2,phase='available',projectileInstanceId=plan.projectileInstanceId,
 originEventId=plan.originEventId,networkId=plan.networkId,
 spendOperationId=plan.spendOperationId,origin=copy(plan.origin),itemId=42,itemRevision=4,metadata=copy(metadata)},
 spend={request={action='spend',operationId='observe:10'},value={custody='spent',spendIdentity=copy(plan.origin),
 units={{id=42,revision=4,metadata=copy(metadata)}}}}}
end
function tx.query(sql,p)
 queries=queries+1
 if queries==loseAt then authority=false end
 if queries==failAt then error('database interruption') end
 if sql:find('SELECT id FROM inventory',1,true) then
  headerOrder[#headerOrder+1]=p[1];return {{id=p[1]=='jane' and 5 or 6}}
 end
 if sql:find('SELECT result_json FROM inventory_grant_receipts',1,true) then
  local row=(p[1]=='native-tomahawk-physical-binding-v2' or p[1]=='native-tomahawk-prompt-binding-v3' or p[1]=='native-tomahawk-native-binding-v4') and p[2]==plan.projectileInstanceId
   and db.binding or db.aliases[p[1]..'/'..p[2]]
  return row and {{result_json=not row.pending and json.encode(row) or nil}} or {}
 end
 if sql:find('INSERT IGNORE INTO inventory_grant_receipts',1,true) then
  if (p[1]=='native-tomahawk-physical-binding-v2' or p[1]=='native-tomahawk-prompt-binding-v3' or p[1]=='native-tomahawk-native-binding-v4') and p[2]==plan.projectileInstanceId then
   db.binding=db.binding or {pending=true}
  else local key=p[1]..'/'..p[2];db.aliases[key]=db.aliases[key] or {pending=true} end
  return {affectedRows=1}
 end
 if sql:find('SELECT result FROM feather_ammunition_operations',1,true) then
  assert(p[1]=='john' and p[2]=='throwable-units:observe:10');return db.spend and {{result=json.encode(db.spend)}} or {}
 end
 if sql:find('FROM inventory_character_collections c',1,true) then
  assert(p[3]=='john');return {{id=100,location='character_collection',is_public=mode=='public-spent' and 1 or 0,max_slots=500}}
 end
 if sql:find('d.name AS itemName',1,true) then return db.items[p[1]] and {copy(db.items[p[1]])} or {} end
 if sql:find('SELECT slot FROM character_equipment',1,true) then return mode=='equipped' and {{slot='weapon_throwable'}} or {} end
 if sql:find('SELECT slot_index FROM inventory_items',1,true) then
  local rows={};for _,row in pairs(db.items) do if row.inventory_id==p[1] then rows[#rows+1]={slot_index=row.slot_index} end end
  return rows
 end
 if sql:find('SELECT `inventory_id`',1,true) then return {copy(assert(db.items[p[1]]))} end
 if sql:find('UPDATE `inventory_items`',1,true) then
  local row=assert(db.items[p[3]]);row.inventory_id=p[1];row.slot_index=p[2];row.row_revision=row.row_revision+1;return {affectedRows=1}
 end
 if sql:find('DELETE FROM `character_equipment`',1,true) then return {affectedRows=0} end
 if sql:find('SELECT inventory_id,row_revision FROM inventory_items',1,true) then return {copy(db.items[p[1]])} end
 if sql:find('UPDATE feather_character_ammunition',1,true) then
  assert(p[3]==activeCollector,'only collector ledger may be credited')
  if db.revision~=p[4] or mode=='ledger-cas' then return {affectedRows=0} end
  db.pools=json.decode(p[1]);db.revision=p[2];return {affectedRows=1}
 end
 if sql:find('UPDATE inventory_grant_receipts',1,true) then
  if mode=='receipt-cas' then return {affectedRows=0} end
  if (p[2]=='native-tomahawk-physical-binding-v2' or p[2]=='native-tomahawk-prompt-binding-v3' or p[2]=='native-tomahawk-native-binding-v4') and p[3]==plan.projectileInstanceId then db.binding=json.decode(p[1])
  else db.aliases[p[2]..'/'..p[3]]=json.decode(p[1]) end
  return {affectedRows=1}
 end
 error('unexpected SQL: '..sql)
end
CharacterAmmunitionAPI={ReadSnapshot=function(_,id)
 assert(id==activeCollector);return Result.Ok({characterId=id,revision=db.revision,pools=copy(db.pools)})
end}
NativeThrowableUnitStorage={Read=function(_,ctx)
 assert(ctx.characterId==activeCollector);local units={}
 for _,row in pairs(db.items) do if row.inventory_id==(activeCollector=='jane' and 99 or 98) then
  units[#units+1]={id=row.id,revision=row.row_revision,itemName=row.itemName,metadata=copy(row.metadata)}
 end end
 table.sort(units,function(a,b) return a.id<b.id end)
 if #units~=db.pools.ammo_tomahawk_regular then return Result.Err('custody') end
 return Result.Ok({contract=2,kind='physical_throwable_units',characterId=ctx.characterId,
 identity={characterId=ctx.characterId,sessionId=ctx.sessionId,epoch=ctx.epoch},
 revision=db.revision,pools=copy(db.pools),units=units})
end}
local function run(p,c,callback)
 activeCollector=(c or context).characterId
 local before,facts=copy(db),copy(tx.moved)
 local ok,result=pcall(claim.Apply,tx,c or context,p or plan,limits,callback or function() return authority end)
 if not ok or not result.ok then db=before;tx.moved=facts end
 return ok and result or Result.Err('exception')
end
reset();local result=run();assert(result.ok)
assert(db.items[42].inventory_id==99 and db.items[42].row_revision==5 and db.revision==21)
assert(db.pools.ammo_tomahawk_regular==1 and db.pools.ammo_revolver_regular==7 and #tx.moved==0)
assert(result.value.throwableUnitsSnapshot.units[1].id==42 and result.value.origin.characterId=='john')
assert(headerOrder[1]=='jane' and headerOrder[2]=='john','headers sorted before receiver ledger or receipts')
local queryCount=queries
local competitor=copy(plan);competitor.collector={characterId='john',sessionId='another-player',epoch='another-epoch'}
local competitorContext=copy(competitor.collector);competitorContext.resource='feather-weapons'
local committed=copy(db)
assert(not run(competitor,competitorContext).ok and equal(committed,db),'second collector loses the serialized claim')
db.pools.ammo_tomahawk_regular=0;db.revision=25;db.items[42].inventory_id=100;db.items[42].row_revision=8
local saved=copy(db);assert(run().value.replayed and equal(saved,db),'lost reply cannot repeat transfer after subsequent play')
local other=copy(plan);other.collector.sessionId='replacement';local ctx=copy(context);ctx.sessionId='replacement'
assert(not run(other,ctx).ok and equal(saved,db),'different collector session cannot replay prior claim')
for _,failure in ipairs({'guard','access','capacity','equipped','public-spent','bad-destination','ledger-cas','receipt-cas'}) do
 reset();mode=failure;local before=copy(db);assert(not run().ok and equal(before,db),failure)
end
for i=1,queryCount do
 reset();failAt=i;local before=copy(db);assert(not run().ok and equal(before,db),'rollback query '..i)
 reset();loseAt=i;before=copy(db);assert(not run().ok and equal(before,db),'authority lost query '..i)
end
for _,mutate in ipairs({
 function() db.binding=nil end,function() db.spend=nil end,
 function() db.binding.phase='uncertain' end,function() db.spend.value.spendIdentity.epoch='wrong' end,
 function() db.items[42].row_revision=5 end,function() db.items[42].metadata.serialNumber='other' end,
 function() db.items[42].inventory_id=6 end,function() db.binding.metadata.condition=0 end,
 function() db.spend.value.units={} end,function() db.revision=21 end}) do
 reset();mutate();local before=copy(db);assert(not run().ok and equal(before,db))
end
reset();local remote=setmetatable({__cfx_functionReference='test'},{__call=function() return authority end})
assert(run(nil,nil,remote).ok,'cross-resource callable-table authority supported')
reset();local own=copy(plan);own.collector=copy(plan.origin)
local ownContext=copy(own.collector);ownContext.resource='feather-weapons'
assert(run(own,ownContext).ok and db.items[42].inventory_id==98 and db.pools.ammo_tomahawk_regular==1,
 'own pickup uses the same one-unit transfer, with a single character header lock')
for count=1,3 do
 reset();db.pools.ammo_tomahawk_regular=count
 for id=1,count do db.items[id]={id=id,inventory_id=99,row_revision=0,slot_index=id-1,item_id=9,
  metadata=copy(metadata),itemName='weapon_thrown_tomahawk',type='item_weapon',instance_mode='unique'}
  db.items[id].metadata.serialNumber='EXISTING-'..id
 end
 local p=copy(plan);p.expectedPools=copy(db.pools);local before=copy(db)
 local result=run(p)
 if count<3 then
  assert(result.ok and db.pools.ammo_tomahawk_regular==count+1 and #result.value.throwableUnitsSnapshot.units==count+1)
 else assert(not result.ok and equal(before,db),'full collector cannot claim a fourth unit') end
end
local donor={resource='feather-weapons',characterId='john',sessionId=plan.origin.sessionId,epoch=plan.origin.epoch}
local function bind(record,ctx)
 local before=copy(db)
 local ok,result=pcall(claim.RecordBinding,tx,ctx or donor,record,function() return authority end)
 if not ok or not result.ok then db=before end
 return ok and result or Result.Err('exception')
end
reset();local record=copy(db.binding);db.binding=nil
assert(bind(record).ok,'durable binding writer requires a matching committed paid spend')
local bindQueries=queries
local before=copy(db);assert(bind(record).value.replayed and equal(before,db))
local second=copy(record);second.projectileInstanceId='boot:world-2';second.originEventId='boot:throw-2'
assert(not bind(second).ok and equal(before,db),'same paid revision cannot bind to two world objects')
assert(run().ok,'newly persisted world binding composes with collector claim')
before=copy(db);local historical=bind(record)
assert(historical.ok and historical.value.binding.phase=='claimed' and equal(before,db),'binding replay never reactivates a claimed object')
for i=1,bindQueries do
 reset();db.binding=nil;failAt=i;before=copy(db)
 assert(not bind(record).ok and equal(before,db),'binding interruption rollback '..i)
 reset();db.binding=nil;loseAt=i;before=copy(db)
 assert(not bind(record).ok and equal(before,db),'binding authority rollback '..i)
end
reset();db.binding=nil;db.spend.value.spendIdentity.sessionId='replacement';before=copy(db)
assert(not bind(record).ok and equal(before,db),'another thrower session cannot bind spend evidence')
local f=assert(io.open('fxmanifest.lua'));local manifest=f:read('*a');f:close()
assert(manifest:find('native_throwable_shared_claim.lua',1,true),'claim primitive loads for released-authority export; no client route is admitted here')
print('Shared physical claim PASS: same paid row, collector ledger only, capacity, historical replay, atomic interruption/authority rollback; modeled SQL/world ports')

-- Prompt-backed durable identity has its own namespace and NO fake network ID.
local function promptPlan()
 local p=copy(plan);p.version=3;p.kind='physical_throwable_prompt_claim'
 p.pickupId=p.projectileInstanceId;p.projectileInstanceId=nil;p.networkId=nil
 p.pickupRevision=0;p.bucket=1;p.position={x=1,y=2,z=3}
 return p
end
local function promptBinding(p)
 local b=copy(p);b.kind='paid_tomahawk_pickup';b.phase='available'
 b.expectedPools=nil;b.expectedRevision=nil;b.collector=nil
 return b
end
reset();local p=promptPlan();local rec=promptBinding(p);db.binding=nil
assert(bind(rec).ok and db.binding.version==3)
local beforeRead=copy(db)
assert(claim.ReadPromptBinding(tx,p.pickupId).value.phase=='available' and equal(beforeRead,db))
assert(run(p).ok and db.items[42].inventory_id==99 and db.pools.ammo_tomahawk_regular==1)
assert(claim.ReadPromptBinding(tx,p.pickupId).value.phase=='claimed')
local saved=copy(db);assert(run(p).value.replayed and equal(saved,db))
for _,mutate in ipairs({
 function(p) p.networkId=77 end,function(p) p.projectileInstanceId='invented' end,
 function(p) p.pickupRevision=1 end,function(p) p.bucket=2 end,
 function(p) p.position.x=100 end,function(p) p.position.x=0/0 end}) do
 reset();local p=promptPlan();db.binding=promptBinding(p);mutate(p)
 local before=copy(db);assert(not run(p).ok and equal(before,db))
end
reset();local p=promptPlan();db.binding=promptBinding(p)
local done=run(p);assert(done.ok);local count=queries
for i=1,count do
 reset();local p=promptPlan();db.binding=promptBinding(p);failAt=i
 local before=copy(db);assert(not run(p).ok and equal(before,db),'prompt claim rollback '..i)
end
print('Prompt claim PASS: versioned durable pickup identity, no network ID, immutable placement, receipt replay and modeled atomic rollback')

reset()
local spent=claim.ReadSpentUnit(tx,plan.origin,'observe:10',42)
assert(spent.ok and spent.value.itemId==42 and spent.value.itemRevision==4 and spent.value.metadata.serialNumber==metadata.serialNumber)
local other=copy(plan.origin);other.epoch='other'
assert(not claim.ReadSpentUnit(tx,other,'observe:10',42).ok,'a different native epoch cannot supply this spend')

-- Native-collected units reuse the real atomic move/ledger/receipt primitive,
-- but have a distinct namespace and strict presentation + claim kind.
local function nativePlan()
 local p=promptPlan();p.version=4;p.presentation='native';p.kind='physical_throwable_native_claim';return p
end
local function nativeBinding(p)
 local b=promptBinding(p);b.kind='paid_tomahawk_native_pickup';return b
end
reset();local p=nativePlan();local rec=nativeBinding(p);db.binding=nil
assert(bind(rec).ok and db.binding.version==4)
assert(claim.ReadNativeBinding(tx,p.pickupId).ok)
assert(not claim.ReadPromptBinding(tx,p.pickupId).ok,'native binding never becomes a prompt binding')
local before=copy(db)
assert(not run(promptPlan()).ok and equal(before,db),'prompt claim cannot collect native binding')
queries=0
assert(run(p).ok and db.items[42].inventory_id==99 and db.items[42].row_revision==5
 and equal(db.items[42].metadata,metadata) and db.pools.ammo_tomahawk_regular==1)
local count=queries
local saved=copy(db);assert(run(p).value.replayed and equal(saved,db))
for n=1,count do
 reset();local p=nativePlan();db.binding=nativeBinding(p);failAt=n
 local before=copy(db);assert(not run(p).ok and equal(before,db),'native claim rollback '..n)
 reset();local p=nativePlan();db.binding=nativeBinding(p);loseAt=n
 local before=copy(db);assert(not run(p).ok and equal(before,db),'native claim authority '..n)
end
for _,mutate in ipairs({
 function(p) p.presentation=nil end,function(p) p.version=3 end,
 function(p) p.kind='physical_throwable_prompt_claim' end,function(p) p.pickupRevision=1 end,
 function(p) p.position.x=99 end,function(p) p.networkId=77 end}) do
 reset();local p=nativePlan();db.binding=nativeBinding(p);mutate(p)
 local before=copy(db);assert(not run(p).ok and equal(before,db))
end
reset();local p=promptPlan();local rec=promptBinding(p);rec.presentation='native';db.binding=nil
assert(not bind(rec).ok,'v3 cannot be relabeled native to bypass namespace separation')
print('Native collection primitive PASS: v4 namespace, exact same paid metadata/row, atomic rollback, historical receipt replay, prompt path isolation')
-- Live item114 rolled back before its paid-spend read. Distinguish those
-- predicates without weakening exact binding/ledger checks or adding I/O.
for _,case in ipairs({
 {'binding_missing',function() db.binding=nil end},
 {'binding_version_changed',function() db.binding.version=3 end},
 {'binding_id_changed',function() db.binding.pickupId='different' end},
 {'binding_shape_changed',function() db.binding.kind='physical_throwable_native_claim' end},
 {'binding_revision_changed',function() db.binding.pickupRevision=1 end},
 {'binding_bucket_changed',function() db.binding.bucket=db.binding.bucket+1 end},
 {'binding_position_changed',function() db.binding.position.x=99 end},
 {'binding_event_changed',function() db.binding.originEventId='different' end},
 {'binding_spend_changed',function() db.binding.spendOperationId='different' end},
 {'binding_origin_changed',function() db.binding.origin.epoch='different' end},
 {'binding_item_changed',function() db.binding.itemId=43 end},
 {'binding_item_revision_changed',function() db.binding.itemRevision=5 end},
 {'binding_metadata_changed',function() db.binding.metadata.serialNumber='different' end},
 {'binding_not_available',function() db.binding.phase='review_required' end},
 {'collector_revision_changed',function() db.revision=db.revision+1 end},
 {'collector_pools_changed',function() db.pools.ammo_revolver_regular=8 end},
}) do
 reset();local p=nativePlan();db.binding=nativeBinding(p);case[2]()
 local before=copy(db);local calls=0
 local refused=run(p,nil,function() calls=calls+1;return true end)
 assert(not refused.ok and refused.code=='throwable_shared_claim_refused'
  and refused.message:find('['..case[1]..']',1,true) and equal(before,db),case[1])
 -- Two sorted headers and one binding read; modeled ReadSnapshot has no SQL.
 assert(queries==3,case[1]..' adds no query or paid-spend read')
 local afterBinding=case[1]=='binding_not_available' or case[1]:find('collector_',1,true)
 assert(calls==(afterBinding and 3 or 2),case[1]..' preserves short-circuit authority calls')
end
reset();local p=nativePlan();db.binding=nativeBinding(p);local before=copy(db);local calls=0
local refused=run(p,nil,function() calls=calls+1;return calls<3 end)
assert(not refused.ok and refused.message:find('[binding_authority_changed]',1,true)
 and calls==3 and equal(before,db))
print('Claim diagnostics PASS: exact predicate labels, unchanged short-circuit authority/query counts, atomic refusal')
reset();local p=nativePlan();db.binding=nativeBinding(p);db.spend.value.units[1].metadata.serialNumber='altered-paid-receipt'
local before=copy(db)
assert(not run(p,nil,function() return true end).ok and equal(before,db),
 'continuation authority never replaces the locked canonical paid receipt verification inside the claim transaction')
