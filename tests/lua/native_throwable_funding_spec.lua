Result={Codes={CONFLICT='conflict'},Ok=function(v) return {ok=true,value=v} end,
 Err=function(c,m) return {ok=false,error={code=c,message=m}} end}
IsCallable=nil
local function equal(a,b)
 if type(a)~=type(b) then return false end
 if type(a)~='table' then return a==b end
 for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
 for k in pairs(b) do if a[k]==nil then return false end end; return true
end
InventoryMetadata={DocumentsEqual=equal}
exports=function() end; RegisterCommand=function() end
dofile('server/services/character_ammunition.lua')
local authority,revision,count,writes=true,7,0,0
local metadata={serialNumber='T',ammo={ownership='character',type='ammo_tomahawk_regular'}}
local expected={weapon_throwable={itemId=170,revision=0}}
CharacterAmmunitionAPI.ReadSnapshot=function() return Result.Ok({revision=revision,pools={ammo_tomahawk_regular=count}}) end
NativeThrowableEquipment={Read=function() return Result.Ok({expected=expected,
 equipment={throwable={id=170,revision=0,metadata=metadata}}}) end}
CharacterAmmunitionAPI.Apply=function(tx,context,spec)
 assert(spec.ammunitionId=='ammo_tomahawk_regular' and spec.operationId=='fund-v1')
 writes=writes+1; return Result.Ok({revision=8})
end
local spec={characterId='john',action='throwable-funding',slot='weapon_throwable',amount=1,
 ammunitionId='ammo_tomahawk_regular',limits={ammo_tomahawk_regular=1},expectedRevision=7,
 expectedPools={ammo_tomahawk_regular=0},expected=expected,before=metadata,
 throwableId=170,throwableRevision=0,operationId='fund-v1'}
local function run() return CharacterAmmunitionAPI.ApplyThrowableFunding({}, {characterId='john'},spec,function() return authority end) end
assert(run().ok and writes==1)
authority=false; assert(not run().ok and writes==1); authority=true
revision=8; assert(not run().ok and writes==1); revision=7
count=1; assert(not run().ok and writes==1); count=0
spec.throwableId=171; assert(not run().ok and writes==1); spec.throwableId=170
spec.amount=2; assert(not run().ok and writes==1); spec.amount=1
local original=CharacterAmmunitionAPI.Apply
CharacterAmmunitionAPI.Apply=function(...) authority=false; return original(...) end
assert(not run().ok and writes==2) -- enclosing transaction must roll back
print('staged throwable funding primitive PASS: exact released reservation/equipment/ledger; canonical Apply only; post-write authority rollback')
