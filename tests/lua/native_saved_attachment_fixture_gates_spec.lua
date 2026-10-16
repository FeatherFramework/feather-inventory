Config={DevMode=true,CharacterAmmunitionEnabled=true}
local commands,encoded={},nil
RegisterCommand=function(name,callback) commands[name]=callback end
Result={Ok=function(v) return {ok=true,value=v} end,Err=function(c,m) return {ok=false,error={code=c,message=m}} end}
json={encode=function(value) encoded=value; return 'diagnostic' end}
local jane='6a2fd060-c46f-11f1-9ae2-e0d55eaa2deb'
InventoryIdentity={GetSession=function(id) assert(id==1); return Result.Ok({characterId=jane,sessionId='s'}) end}
InventoryReadiness={state='ready'}
local optIn,proof,current='0','stopped',true
GetConvar=function() return optIn end
GetResourceState=function(name) return name=='feather-weapons' and 'stopped' or proof end
exports={['feather-core']={IsSessionCurrent=function() return current end}}
TransactionAPI={Transaction=function() error('inspection must never enter transaction') end}
CharacterAmmoNativePreview={Load=function() error('inspection must never load fixture plan') end}
dofile('server/services/native_repair_fixture.lua')
local oldPrint=print; print=function() end
local run=commands.InvJaneSavedAttachmentFixture
run(0,{'1',jane,'inspect'})
assert(encoded.noSQLWrites and encoded.noNativeWrites and not encoded.allowed and not encoded.fixtureOptIn)
assert(encoded.characterMatches and encoded.coreCurrent and encoded.inventoryState=='ready')
optIn='1'; proof='missing'; run(0,{'1',jane,'inspect'})
assert(not encoded.allowed and encoded.proofState=='missing','diagnose exact refusal without weakening gate')
proof='stopped'; run(0,{'1',jane,'inspect'}); assert(encoded.allowed)
Config.CharacterAmmunitionEnabled=false
run(0,{'1',jane,'inspect'}); assert(not encoded.allowed and not encoded.inventoryCharacterAmmoEnabled,'saved fixture requires enabled native character-ammo feature, never disables server config')
Config.CharacterAmmunitionEnabled=true
current=false; run(0,{'1',jane,'inspect'}); assert(not encoded.allowed and not encoded.coreCurrent)
InventoryIdentity.GetSession=function() error('provider unavailable') end
run(0,{'1',jane,'inspect'}); assert(not encoded.allowed and not encoded.sessionReadSucceeded)
print=oldPrint
print('saved fixture diagnostics PASS (read-only exact gates, opt-in/proof/current/provider failure, no transaction/native writes)')
