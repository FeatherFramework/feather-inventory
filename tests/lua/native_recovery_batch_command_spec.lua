Config={DevMode=true,CharacterAmmunitionEnabled=true}
local cid='6a2fd060-c46f-11f1-9ae2-e0d55eaa2deb'
local command,registered={},{}
local flags,files,objects={}, {},{}
local function copy(v) if type(v)~='table' then return v end;local r={};for k,x in pairs(v) do r[k]=copy(x) end;return r end
local seq=0
json={encode=function(v) seq=seq+1;objects[tostring(seq)]=copy(v);return tostring(seq) end,
 decode=function(v) return copy(assert(objects[v])) end}
GetCurrentResourceName=function() return 'feather-inventory' end
LoadResourceFile=function(_,p) return files[p] end
SaveResourceFile=function(_,p,s,n) assert(#s==n);files[p]=s;return 1 end
SetConvar=function(k,v) flags[k]=tonumber(v) end
GetConvarInt=function(k) return flags[k] or 0 end
GetResourceState=function() return 'started' end
InventoryIdentity={GetSession=function(src) return {ok=true,value={characterId=src==7 and cid or 'other',sessionId='session'}} end}
InventoryAPI={AccessModes={REMOVE='remove'}}
InventoryMetadata={DocumentsEqual=function(a,b) return a.id==b.id and a.revision==b.revision end}
Result={Err=function(code) return {ok=false,error={code=code}} end}
local row={id=229,inventory_id=2,item_id=1,slot_index=1,row_revision=8,character_id=cid,
 metadata={condition=100,quality=100,flags={disabled=false,evidence=false},
 weaponDefinitionId='utility_lasso',serialNumber='FW-LASS-6AE6BCBA-26771B-0001',
 provenance={reference='native-jane-ownership-lasso-alpha-v1'}}}
local killed,writes=0,0
DB={query=function() return {copy(row)} end}
GuardsAPI={CanMoveInstance=function() return true end}
for _,name in ipairs({'RegisterMoveGuard','RegisterDestroyGuard','RegisterInstanceChangeGuard'}) do
 GuardsAPI[name]=function(label,fn) assert(label=='feather-native-recovery-batch');registered[name]=fn;return {ok=true} end
end
RegisterCommand=function(name,fn,restricted) assert(restricted);command[name]=fn end
TransactionAPI={Transaction=function(context,body)
 local tx={
  AssertAccess=function(_,src,inv) assert(src==7 and inv==2);return {ok=true} end,
  GetItemForUpdate=function() return {ok=true,value={revision=8,inventoryId=2,metadata=row.metadata}} end,
  SetMetadata=function(_,id,doc,rev)
   assert(id==229 and doc.condition==99 and row.metadata.condition==100 and rev==8)
   assert(registered.RegisterInstanceChangeGuard({id=229},{operation='metadata_write',runtimeTicket=context.runtimeTicket,resource='feather-inventory'}))
   writes=writes+1;return {ok=true}
  end,
  query=function(sql)
   if sql=='SELECT CONNECTION_ID() AS connectionId' then return {{connectionId=123}} end
   assert(sql=='KILL CONNECTION 123','may only terminate own observed transaction')
   killed=killed+1;error('connection lost')
  end}
 local ok,v=pcall(body,tx)
 return ok and v or {ok=false,outcome='unknown',error={code='transaction_outcome_unknown'}}
end}
dofile('server/internal/native_recovery_batch.lua')
dofile('server/services/native_recovery_batch.lua')
local call=assert(command.InvNativeRecoveryBatch)
local notices=0
TranslateResult=function(src,result) assert(src==7);assert(result.skipReason=='native_recovery_audit_pending' or result.code=='transaction_outcome_unknown');return 'translated preview' end
Feather={Notify={RightNotify=function(src,message) assert(src==7 and message=='translated preview');notices=notices+1 end}}
call(1,{'notice','7','partial'});assert(notices==0)
call(0,{'notice','7','partial'});call(0,{'notice','7','unknown'})
assert(notices==2 and writes==0 and next(files)==nil,'previews must not mutate fixture or journal')
call(1,{'run','7','disconnect','8'});assert(writes==0)
call(0,{'run','7','disconnect','8'});assert(writes==0,'default off')
flags.feather_native_recovery_batch=1
call(0,{'run','7','disconnect','8'});assert(writes==0,'disconnect needs separate opt-in')
flags.feather_native_recovery_batch=1;flags.feather_native_recovery_disconnect=1
call(0,{'run','7','disconnect','8'})
assert(killed==1 and writes==1 and flags.feather_native_recovery_batch==0 and flags.feather_native_recovery_disconnect==0)
assert(not registered.RegisterMoveGuard({id=229}) and registered.RegisterMoveGuard({id=112}))
flags.feather_native_recovery_batch=1;flags.feather_native_recovery_disconnect=1
call(0,{'run','7','disconnect','8'});assert(killed==1,'journal prohibits another transaction')
assert(next(files),'journal retained')
print('PASS real service wiring: console/default/double opt-in gates, normal CAS/private hold, only own connection and persistent no-retry')
