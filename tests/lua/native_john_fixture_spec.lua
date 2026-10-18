local root=arg and arg[1] or '.'
local runtime=assert(io.open(root..'/server/services/native_repair_fixture.lua','r'))
local runtimeSource=runtime:read('*a'); runtime:close()
assert(not runtimeSource:find('InvJohnNativeFixture',1,true),'retired fixture command must not ship in runtime')
Config={AmmunitionPools={enabled=false},Escrow={maxTotal=200}}
dofile('../feather-weapons/shared/constants.lua'); dofile('../feather-weapons/shared/definitions/ammunition.lua')
dofile('../feather-weapons/shared/definitions/weapons.lua'); dofile('../feather-weapons/shared/validation.lua')
dofile('../feather-weapons/shared/character_ammunition_item.lua')
local function copy(v) if type(v)~='table' then return v end; local t={}; for k,x in pairs(v) do t[k]=copy(x) end; return t end
Result={Ok=function(v) return {ok=true,value=v} end,Err=function(c,m) return {ok=false,error={code=c,message=m}} end}
RegisterCommand=function() end
local docs,n={},0
json={encode=function(v) n=n+1; docs[tostring(n)]=copy(v); return tostring(n) end,decode=function(v) assert(docs[v]); return copy(docs[v]) end}
dofile(root..'/tests/lua/fixtures/native_john_fixture_legacy.lua')
local john='4560a489-ca6c-11f1-9ad4-e0d55eaa2deb'
local db,active,failAmmo,failReceipt,loseAuthority
local function reset()
 db={receipt=nil,items={},equipment={},ledger={revision=0,pools=json.encode({ammo_revolver_regular=0})},loose=0}
 active=true; failAmmo=false; failReceipt=false; loseAuthority=false
end
local tx={query=function(sql,p)
 if sql:find('INSERT IGNORE',1,true) then db.receipt=db.receipt or {request_fingerprint=p[3]}; return {} end
 if sql:find('SELECT request_fingerprint',1,true) then return {db.receipt} end
 if sql:find('FROM inventory WHERE',1,true) then assert(p[1]==john); return {{id=9}} end
 if sql:find('FROM feather_character_ammunition',1,true) then assert(p[1]==john); return {copy(db.ledger)} end
 if sql:find('FROM inventory_items',1,true) then assert(p[1]==9); return copy(db.items) end
 if sql:find('FROM character_equipment',1,true) then assert(p[1]==john); return copy(db.equipment) end
 if sql:find('FROM items WHERE',1,true) then return {{id=10,name='weapon_revolver_cattleman',type='item_weapon',instance_mode='unique'},
  {id=11,name='ammo_revolver_regular',type='item_ammo',instance_mode='stack'}} end
 if sql:find('UPDATE inventory_grant_receipts',1,true) then
  if failReceipt then return {affectedRows=0} end; db.receipt.result_json=p[1]; return {affectedRows=1}
 end
 error(sql)
end}
function tx:CreateInstance(inv,id,metadata)
 assert(inv==9 and id==10 and WeaponCharacterAmmoItem.Validate(metadata,WeaponDefinitionCatalog.weapons.revolver_cattleman))
 assert(metadata.ammo.ownership=='character' and metadata.ammo.loaded==nil and metadata.ammo.reserve==nil)
 db.items={{id=300,metadata=copy(metadata)}}; if loseAuthority then active=false end
 return Result.Ok({instanceId=300,revision=0})
end
function tx:AddQuantity(inv,id,amount)
 assert(inv==9 and id==11 and amount==2)
 if failAmmo then return Result.Err('fail','ammo capacity refused') end
 db.loose=db.loose+2; return Result.Ok({301})
end
local function apply()
 local before=copy(db)
 local result=NativeJohnMultiplayerFixture.Apply(tx,function() return active end,{ammo_revolver_regular=200},WeaponCharacterAmmoItem,WeaponDefinitionCatalog.weapons.revolver_cattleman)
 if not result.ok then db=before end; return result
end
reset(); assert(apply().ok and #db.items==1 and db.loose==2 and db.ledger.revision==0 and next(db.equipment)==nil)
assert(docs[db.ledger.pools].ammo_revolver_regular==0)
db.loose=0; db.items={}; assert(apply().value.replayed and db.loose==0 and #db.items==0,'receipt never replenishes removed fixture')
reset(); failAmmo=true; assert(not apply().ok and #db.items==0 and db.receipt==nil)
reset(); failReceipt=true; assert(not apply().ok and #db.items==0 and db.loose==0 and db.receipt==nil)
reset(); loseAuthority=true; assert(not apply().ok and #db.items==0 and db.receipt==nil)
reset(); db.items={{id=999}}; assert(not apply().ok and #db.items==1 and db.receipt==nil)
reset(); db.equipment={{slot='weapon'}}; assert(not apply().ok and db.receipt==nil)
reset(); db.ledger.revision=1; assert(not apply().ok and db.receipt==nil)
reset(); db.ledger.pools=json.encode({ammo_revolver_regular=1}); assert(not apply().ok)
reset(); active=false; assert(not apply().ok and db.receipt==nil)
reset(); assert(apply().ok); db.receipt.request_fingerprint='foreign'; assert(not apply().ok and db.loose==2)
print('John bounded fixture PASS (native metadata, receipt replay/no replenishment, zero carried ammo, exact target, item/ammo/receipt/authority rollback; mocked SQL)')
