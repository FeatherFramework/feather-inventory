local root=arg and arg[1] or '.'
local function copy(v) if type(v)~='table' then return v end; local t={}; for k,x in pairs(v) do t[k]=copy(x) end; return t end
Result={Ok=function(v) return {ok=true,value=v} end,Err=function(c,m) return {ok=false,error={code=c,message=m}} end}
RegisterCommand=function() end
Config={CharacterAmmunitionEnabled=true}
local docs,n={},0
json={encode=function(v) n=n+1; docs[tostring(n)]=copy(v); return tostring(n) end,
 decode=function(v) assert(docs[v]); return copy(docs[v]) end}
dofile(root..'/server/services/grants_once.lua')
local db,active,capacity,failReceipt,loseAuthority,enrolled
local function reset()
 db={receipt=nil,items={},ledgerRevision=5,ammo=7,equipment={weapon=99}}
 active=true; capacity=true; failReceipt=false; loseAuthority=false; enrolled=true
end
local tx={query=function(sql,p)
 if sql:find('INSERT IGNORE',1,true) then db.receipt=db.receipt or {request_fingerprint=p[3]}; return {} end
 if sql:find('SELECT request_fingerprint',1,true) then return {db.receipt} end
 if sql:find('FROM inventory WHERE',1,true) then assert(p[1]=='John'); return {{id=5}} end
 if sql:find('FROM feather_character_ammunition',1,true) then return enrolled and {{revision=db.ledgerRevision}} or {} end
 if sql:find('FROM items WHERE',1,true) then return {{id=10,type='item_weapon',instance_mode='unique'}} end
 if sql:find('UPDATE inventory_grant_receipts',1,true) then
  if failReceipt then return {affectedRows=0} end
  db.receipt.result_json=p[1]; return {affectedRows=1}
 end
 error(sql)
end}
function tx:CreateInstance(inv,id,metadata)
 assert(inv==5 and id==10 and (metadata.weaponDefinitionId=='melee_knife'
  or metadata.weaponDefinitionId=='utility_lasso' or metadata.ammo.ownership=='character'))
 if not capacity then return Result.Err('capacity','full') end
 db.items={{id=300,metadata=copy(metadata)}}
 if loseAuthority then active=false end
 return Result.Ok({instanceId=300,revision=0})
end
local spec={resource='feather-weapons',requestId='native-v1',fingerprint='bound-payload',definitionId='revolver_cattleman',
 itemName='weapon_revolver_cattleman',metadata={serialNumber='FW-NATIVE-1',ammo={ownership='character',type='ammo_revolver_regular'}}}
local function apply()
 local before=copy(db)
 local result=NativeFirearmIssuanceAPI.Apply(tx,{characterId='John'},spec,function() return active end)
 if not result.ok then db=before end
 return result
end
reset(); local value=apply(); assert(value.ok and value.value.itemInstanceId==300 and #db.items==1)
assert(db.ammo==7 and db.ledgerRevision==5 and db.equipment.weapon==99,'no ammo/equipment writes')
db.items={}; value=apply(); assert(value.ok and value.value.replayed and #db.items==0,'historical receipt cannot recreate removed item')
db.receipt.request_fingerprint='foreign'; assert(not apply().ok)
reset(); capacity=false; assert(not apply().ok and db.receipt==nil and #db.items==0)
reset(); failReceipt=true; assert(not apply().ok and db.receipt==nil and #db.items==0)
reset(); loseAuthority=true; assert(not apply().ok and db.receipt==nil and #db.items==0)
reset(); enrolled=false; assert(not apply().ok and db.receipt==nil and #db.items==0)
reset(); active=false; assert(not apply().ok and db.receipt==nil)
assert(not NativeFirearmIssuanceAPI.Issue({},spec,'untrusted').ok)
print('Native issuance transaction PASS (atomic item/receipt, payload conflict, no replenishment, rollback, capacity/enrollment/authority refusal, unchanged equipment/ammo; mocked SQL)')
reset()
spec={resource='feather-weapons',requestId='knife-v1',fingerprint='knife-payload',definitionId='melee_knife',
 itemName='weapon_melee_knife',metadata={weaponDefinitionId='melee_knife',serialNumber='FW-KNIFE'}}
local knife=apply(); assert(knife.ok and db.items[1].metadata.ammo==nil and db.ammo==7 and db.ledgerRevision==5 and db.equipment.weapon==99)
db.items={}; assert(apply().value.replayed and #db.items==0,'knife replay never replenishes delivered item')
spec.fingerprint='changed'; assert(not apply().ok)
print('knife receipt reuse PASS (same canonical delivery namespace, no ammo/equipment writes, historical replay/conflict)')
reset()
spec={resource='feather-weapons',requestId='lasso-v1',fingerprint='lasso-payload',definitionId='utility_lasso',
 itemName='weapon_lasso',metadata={weaponDefinitionId='utility_lasso',serialNumber='FW-LASSO'}}
local lasso=apply()
assert(lasso.ok and lasso.value.itemInstanceId==300 and lasso.value.serialNumber=='FW-LASSO')
assert(db.items[1].metadata.ammo==nil and db.ammo==7 and db.ledgerRevision==5 and db.equipment.weapon==99)
db.items={}
local lassoReplay=apply()
assert(lassoReplay.ok and lassoReplay.value.replayed and #db.items==0 and lassoReplay.value.serialNumber=='FW-LASSO',
 'lasso historical receipt cannot replenish a transferred/destroyed item')
spec.fingerprint='different-lasso-payload'; assert(not apply().ok and #db.items==0)
print('lasso receipt reuse PASS: historical item/serial replay, no replenishment or equipment/ammo writes; mocked SQL')
