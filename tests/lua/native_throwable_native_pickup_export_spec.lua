local function copy(v) if type(v)~='table' then return v end; local r={}; for k,x in pairs(v) do r[k]=copy(x) end; return r end
Result={Ok=function(v) return {ok=true,value=v} end,Err=function(c,m) return {ok=false,error={code=c,message=m}} end}
Config={DevMode=true,CharacterAmmunitionEnabled=true}
local registered={}
local authority,gate,caller,writes,lose=true,1,'feather-weapons',0,false
exports=setmetatable({['feather-core']={IsSessionCurrent=function() return authority end},
 ['feather-weapons']={ValidateCharacterAmmoRuntimeOperation=function(_,c,op,s)
  return authority and c.runtimeEpoch=='e' and c.runtimeTicket=='ticket' and op=='pickup' and s.nativePickupPlan.spendReceiptId=='spend11'
 end}},{__call=function(_,name,fn) registered[name]=fn end})
GetInvokingResource=function() return caller end
GetConvarInt=function() return gate end
GetResourceState=function() return 'started' end
TransactionAPI={Transaction=function(_,fn)
 local before=writes; local result=fn({}); if not result.ok then writes=before end; return result
end}
NativeThrowableNativePickupClaim={Apply=function(_,c,p,limits,current)
 assert(c.epoch=='e' and c.sessionId=='s' and p.expectedRevision==11 and limits.ammo_tomahawk_regular==1 and current())
 writes=writes+1; if lose then authority=false end
 return Result.Ok({characterId='john',revision=12,pools={ammo_tomahawk_regular=1}})
end}
dofile('server/services/native_throwable_native_pickup.lua')
local apply=assert(registered.ReconcileNativeThrowablePickup)
local context={actorSource=2,characterId='john',sessionId='s',runtimeEpoch='e',runtimeTicket='ticket'}
local spec={expectedRevision=11,limits={ammo_tomahawk_regular=1},nativePickupPlan={expectedRevision=11,spendReceiptId='spend11'}}
assert(apply(context,spec).ok and writes==1)
lose=true; assert(not apply(context,spec).ok and writes==1,'post-write authority loss rolls back')
authority=true; lose=false; gate=0; assert(not apply(context,spec).ok and writes==1)
gate=1; caller='untrusted'; assert(not apply(context,spec).ok and writes==1)
caller='feather-weapons'; local stale=copy(context); stale.runtimeTicket='old'
assert(not apply(stale,spec).ok and writes==1)
print('native pickup export PASS: trusted caller/reserved plan/current gate, transaction and post-write rollback; mocked claim')
local quantityGate='1';Config.DevMode=false;gate=0;authority=true
GetConvar=function(name,default) return name=='feather_throwable_quantities' and quantityGate or default end
exports['feather-weapons'].ValidateCharacterAmmoRuntimeOperation=function(_,c,op,s)
 return authority and c.runtimeEpoch=='e' and c.runtimeTicket=='ticket' and op=='pickup'
  and s.nativePickupPlan.version==2 and s.limits.ammo_tomahawk_regular==3
end
ThrowableQuantityRecovery={Claim=function(_,c,s,current)
 assert(c.characterId=='john' and c.runtimeEpoch=='e' and s.nativePickupPlan.version==2 and current())
 writes=writes+1;if lose then authority=false end
 return Result.Ok({characterId='john',revision=12,pools={ammo_tomahawk_regular=0},quantityDeclined=true,recovered=0})
end}
spec={expectedRevision=11,limits={ammo_tomahawk_regular=3},pools={ammo_tomahawk_regular=1},
 nativePickupPlan={version=2,kind='quantity_pickup_ledger_plan',expectedRevision=11}}
local result=apply(context,spec)
assert(result.ok and result.value.quantityDeclined and writes==2,'quantity mode requires its own opt-in, not legacy developer flags')
lose=true;assert(not apply(context,spec).ok and writes==2,'quantity post-write scope loss rolls back')
authority=true;lose=false;quantityGate='0';assert(not apply(context,spec).ok and writes==2)
quantityGate='1';caller='untrusted';assert(not apply(context,spec).ok and writes==2)
print('PASS quantity pickup export: separate opt-in, exact runtime ticket, no legacy developer flag, preserves definite denial, post-write rollback')
