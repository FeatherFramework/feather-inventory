Config={AmmunitionPools={enabled=false},Escrow={maxTotal=200}}
dofile('../feather-weapons/shared/constants.lua'); dofile('../feather-weapons/shared/definitions/ammunition.lua')
dofile('../feather-weapons/shared/definitions/weapons.lua'); dofile('../feather-weapons/shared/validation.lua')
dofile('../feather-weapons/shared/character_ammunition_item.lua')
local definition=WeaponDefinitionCatalog.weapons.revolver_cattleman
Result={Ok=function(v) return {ok=true,value=v} end,Err=function(c,m) return {ok=false,error={code=c,message=m}} end}
RegisterCommand=function() end
local documents,seq={},0
json={encode=function(v) seq=seq+1; documents[tostring(seq)]=v; return tostring(seq) end,
 decode=function(v) local out={}; for k,x in pairs(documents[v]) do out[k]=x end; return out end}
dofile('server/services/native_repair_fixture.lua')
local metadata={schemaVersion=2,weaponDefinitionId=definition.id,serialNumber='original',condition=100,quality=100,
 maintenance={degradation=0,permanentDegradation=0,damage=0,dirt=0,soot=0},
 ammo={ownership='character',type=definition.ammunitionType},attachments={},cosmetics={},
 flags={stolen=false,evidence=false,disabled=false},provenance={}}
local active,failOil=true,false
local receipt,created,oil=nil,0,0
CharacterAmmoEnrollment={ReadJaneEconomic=function(_,_,primary,mode)
 assert(primary and mode=='funded-equipment'); return Result.Ok({})
end}
local tx={}
function tx.query(sql,args)
 if sql:find('INSERT IGNORE',1,true) then receipt=receipt or {request_fingerprint=args[3]}; return {} end
 if sql:find('SELECT request_fingerprint',1,true) then return {receipt} end
 if sql:find('FROM inventory WHERE',1,true) then return {{id=4}} end
 if sql:find('FROM items WHERE',1,true) then assert(args[1]=='gun_oil'); return {{id=9}} end
 if sql:find('UPDATE inventory_grant_receipts',1,true) then receipt.result_json=args[1]; return {affectedRows=1} end
 error(sql)
end
function tx:GetItemForUpdate(id)
 assert(id==112); return Result.Ok({inventoryId=4,revision=1,metadata=metadata,definition={id=2,name=definition.itemName}})
end
function tx:CreateInstance(inventory,id,value)
 assert(inventory==4 and id==2 and value.serialNumber~=metadata.serialNumber)
 assert(value.condition==50 and value.maintenance.permanentDegradation==0.1)
 assert(WeaponCharacterAmmoItem.Validate(value,definition))
 created=created+1; return Result.Ok({instanceId=200,revision=0})
end
function tx:AddQuantity(inventory,id,quantity)
 assert(inventory==4 and id==9 and quantity==1)
 if failOil then return Result.Err('missing','oil failed') end
 oil=oil+1; return Result.Ok({201})
end
local function run()
 local oldReceipt,oldCreated,oldOil=receipt,created,oil
 local result=NativeRepairFixture.Apply(tx,function() return active end,{},WeaponCharacterAmmoItem,definition)
 if not result.ok then receipt,created,oil=oldReceipt,oldCreated,oldOil end
 return result
end
active=false; assert(not run().ok and created==0)
active=true; failOil=true; assert(not run().ok and created==0 and oil==0 and receipt==nil)
failOil=false
local granted=run(); assert(granted.ok and granted.value.fixtureId==200 and created==1 and oil==1)
local replay=run(); assert(replay.ok and replay.value.replayed and created==1 and oil==1)
assert(metadata.serialNumber=='original' and metadata.condition==100 and metadata.maintenance.permanentDegradation==0)
receipt.request_fingerprint='conflict'; assert(not run().ok and created==1)
print('native_repair_fixture_spec PASS (exact one worn firearm/oil, real metadata validation, atomic rollback/replay, original untouched; mocked transaction)')
