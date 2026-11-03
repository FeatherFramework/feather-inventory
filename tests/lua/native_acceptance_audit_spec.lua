local handler,caller,phase,reads=nil,'feather-weapons','cleared',0
local cids={'6a2fd060-c46f-11f1-9ae2-e0d55eaa2deb','4560a489-ca6c-11f1-9ad4-e0d55eaa2deb'}
Config={DevMode=true,CharacterAmmunitionEnabled=true}
GuardsAPI={HasRegisteredGuard=function() return true end,CanMoveInstance=function(id,context)
 assert(id==112 and context.operation=='acceptance_guard_read');return false end}
GetInvokingResource=function() return caller end
GetConvarInt=function() return 1 end
GetCurrentResourceName=function() return 'feather-inventory' end
LoadResourceFile=function() return 'journal' end
json={decode=function() return {version=1,phase=phase} end}
exports=function(name,fn) assert(name=='ReadNativeAcceptanceAudit');handler=fn end
local actors={{source=31,characterId=cids[1],sessionId='jane'},{source=87,characterId=cids[2],sessionId='john'}}
InventoryIdentity={GetSession=function(src)
 local a=src==31 and actors[1] or actors[2]
 return {ok=true,value={characterId=a.characterId,sessionId=a.sessionId}}
end}
DB={query=function(sql,arg)
 reads=reads+1;assert(sql:match('^SELECT'),'audit must never write')
 if sql:match('SELECT id FROM inventory ') then return {{id=arg==cids[1] and 2 or 5}} end
 if sql:match('FROM inventory_items') then return {{id=112,metadata={condition=100}},{id=230},{id=231,metadata=''}} end
 if sql:match('FROM feather_character_ammunition') then return {{revision=35,pools={ammo=1}}} end
 if sql:match('FROM character_equipment') then return {{slot='weapon',inventory_items_id=112}} end
 error('unexpected SQL')
end}
dofile('server/services/native_acceptance_audit.lua')
local audit=handler(actors)
assert(audit.ok and reads==8)
assert(audit.value[1].items[2].metadata==nil and audit.value[1].items[2].metadataState=='sql_null')
assert(audit.value[1].items[3].metadata=='' and audit.value[1].items[3].metadataState=='empty')
GuardsAPI.CanMoveInstance=function() return true end
assert(not handler(actors).ok,'unprotected equipped item cannot pass audit')
GuardsAPI.CanMoveInstance=function() return false end
caller='other';reads=0;assert(not handler(actors).ok and reads==0)
caller='feather-weapons';phase='awaiting_readback';assert(not handler(actors).ok and reads==0)
phase='cleared';Config.DevMode=false;assert(not handler(actors).ok and reads==0)
Config.DevMode=true;GetConvarInt=function() return 0 end;assert(not handler(actors).ok and reads==0)
GetConvarInt=function() return 1 end
actors[1].characterId='unrelated';assert(not handler(actors).ok and reads==0)
print('PASS read-only acceptance audit: provider caller/default gates, exact characters/current sessions, recovery hold and SELECT-only snapshots')
