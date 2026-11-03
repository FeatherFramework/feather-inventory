dofile('server/internal/native_recovery_batch.lua')
local function copy(v) if type(v)~='table' then return v end;local r={};for k,x in pairs(v) do r[k]=copy(x) end;return r end
local function equal(a,b)
 if type(a)~=type(b) then return false end;if type(a)~='table' then return a==b end
 for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
 for k in pairs(b) do if a[k]==nil then return false end end;return true
end
local saved,failSave,gone,current,calls=nil,false,false,true,0
local row={id=229,revision=8,metadata={condition=100}}
local engine
local api={
 load=function() return copy(saved) end,
 save=function(j) if failSave then return false end;saved=copy(j);return true end,
 current=function() return current end,
 capture=function() return copy(row) end,
 fixture=function(v) return v and v.id==229 end,
 equal=equal,connectionGone=function(id) assert(id==99);return gone end,
 execute=function(mode,before,ticket,record)
  calls=calls+1;assert(saved.phase=='prepared','journal must precede transaction')
  assert(not engine.Guard({id=229},{operation='move'}))
  assert(engine.Guard({id=229},{operation='metadata_write',runtimeTicket=ticket,resource='feather-inventory'}))
  assert(not engine.Guard({id=229},{operation='metadata_write',runtimeTicket={},resource='feather-inventory'}))
  if mode=='rollback' then return {ok=false,error={code='recovery_probe_rollback'}} end
  record(99);assert(saved.connectionId==99,'connection id persisted before fault')
  return {ok=false,outcome='unknown',error={code='transaction_outcome_unknown'}}
 end}
engine=NativeRecoveryBatch.New(api)
assert(engine.Status().phase=='idle' and engine.Guard({id=229}))
assert(engine.Run('rollback',7).phase=='refused' and calls==0)
failSave=true;assert(engine.Run('rollback',8).phase=='journal_invalid_do_not_retry' and calls==0)
assert(not engine.Guard({id=229}) and engine.Guard({id=112}))
failSave=false;engine=NativeRecoveryBatch.New(api)
assert(engine.Run('rollback',8).phase=='awaiting_readback' and calls==1)
assert(engine.Clear().phase=='refused')
assert(engine.Verify().phase=='verified_rollback')
assert(not engine.Guard({id=229}),'verification alone must not release hold')
assert(engine.Clear().phase=='cleared' and engine.Guard({id=229}))
assert(engine.Run('rollback',8).phase=='refused' and calls==1,'persisted one-use per mode')
assert(engine.Run('disconnect',8).providerOutcome=='unknown' and calls==2)
-- Simulate resource restart: all active hold and evidence comes from persisted journal.
engine=NativeRecoveryBatch.New(api)
assert(not engine.Guard({id=229}) and engine.Status().connectionId==99)
assert(engine.Run('disconnect',8).phase=='awaiting_readback' and calls==2)
assert(engine.Verify().phase=='unresolved' and not engine.Guard({id=229}),'baseline alone cannot resolve live connection')
gone=true;row.metadata.condition=99
assert(engine.Verify().phase=='unresolved' and engine.Clear().phase=='refused')
row.metadata.condition=100
assert(engine.Verify().phase=='verified_rollback' and engine.Clear().phase=='cleared')
assert(engine.Run('disconnect',8).phase=='refused' and calls==2)
saved=false;engine=NativeRecoveryBatch.New(api)
assert(not engine.Guard({id=229}) and engine.Status().phase=='journal_invalid_do_not_retry')
print('PASS durable predispatch journal, exact private metadata ticket, restart hold, terminated-connection/readback verification and explicit cleanup')
