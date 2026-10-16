local root=arg and arg[1] or '.'
Config={DevMode=true,CharacterAmmunitionEnabled=true}
Result={Ok=function(v) return {ok=true,value=v} end,Err=function(c,m) return {ok=false,error={code=c,message=m}} end}
local caller,session,authority='feather-weapons',true,true
GetInvokingResource=function() return caller end
GetResourceState=function() return 'started' end
local registered={}
local checks,transactions=0,0
exports=setmetatable({['feather-core']={IsSessionCurrent=function() return session end},
 ['feather-weapons']={ValidateNativeEvidenceCommit=function(_,context,spec)
  checks=checks+1
  return authority and context.ticket=='reserved' and spec.serialNumber=='SERIAL'
 end}},{__call=function(_,name,fn) registered[name]=fn end})
dofile(root..'/server/services/native_evidence_commit.lua')
local bodyCalls=0
NativeEvidenceCommit.Apply=function(tx,spec,current)
 bodyCalls=bodyCalls+1
 assert(current() and spec.itemId==135)
 return Result.Ok({itemId=135,revision=14})
end
TransactionAPI={Transaction=function(context,callback)
 transactions=transactions+1
 assert(context.actorSource==3 and context.sessionId=='sid' and context.reason=='native_evidence_hold')
 return callback({})
end}
local context={actorSource=3,characterId='Jane',sessionId='sid',ticket='reserved'}
local spec={characterId='Jane',itemId=135,serialNumber='SERIAL',held=true}
assert(registered.CommitNativeEvidenceTransition(context,spec).ok and checks>=3 and transactions==1 and bodyCalls==1)
caller='untrusted'; assert(not registered.CommitNativeEvidenceTransition(context,spec).ok and transactions==1)
caller='feather-weapons'; session=false
assert(not registered.CommitNativeEvidenceTransition(context,spec).ok and transactions==1)
session=true; authority=false
assert(not registered.CommitNativeEvidenceTransition(context,spec).ok and transactions==1)
authority=true
NativeEvidenceCommit.Apply=function() authority=false; return Result.Ok({itemId=135,revision=14}) end
assert(not registered.CommitNativeEvidenceTransition(context,spec).ok,'authority loss after body must request rollback')
assert(context.ticket=='reserved' and spec.serialNumber=='SERIAL','caller tables remain untouched')
print('Native evidence export PASS (trusted caller/current reserved validator, transaction authority boundaries, postbody rollback, private inputs; mocked body)')
