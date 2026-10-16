local function copy(v) if type(v)~='table' then return v end; local out={}; for k,x in pairs(v) do out[k]=copy(x) end; return out end
local docs,n={},0
json={encode=function(v) n=n+1; docs[tostring(n)]=copy(v); return tostring(n) end,decode=function(v) return copy(docs[v]) end}
Result={Codes={DENIED='denied',INVALID_INPUT='input',CONFLICT='conflict',NOT_FOUND='missing'},
 Ok=function(v) return {ok=true,value=v} end,Err=function(c) return {ok=false,error={code=c}} end}
Config={DevMode=true,CharacterAmmunitionEnabled=true}
RegisterCommand=function() end
InventoryIdentity={NormalizeCharacterId=function(id) return id end}
local authority,failWear,expire=true,false,false
exports={['feather-core']={IsSessionCurrent=function() return true end},
 ['feather-weapons']={ValidateCharacterAmmoRuntimeOperation=function() return authority end}}
local database={revision=25,pools={ammo=1},itemRevision=4}
local order={}
local tx={query=function(sql,p)
 if sql:find('SELECT id FROM inventory',1,true) then return {{id=2}} end
 if sql:find('SELECT revision, pools',1,true) then return {{revision=database.revision,pools=json.encode(database.pools)}} end
 if sql:find('UPDATE feather_character',1,true) then database.revision=p[2]; database.pools=json.decode(p[1]); order[#order+1]='ammo'; return {affectedRows=1} end
 error(sql)
end}
NativeLifecycleWear={Apply=function(_,spec,current)
 assert(spec.characterId=='Jane' and current()); database.itemRevision=database.itemRevision+1; order[#order+1]='wear'
 if failWear then return Result.Err('wear_cas_failed') end
 if expire then authority=false end
 return Result.Ok(spec)
end}
TransactionAPI={Transaction=function(_,body)
 local before=copy(database); local result=body(tx); if not result.ok then database=before end; return result
end}
dofile('server/services/character_ammunition.lua')
local context={actorSource=1,characterId='Jane',sessionId='s',runtimeEpoch='e',runtimeTicket='ticket'}
local spec={expectedRevision=25,pools={ammo=0},limits={ammo=10},finalWear={characterId='Jane',lifecycleWear={}}}
local A=CharacterAmmunitionAPI
failWear=true; assert(not A.Observe(context,spec,'feather-weapons').ok and database.revision==25 and database.itemRevision==4,'wear failure rolls back preceding ammo reduction')
failWear=false; expire=true; assert(not A.Observe(context,spec,'feather-weapons').ok and database.revision==25 and database.itemRevision==4,'authority loss rolls back both')
expire=false; authority=true; order={}
local result=A.Observe(context,spec,'feather-weapons')
assert(result.ok and database.revision==26 and database.itemRevision==5 and order[1]=='ammo' and order[2]=='wear')
spec.expectedRevision=26; spec.pools.ammo=0; order={}
result=A.Observe(context,spec,'feather-weapons')
assert(result.ok and database.revision==26 and database.itemRevision==6 and order[1]=='wear','zero belt does not churn ledger')
print('Death ammo/wear atomic composition PASS (one transaction, wear failure and authority loss roll back ammo, unchanged ledger persists wear only)')
