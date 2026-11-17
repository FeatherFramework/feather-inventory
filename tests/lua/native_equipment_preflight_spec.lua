local registered={}
local invoking='feather-weapons'
local session=true
Config={DevMode=true,CharacterAmmunitionEnabled=true}
GetInvokingResource=function() return invoking end
Result={Err=function(code,message) return {ok=false,error={code=code,message=message}} end}
exports=setmetatable({['feather-core']={IsSessionCurrent=function(_,source,sid,cid)
 return session and source==1 and sid=='s' and cid=='jane'
end}},{__call=function(_,name,fn) registered[name]=fn end})
local candidate={id=112,row_revision=1,itemName='cattleman',metadata={ammo={ownership='character'}}}
local rows={{slot='weapon',inventory_items_id=112,row_revision=1,owner_character='jane'},
 {slot='hat',inventory_items_id=90,row_revision=2,owner_character='jane'}}
local calls=0
local lose=false
local original
local legacy={}
TransactionAPI={Transaction=function(_,fn)
 return fn({query=function(sql,args)
  calls=calls+1
  if original then original.characterId='foreign' end
  if lose then session=false end
  if sql:find('SELECT id FROM inventory',1,true)==1 then assert(args[1]=='jane'); return {{id=1}} end
  if sql:find('SELECT ce.slot',1,true)==1 then return rows end
  if sql:find('native_throwable_units_v1',1,true) then assert(args[1]=='jane');return legacy end
  if sql:find('SELECT ii.id',1,true)==1 then assert(args[1]==112 and args[2]=='jane'); return candidate and {candidate} or {} end
  error('No write query allowed: '..sql)
 end})
end}
CharacterAmmunitionAPI={ReadRuntimeEquipment=function() return {ok=true,value={primary={id=112,revision=1}}} end}
dofile('server/services/native_equipment_commit.lua')
local read=registered.ReadNativeEquipmentTransition
local function context() return {actorSource=1,sessionId='s',characterId='jane'} end
invoking='other'; assert(not read(context(),112).ok and calls==0); invoking='feather-weapons'
assert(not read(context(),-1).ok and calls==0)
original=context()
local result=read(original,112)
assert(result.ok and result.value.expected.hat.itemId==90 and result.value.candidate.revision==1)
original=nil
candidate=nil; assert(not read(context(),112).ok)
rows[1].owner_character='foreign'; assert(not read(context()).ok); rows[1].owner_character='jane'
lose=true; assert(not read(context()).ok,'session loss cannot return usable preflight')
lose=false;session=true
GetConvar=function(name,default) return name=='feather_throwable_quantities' and '1' or default end
NativeThrowableUnitStorage={Read=function() error('quantity preflight must not read physical unit custody') end}
CharacterAmmunitionAPI.ReadSnapshot=function(_,cid,limits)
 assert(cid=='jane' and limits.ammo_tomahawk_regular==3)
 return {ok=true,value={revision=9,pools={ammo_tomahawk_regular=3}}}
end
local deadContext=context();deadContext.epoch='death-epoch'
local quantity=read(deadContext,nil,{ammo_tomahawk_regular=3})
assert(quantity.ok and quantity.value.throwableEquipment.contract==3
 and quantity.value.throwableEquipment.identity.epoch=='death-epoch'
 and quantity.value.throwableEquipment.pools.ammo_tomahawk_regular==3)
legacy={{id=900}};assert(not read(deadContext,nil,{ammo_tomahawk_regular=3}).ok);legacy={}
rows[#rows+1]={slot='weapon_throwable',inventory_items_id=901,row_revision=0,owner_character='jane'}
assert(not read(deadContext,nil,{ammo_tomahawk_regular=3}).ok,'legacy equipped units remain refused')
table.remove(rows)
lose=true;assert(not read(deadContext,nil,{ammo_tomahawk_regular=3}).ok,'quantity read still checks current session')
print('Native equipment preflight PASS (caller/current/owned candidate/full snapshot/non-firearm slots/immutable context/no writes)')
