local routes={}
Feather={RPC={Register=function(name,fn) routes[name]=fn end}}
Config={CharacterAmmunitionEnabled=false}
local reads=0
local session={ok=true,value={characterId='jane',sessionId='s'}}
InventoryIdentity={GetSession=function(src) assert(src==5); return session end}
local swap=false
InventoryAPI={GetCharacterInventory=function(id) assert(id=='jane'); reads=reads+1; return {ok=true,value={id=7}} end,
 GetInventoryItems=function(id) assert(id==7); if swap then session={ok=true,value={characterId='other',sessionId='new'}} end
 return {ok=true,value={{id=112,name='weapon_revolver_cattleman'}}} end}
dofile('server/services/callbacks.lua')
local result
local function respond(v) result=v end
local read=routes['Feather:Inventory:NativeAmmoInventory']
read({characterId='foreign',inventory=999},respond,5)
assert(not result.ok and reads==0)
Config.CharacterAmmunitionEnabled=true
read({characterId='foreign',inventory=999},respond,5)
assert(result.ok and reads==1 and result.value.characterId=='jane' and result.value.items[1].id==112)
swap=true
read({},respond,5)
assert(not result.ok and result.error.code=='ammunition_preview_context_changed')
print('native ammo own-inventory preview PASS (gate, ignored foreign input, post-read session check)')
