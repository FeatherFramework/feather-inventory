Config={DevMode=true,CharacterAmmunitionEnabled=false}
Result={Codes={DENIED='denied',NOT_FOUND='missing',CONFLICT='conflict'},
    Err=function(code,message) return {ok=false,error={code=code,message=message}} end,
    Ok=function(value) return {ok=true,value=value} end}
RegisterCommand=function() end
local scope='1'
GetConvar=function() return scope end
local jane='6a2fd060-c46f-11f1-9ae2-e0d55eaa2deb'
exports={['feather-core']={IsSessionCurrent=function() return true end}}
json={decode=function(value) return value end}
local queries=0
local tx={query=function(sql)
    queries=queries+1
    assert(sql:find('SELECT',1,true)==1,'read-only scope never writes')
    if sql:find('SELECT id',1,true) then return {{id=1}} end
    if sql:find('SELECT revision',1,true) then return {{revision=0,pools={ammo_revolver_regular=0}}} end
    error(sql)
end}
TransactionAPI={Transaction=function(_,fn) return fn(tx) end}
dofile('server/services/character_ammunition.lua')
local ctx={actorSource=1,characterId=jane,sessionId='s'}
local limits={ammo_revolver_regular=200}
assert(CharacterAmmunitionAPI.Snapshot(ctx,limits,'feather-weapons').ok and queries==2)
assert(not CharacterAmmunitionAPI.Mutate(ctx,{},'feather-weapons').ok and queries==2,'read scope cannot authorize mutation')
assert(not CharacterAmmunitionAPI.Observe(ctx,{},'feather-weapons').ok and queries==2)
assert(not CharacterAmmunitionAPI.Snapshot(ctx,limits,'proof').ok and queries==2)
ctx.characterId='original'; assert(not CharacterAmmunitionAPI.Snapshot(ctx,limits,'feather-weapons').ok and queries==2)
ctx.characterId=jane; Config.DevMode=false
assert(not CharacterAmmunitionAPI.Snapshot(ctx,limits,'feather-weapons').ok and queries==2)
Config.DevMode=true; scope='0'
assert(not CharacterAmmunitionAPI.Snapshot(ctx,limits,'feather-weapons').ok and queries==2)
scope='1'
local query=tx.query
tx.query=function(sql) local value=query(sql); scope='0'; return value end
assert(not CharacterAmmunitionAPI.Snapshot(ctx,limits,'feather-weapons').ok,'scope lost during read cannot return authority')
print('Inventory Jane development read scope PASS (trusted caller, UUID, DevMode, opt-in, no mutation, post-read revocation)')
