-- Actual runtime snapshot entry point, modeled SQL transaction with rollback.
Result={Codes={DENIED='denied',CONFLICT='conflict',NOT_FOUND='missing',INVALID_INPUT='invalid'},
 Ok=function(v) return {ok=true,value=v} end,Err=function(c,m) return {ok=false,error={code=c,message=m}} end}
Config={DevMode=false,CharacterAmmunitionEnabled=true}
json={encode=function(v) return v end,decode=function(v) if v=='bad' then error('bad json') end return v end}
RegisterCommand=function() end
GetConvarInt=function() return 0 end
local alive=true
exports={['feather-core']={IsSessionCurrent=function() return alive end}}
dofile('server/services/character_ammunition.lua')
local A=CharacterAmmunitionAPI
local state,queries,inserted,expire
local function reset()
 state={inventory=true,items={},equipment={},receipts={}}
 queries,inserted,expire=0,0,nil;alive=true
end
local function query(sql,params)
 queries=queries+1
 if sql:find('SELECT id FROM inventory',1,true) then return state.inventory and {{id=2}} or {} end
 if sql:find('SELECT revision, pools',1,true) then return state.ledger and {state.ledger} or {} end
 if sql:find('SELECT operation_id',1,true) then return state.receipts end
 if sql:find('SELECT slot FROM character_equipment',1,true) then return state.equipment end
 if sql:find('SELECT ii.metadata',1,true) then return state.items end
 if sql:find('INSERT INTO feather_character_ammunition',1,true) then
  inserted=inserted+1;state.ledger={revision=0,pools=params[2]}
  if expire=='ledger' then alive=false end
  return {affectedRows=1}
 end
 if sql:find('INSERT INTO feather_ammunition_operations',1,true) then
  inserted=inserted+1
  assert(params[2]=='native-character-ammo-initialization-v1')
  state.receipts={{operation_id=params[2],result=params[3]}}
  return {affectedRows=expire=='receipt' and 0 or 1}
 end
 error('Unexpected mutation/query: '..sql)
end
TransactionAPI={Transaction=function(context,fn)
 assert(context.resource=='feather-weapons')
 local beforeLedger,beforeReceipts=state.ledger,state.receipts
 local result=fn({query=query})
 if not result.ok then state.ledger,state.receipts=beforeLedger,beforeReceipts end
 return result
end}
A.ReadRuntimeEquipment=function()
 if expire=='equipment' then return Result.Err('conflict','equipment read failed') end
 return Result.Ok({})
end
local context={actorSource=1,characterId='character',sessionId='session'}
local limits={ammo_revolver_regular=200,ammo_repeater_regular=200}
local function start(caller) return A.RuntimeSnapshot(context,limits,caller or 'feather-weapons') end
reset();state.items={{name='bread',type='item_standard',metadata={quality=100}}}
local first=start()
assert(first.ok and first.value.revision==0 and inserted==2)
for _,amount in pairs(first.value.pools) do assert(amount==0) end
assert(state.items[1].metadata.quality==100 and #state.equipment==0)
state.ledger.revision=9;state.ledger.pools.ammo_revolver_regular=7
local again=start()
assert(again.ok and again.value.revision==9 and again.value.pools.ammo_revolver_regular==7 and inserted==2,
 'existing balances and receipt must never be reset or duplicated')
for _,item in ipairs({{name='weapon_lasso'}, {name='ammo_revolver'}, {name='custom',type='item_weapon'},
 {name='custom',type='item_ammo'}, {name='custom',metadata={ammo={clip=6}}},
 {name='custom',metadata={weaponDefinitionId='x'}}, {name='custom',metadata='bad'},
 {name='custom',metadata=17}, {metadata={}}}) do
 reset();state.items={item};assert(not start().ok and inserted==0)
end
reset();state.equipment={{slot='weapon'}};assert(not start().ok and inserted==0)
reset();state.receipts={{operation_id='history'}};assert(not start().ok and inserted==0)
reset();state.inventory=false;assert(not start().ok and inserted==0)
reset();alive=false;assert(not start().ok and queries==0)
reset();assert(not start('untrusted').ok and queries==0)
reset();Config.CharacterAmmunitionEnabled=false;assert(not start().ok and queries==0);Config.CharacterAmmunitionEnabled=true
for _,failure in ipairs({'ledger','receipt','equipment'}) do
 reset();expire=failure;assert(not start().ok and not state.ledger and #state.receipts==0,'failed setup rolls back both writes')
end
reset();assert(not A.ReadSnapshot({query=query},context.characterId,limits,false).ok and inserted==0,
 'ordinary read-only snapshot cannot initialize data')
print('Fresh character runtime setup PASS (zero ledger, existing balances, ordinary starter items, migration/history guards, caller/session and atomic rollback)')
