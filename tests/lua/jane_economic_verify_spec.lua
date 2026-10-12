local char='6a2fd060-c46f-11f1-9ae2-e0d55eaa2deb'
Result={Codes={CONFLICT='conflict'},Ok=function(v) return {ok=true,value=v} end,
 Err=function(c,m) return {ok=false,error={code=c,message=m}} end}
local commands={}
RegisterCommand=function(name,fn) commands[name]=fn end
Config={DevMode=true,CharacterAmmunitionEnabled=false}
dofile('server/services/character_ammunition_enrollment.lua')
local limits={ammo_revolver_regular=200}
for i=2,27 do limits['ammo_test_'..i]=100 end
local function pools(n) local p={}; for id in pairs(limits) do p[id]=id=='ammo_revolver_regular' and n or 0 end; return p end
local ledger={revision=3,pools=pools(0)}
local operations={
 {operation_id='alpha-character-ammo-enrollment-v1',result={fingerprint='alpha-character-ammo-enrollment-v1',
  value={characterId=char,revision=0,items=1,itemRevisions={['112']=1},pools={ammo_revolver_regular=0}}}},
 {operation_id='jane-economic-load-v1',result={fingerprint='ammo_revolver_regular:2:0',
  value={characterId=char,operationId='jane-economic-load-v1',revision=1,inventoryDelta=-2,pools=pools(2)}}},
 {operation_id='jane-economic-unload-v1',result={fingerprint='ammo_revolver_regular:-1:2',
  value={characterId=char,operationId='jane-economic-unload-v1',revision=3,inventoryDelta=1,pools=pools(0)}}}}
local grant={request_fingerprint=char..'|ammo_revolver_regular|8|2',result_json={characterId=char,
 grantId='native-test-jane-revolver-regular-two-v1',itemName='ammo_revolver_regular',definitionId=8,quantity=2,instanceIds={201,202}}}
local firearm={id=112,row_revision=1,name='weapon_revolver_cattleman',type='item_weapon',metadata={
 weaponDefinitionId='revolver_cattleman',serialNumber='FW-REVO-6AC9DCDE-FDEBF3-0001',ammo={ownership='character',type='ammo_revolver_regular'}}}
