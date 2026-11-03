Result={Ok=function(v) return {ok=true,value=v} end,Err=function(c) return {ok=false,error={code=c}} end}
Config={DevMode=true,CharacterAmmunitionEnabled=true}
local gate,caller,session,reserved,transactions,wears,commits,lose=1,'feather-weapons',true,true,0,0,0,false
local registered={}
local reinforcedGate,davyGate,binocularsGate,cameraGate,advancedCameraGate,improvedGate=0,0,0,0,0,0
local metalDetectorGate,fishingRodGate=0,0
GetInvokingResource=function() return caller end
GetConvarInt=function(name,default)
 assert(default==0)
 if name=='feather_native_lasso_reinforced' then return reinforcedGate end
 if name=='feather_native_davy_lantern' then return davyGate end
 if name=='feather_native_binoculars' then return binocularsGate end
 if name=='feather_native_camera' then return cameraGate end
 if name=='feather_native_camera_advanced' then return advancedCameraGate end
 if name=='feather_native_binoculars_improved' then return improvedGate end
 if name=='feather_native_metal_detector' then return metalDetectorGate end
 if name=='feather_native_fishing_rod' then return fishingRodGate end
 assert(name=='feather_native_utility'); return gate
end
GetResourceState=function() return 'started' end
exports=setmetatable({['feather-core']={IsSessionCurrent=function() return session end},
 ['feather-weapons']={ValidateNativeEquipmentCommit=function(_,c,s)
  assert(c.ticket=='ticket' and c.epoch=='epoch' and s.utilityId==200); return reserved
 end}}, {__call=function(_,name,fn) registered[name]=fn end})
TransactionAPI={Transaction=function(_,fn) transactions=transactions+1; return fn({}) end}
NativeLifecycleWear={Apply=function(_,s,current)
 assert(current()); wears=wears+1; return Result.Ok(s)
end}
local install=dofile('server/internal/native_utility_exports.lua')
assert(next(registered)==nil,'file load cannot register live admission')
install({Read=function(_,cid,current) assert(cid=='john' and current()); return Result.Ok({characterId=cid}) end,
 Apply=function(_,s,current) assert(s.utilityId==200 and current()); commits=commits+1
  if lose then reserved=false end; return Result.Ok({slot='weapon_utility'}) end})
local c={actorSource=4,characterId='john',sessionId='s',epoch='epoch',ticket='ticket'}
local s={characterId='john',utility=true,slot='weapon_utility',action='equip',utilityId=200,lifecycleSnapshot={},lifecycleWear={}}
assert(registered.ReadNativeUtilityEquipment(c).ok)
assert(registered.CommitNativeUtilityEquipment(c,s).ok and wears==1 and commits==1)
for _,mode in ipairs({'gate','caller','session','reservation','wear_missing'}) do
 local before=transactions
 gate=mode=='gate' and 0 or 1; caller=mode=='caller' and 'foreign' or 'feather-weapons'
 session=mode~='session'; reserved=mode~='reservation'
 if mode=='wear_missing' then s.lifecycleWear=nil end
 assert(not registered.CommitNativeUtilityEquipment(c,s).ok and transactions==before)
 s.lifecycleWear={}
end
gate=1; caller='feather-weapons'; session=true; reserved=true; lose=true
assert(not registered.CommitNativeUtilityEquipment(c,s).ok,'post-write authority loss must return rollback result')
reserved=true; lose=false; s.slot='weapon_utility_secondary'; s.lassoFamily=true
local before=transactions
assert(not registered.CommitNativeUtilityEquipment(c,s).ok and transactions==before,'secondary requires independent admission')
reinforcedGate=1
assert(registered.CommitNativeUtilityEquipment(c,s).ok)
reinforcedGate=0
assert(not registered.CommitNativeUtilityEquipment(c,s).ok,'revoked family reservation cannot commit')
print('staged utility export factory PASS: explicit installation, default-off/current caller/session/reservation/final-wear gates and post-write refusal; mocked TX')
s.lassoFamily=nil; s.davyFamily=true
assert(not registered.CommitNativeUtilityEquipment(c,s).ok)
davyGate=1
assert(registered.CommitNativeUtilityEquipment(c,s).ok)
davyGate=0
assert(not registered.CommitNativeUtilityEquipment(c,s).ok,'Davy reserved mode requires independent admission')
davyGate=1; s.binocularsFamily=true; s.slot='weapon_utility_tertiary'
assert(not registered.CommitNativeUtilityEquipment(c,s).ok)
binocularsGate=1
assert(registered.CommitNativeUtilityEquipment(c,s).ok)
binocularsGate=0
assert(not registered.CommitNativeUtilityEquipment(c,s).ok,'Binoculars reservation requires independent third-slot admission')
binocularsGate=1; s.cameraFamily=true; s.slot='weapon_utility_quaternary'
assert(not registered.CommitNativeUtilityEquipment(c,s).ok)
cameraGate=1
assert(registered.CommitNativeUtilityEquipment(c,s).ok)
cameraGate=0
assert(not registered.CommitNativeUtilityEquipment(c,s).ok,'Camera reservation requires independent fourth-slot admission')
cameraGate=1; s.advancedCameraFamily=true; s.slot='weapon_utility_quinary'
local beforeAdvanced=transactions
assert(not registered.CommitNativeUtilityEquipment(c,s).ok and transactions==beforeAdvanced)
advancedCameraGate=1
assert(registered.CommitNativeUtilityEquipment(c,s).ok)
advancedCameraGate=0
assert(not registered.CommitNativeUtilityEquipment(c,s).ok,'Advanced Camera reservation requires independent fifth-slot admission')
advancedCameraGate=1; s.improvedBinocularsFamily=true; s.slot='weapon_utility_senary'
local beforeImproved=transactions
assert(not registered.CommitNativeUtilityEquipment(c,s).ok and transactions==beforeImproved)
improvedGate=1
assert(registered.CommitNativeUtilityEquipment(c,s).ok)
improvedGate=0
assert(not registered.CommitNativeUtilityEquipment(c,s).ok,'sixth reserved mode requires own gate')
improvedGate=1
for _,tool in ipairs({{'weapon_utility_septenary','metalDetectorFamily'}, {'weapon_utility_octonary','fishingRodFamily'}}) do
 s.slot=tool[1];s[tool[2]]=true
 local before=transactions;assert(not registered.CommitNativeUtilityEquipment(c,s).ok and transactions==before)
 if tool[2]=='metalDetectorFamily' then metalDetectorGate=1 else fishingRodGate=1 end
 assert(registered.CommitNativeUtilityEquipment(c,s).ok)
 if tool[2]=='metalDetectorFamily' then metalDetectorGate=0 else fishingRodGate=0 end
 assert(not registered.CommitNativeUtilityEquipment(c,s).ok)
 s[tool[2]]=nil
end