local rows={firearm,{id=203,definition_id=8,name='ammo_revolver_regular',type='item_ammo'}}
local equipment={}
local queries=0
local tx={query=function(sql)
 queries=queries+1; assert(sql:find('SELECT',1,true)==1,'verifier must never write SQL')
 if sql:find('SELECT id FROM inventory',1,true) then return {{id=1}} end
 if sql:find('SELECT revision, pools',1,true) then return {ledger} end
 if sql:find('SELECT operation_id',1,true) then return operations end
 if sql:find('inventory_grant_receipts',1,true) then return {grant} end
 if sql:find('SELECT ii.id',1,true) then return rows end
 if sql:find('character_equipment',1,true) then return equipment end
 error(sql)
end}
local function read() return CharacterAmmoEnrollment.ReadJaneEconomic(tx,limits) end
assert(read().ok and queries==6)
ledger.revision=2; assert(not read().ok); ledger.revision=3
ledger.pools.ammo_revolver_regular=1; assert(not read().ok); ledger.pools.ammo_revolver_regular=0
rows[3]=rows[2]; assert(not read().ok); rows[3]=nil
firearm.row_revision=2; assert(not read().ok); firearm.row_revision=1
firearm.metadata.ammo.loaded=0; assert(not read().ok); firearm.metadata.ammo.loaded=nil
grant.result_json.quantity=4; assert(not read().ok); grant.result_json.quantity=2
operations[2].result.value.inventoryDelta=-1; assert(not read().ok); operations[2].result.value.inventoryDelta=-2
operations[3].result.value.pools.ammo_revolver_regular=1; assert(not read().ok); operations[3].result.value.pools.ammo_revolver_regular=0
equipment[1]={slot='weapon'}; assert(not read().ok); equipment[1]=nil
assert(read().ok)
local current=true
InventoryIdentity={GetSession=function() return {ok=true,value={characterId=char,sessionId='s'}} end}
GetResourceState=function() return 'stopped' end
GuardsAPI={HasRegisteredGuard=function() return false end}
exports={['feather-core']={IsSessionCurrent=function() return current end}}
CharacterAmmoNativePreview={Load=function() return {},nil,nil,nil,nil,{Build=function() return {limits=limits} end} end}
TransactionAPI={Transaction=function(_,fn) return fn(tx) end}
local output={}; local oldPrint=print; print=function(v) output[#output+1]=v end
local run=commands.InvJaneAmmoEconomicVerify
local before=queries
run(1,{'1',char}); run(0,{'1','original'}); assert(queries==before)
run(0,{'1',char}); assert(output[#output]:find('PASS revision3',1,true))
local query=tx.query
tx.query=function(sql) local value=query(sql); if sql:find('character_equipment',1,true) then current=false end; return value end
run(0,{'1',char}); assert(output[#output]:find('FAIL',1,true),'session loss during read cannot produce PASS')
print=oldPrint
-- Saved-primary gate reuses exact economic evidence; only equipment INSERT is allowed.
current=true
local opted='0'; local veto=false; local inserted=0; local revoke=false
GetConvar=function() return opted end
GuardsAPI.CanChangeInstance=function(id,spec) assert(id==112 and spec.operation=='equipment_write'); return not veto end
tx.query=function(sql,params)
 if sql:find('SELECT character_id, slot FROM character_equipment',1,true) then return {} end
 if sql:find('INSERT INTO character_equipment',1,true)==1 then
  assert(params[1]==char and params[2]=='weapon' and params[3]==112)
  inserted=inserted+1; equipment[1]={slot='weapon',inventory_items_id=112}
  if revoke then current=false end
  return 1
 end
 return query(sql)
end
TransactionAPI.Transaction=function(_,fn)
 local previous=equipment[1]
 local result=fn(tx)
 if not result.ok then equipment[1]=previous end
 return result
end
print=function(v) output[#output+1]=v end
local primary=commands.InvJanePrimary
primary(0,{'1',char,'save'}); assert(inserted==0 and not equipment[1])
opted='1'; veto=true
primary(0,{'1',char,'save'}); assert(inserted==0 and not equipment[1])
veto=false; revoke=true
primary(0,{'1',char,'save'}); assert(inserted==1 and not equipment[1] and output[#output]:find('FAIL',1,true))
current=true; revoke=false
primary(0,{'1',char,'save'}); assert(inserted==2 and equipment[1] and output[#output]:find('PASS save',1,true))
primary(0,{'1',char,'save'}); assert(inserted==2,'retry must not rewrite equipment')
opted='0'; primary(0,{'1',char,'verify'}); assert(inserted==2 and output[#output]:find('PASS verify',1,true))
assert(not read().ok,'original unequipped verifier must reject saved equipment')
equipment[1]={slot='offhand',inventory_items_id=112}
primary(0,{'1',char,'verify'}); assert(output[#output]:find('FAIL',1,true))
equipment[1]={slot='weapon',inventory_items_id=112}
ledger.revision=5
operations[4]={operation_id='jane-primary-load-v1',result={fingerprint='ammo_revolver_regular:1:3',
 value={characterId=char,operationId='jane-primary-load-v1',revision=4,inventoryDelta=-1,pools=pools(1)}}}
operations[5]={operation_id='jane-primary-unload-v1',result={fingerprint='ammo_revolver_regular:-1:4',
 value={characterId=char,operationId='jane-primary-unload-v1',revision=5,inventoryDelta=1,pools=pools(0)}}}
local writes=inserted
primary(0,{'1',char,'verify-roundtrip'})
assert(output[#output]:find('PASS verify-roundtrip',1,true) and output[#output]:find('ledgerRevision5',1,true)
 and output[#output]:find('receipts6',1,true) and inserted==writes)
operations[5].result.fingerprint='wrong'; primary(0,{'1',char,'verify-roundtrip'}); assert(output[#output]:find('FAIL',1,true))
operations[5].result.fingerprint='ammo_revolver_regular:-1:4'
primary(0,{'1',char,'verify'}); assert(output[#output]:find('FAIL',1,true),'old revision3 verifier must not accept advanced state')
ledger.revision=6; ledger.pools.ammo_revolver_regular=1
local looseRow=rows[2]; rows[2]=nil
operations[6]={operation_id='jane-logout-load-v1',result={fingerprint='ammo_revolver_regular:1:5',
 value={characterId=char,operationId='jane-logout-load-v1',revision=6,inventoryDelta=-1,pools=pools(1)}}}
primary(0,{'1',char,'verify-carried'})
assert(output[#output]:find('PASS verify-carried',1,true) and output[#output]:find('ledgerRevision6 carried1 loose0 receipts7',1,true))
rows[2]=looseRow; primary(0,{'1',char,'verify-carried'}); assert(output[#output]:find('FAIL',1,true),'carried round cannot also remain loose')
ledger.revision=7; ledger.pools.ammo_revolver_regular=0
operations[7]={operation_id='jane-login-unload-v1',result={fingerprint='ammo_revolver_regular:-1:6',
 value={characterId=char,operationId='jane-login-unload-v1',revision=7,inventoryDelta=1,pools=pools(0)}}}
primary(0,{'1',char,'verify-login'})
assert(output[#output]:find('PASS verify-login',1,true) and output[#output]:find('ledgerRevision7',1,true)
 and output[#output]:find('receipts8',1,true) and inserted==writes)
operations[7].result.value.inventoryDelta=2
primary(0,{'1',char,'verify-login'}); assert(output[#output]:find('FAIL',1,true))
operations[7].result.value.inventoryDelta=1
ledger.revision=8; ledger.pools.ammo_revolver_regular=1; rows[2]=nil
operations[8]={operation_id='jane-auto-login-load-v1',result={fingerprint='ammo_revolver_regular:1:7',
 value={characterId=char,operationId='jane-auto-login-load-v1',revision=8,inventoryDelta=-1,pools=pools(1)}}}
primary(0,{'1',char,'verify-auto-carried'})
assert(output[#output]:find('PASS verify-auto-carried',1,true) and output[#output]:find('ledgerRevision8 carried1 loose0 receipts9',1,true))
ledger.revision=9; ledger.pools.ammo_revolver_regular=0; rows[2]=looseRow
operations[9]={operation_id='jane-auto-login-unload-v1',result={fingerprint='ammo_revolver_regular:-1:8',
 value={characterId=char,operationId='jane-auto-login-unload-v1',revision=9,inventoryDelta=1,pools=pools(0)}}}
primary(0,{'1',char,'verify-auto-login'})
assert(output[#output]:find('PASS verify-auto-login',1,true) and output[#output]:find('ledgerRevision9 carried0 loose1 receipts10',1,true) and inserted==writes)
operations[9].result.value.inventoryDelta=2
primary(0,{'1',char,'verify-auto-login'}); assert(output[#output]:find('FAIL',1,true))
operations[9].result.value.inventoryDelta=1
ledger.revision=11
operations[10]={operation_id='ui:2acadf8f-c503-11f1-9ae2-e0d55eaa2deb:100:1',result={fingerprint='ammo_revolver_regular:1:9',
 value={characterId=char,operationId='ui:2acadf8f-c503-11f1-9ae2-e0d55eaa2deb:100:1',revision=10,inventoryDelta=-1,pools=pools(1)}}}
operations[11]={operation_id='ui:2acadf8f-c503-11f1-9ae2-e0d55eaa2deb:200:2',result={fingerprint='ammo_revolver_regular:-1:10',
 value={characterId=char,operationId='ui:2acadf8f-c503-11f1-9ae2-e0d55eaa2deb:200:2',revision=11,inventoryDelta=1,pools=pools(0)}}}
primary(0,{'1',char,'verify-ui-roundtrip'})
assert(output[#output]:find('PASS verify-ui-roundtrip',1,true) and output[#output]:find('ledgerRevision11 carried0 loose1 receipts12',1,true) and inserted==writes)
operations[11].result.value.inventoryDelta=2
primary(0,{'1',char,'verify-ui-roundtrip'}); assert(output[#output]:find('FAIL',1,true))
operations[11].result.value.inventoryDelta=1
ledger.revision=13
for revision=12,13 do
 local load=revision==12
 local id='ui:a553eaab-c507-11f1-9ae2-e0d55eaa2deb:300:'..revision
 operations[revision]={operation_id=id,result={fingerprint='ammo_revolver_regular:'..(load and '1' or '-1')..':'..(revision-1),
  value={characterId=char,operationId=id,revision=revision,inventoryDelta=load and -1 or 1,pools=pools(load and 1 or 0)}}}
end
primary(0,{'1',char,'verify-native-draw'})
assert(output[#output]:find('PASS verify-native-draw',1,true) and output[#output]:find('ledgerRevision13 carried0 loose1 receipts14',1,true) and inserted==writes)
operations[13].result.value.pools.ammo_revolver_regular=1
primary(0,{'1',char,'verify-native-draw'}); assert(output[#output]:find('FAIL',1,true))
operations[13].result.value.pools.ammo_revolver_regular=0
ledger.revision=15
for revision=14,15 do
 local load=revision==14
 local session=load and 'e19e63ec-c5d6-11f1-9ae2-e0d55eaa2deb' or 'caf5d304-c5d7-11f1-9ae2-e0d55eaa2deb'
 local id='ui:'..session..':400:1'
 operations[revision]={operation_id=id,result={fingerprint='ammo_revolver_regular:'..(load and '1' or '-1')..':'..(revision-1),
  value={characterId=char,operationId=id,revision=revision,inventoryDelta=load and -1 or 1,pools=pools(load and 1 or 0)}}}
end
primary(0,{'1',char,'verify-native-login'})
assert(output[#output]:find('PASS verify-native-login',1,true) and output[#output]:find('ledgerRevision15 carried0 loose1 receipts16',1,true) and inserted==writes)
operations[15].result.value.inventoryDelta=2
primary(0,{'1',char,'verify-native-login'}); assert(output[#output]:find('FAIL',1,true))
operations[15].result.value.inventoryDelta=1
ledger.revision=17
for revision=16,17 do
 local load=revision==16
 local id='ui:bdda2682-c5da-11f1-9ae2-e0d55eaa2deb:500:'..revision
 operations[revision]={operation_id=id,result={fingerprint='ammo_revolver_regular:'..(load and '1' or '-1')..':'..(revision-1),
  value={characterId=char,operationId=id,revision=revision,inventoryDelta=load and -1 or 1,pools=pools(load and 1 or 0)}}}
end
primary(0,{'1',char,'verify-native-death'})
assert(output[#output]:find('PASS verify-native-death',1,true) and output[#output]:find('ledgerRevision17 carried0 loose1 receipts18',1,true) and inserted==writes)
operations[17].result.value.pools.ammo_revolver_regular=1
primary(0,{'1',char,'verify-native-death'}); assert(output[#output]:find('FAIL',1,true))
operations[17].result.value.pools.ammo_revolver_regular=0
ledger.revision=19; rows[2]=nil
local lastId='ui:d2883222-c5dd-11f1-9ae2-e0d55eaa2deb:600:1'
operations[18]={operation_id=lastId,result={fingerprint='ammo_revolver_regular:1:17',
 value={characterId=char,operationId=lastId,revision=18,inventoryDelta=-1,pools=pools(1)}}}
primary(0,{'1',char,'verify-native-shot'})
assert(output[#output]:find('PASS verify-native-shot',1,true) and output[#output]:find('ledgerRevision19 carried0 loose0 receipts19',1,true) and inserted==writes)
rows[2]=looseRow
primary(0,{'1',char,'verify-native-shot'}); assert(output[#output]:find('FAIL',1,true))
ledger.revision=21
rows[3]={id=204,definition_id=8,name='ammo_revolver_regular',type='item_ammo'}
local previewGrant={request_fingerprint=char..'|ammo_revolver_regular|8|2',result_json={characterId=char,
 grantId='native-test-jane-preview-regular-two-v1',itemName='ammo_revolver_regular',definitionId=8,quantity=2,instanceIds={301,302}}}
local originalQuery=tx.query
tx.query=function(sql,params)
 if sql:find('inventory_grant_receipts',1,true) and params[2]=='native-test-jane-preview-regular-two-v1' then return {previewGrant} end
 return originalQuery(sql,params)
end
for index=19,20 do
 local revision=index+1
 local load=revision==20
 local id='ui:d50e8cbd-c5e1-11f1-9ae2-e0d55eaa2deb:700:'..index
 operations[index]={operation_id=id,result={fingerprint='ammo_revolver_regular:'..(load and '1' or '-1')..':'..(revision-1),
  value={characterId=char,operationId=id,revision=revision,inventoryDelta=load and -1 or 1,pools=pools(load and 1 or 0)}}}
end
primary(0,{'1',char,'verify-preview-roundtrip'})
assert(output[#output]:find('PASS verify-preview-roundtrip',1,true) and output[#output]:find('ledgerRevision21 carried0 loose2 receipts22',1,true) and inserted==writes)
previewGrant.result_json.quantity=4
primary(0,{'1',char,'verify-preview-roundtrip'}); assert(output[#output]:find('FAIL',1,true))
previewGrant.result_json.quantity=2; rows[3]=nil
primary(0,{'1',char,'verify-preview-roundtrip'}); assert(output[#output]:find('FAIL',1,true))
print=oldPrint
print('Jane preview roundtrip verifier PASS (two grants, revision21, loose2, receipts22, corruption refusal)')
print('Jane native shot verifier PASS (revision19, no loose/carried round, exact load receipt, no writes)')
print('Jane loaded death verifier PASS (revision17, same-session conserved UI receipts, no writes)')
print('Jane normal loaded login verifier PASS (revision15, cross-session UI receipts, no writes)')
print('Jane native draw durable verifier PASS (revision13, four UI receipts, forged pool refusal)')
print('Jane UI roundtrip durable verifier PASS (revision11, exact UI receipts/deltas, no writes)')
print('Jane automatic login durable verifier PASS (ledger8/9, receipts9/10, conservation, forged delta refusal; mocked SQL)')
print('Jane saved-primary login durable verifier PASS (ledger7/receipts8/loose1/primary identity, no writes, forged unload delta refusal; mocked SQL)')
print('Jane saved-primary roundtrip durable verification PASS (ledger5, six exact receipts, unchanged loose1/equipment/metadata, no writes, receipt corruption refusal; mocked SQL)')
print('Jane saved primary PASS (opt-in, exact locked evidence, guard veto, post-write session rollback, idempotent save, SELECT-only verify, wrong-slot refusal; mocked SQL)')
print('Jane economic durable verifier PASS (SELECT-only, 27-pool ledger, four receipts, loose balance, unchanged item, equipment/receipt/balance corruption refusal; mocked SQL)')
