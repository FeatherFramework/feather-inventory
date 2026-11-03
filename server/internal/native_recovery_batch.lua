-- Pure state machine for the dedicated rollback/disconnect fixture batch.
NativeRecoveryBatch={}
function NativeRecoveryBatch.New(api)
 local j=api.load()
 local phases={prepared=true,awaiting_readback=true,verified_rollback=true,cleared=true}
 local corrupt=j~=nil and (type(j)~='table' or j.version~=1 or type(j.used)~='table'
  or type(j.history)~='table' or not phases[j.phase]
  or (j.phase~='cleared' and (type(j.before)~='table' or j.before.id~=229)))
 local executing,ticket=false,{}
 local T={}
 local function save()
  if api.save(j)~=true then corrupt=true;return false end
  return true
 end
 function T.Guard(item,context)
  if not item or tonumber(item.id)~=229 then return true end
  if corrupt then return false,'native_recovery_audit_pending' end
  if not j or j.phase=='cleared' then return true end
  if executing and context and context.operation=='metadata_write'
   and context.runtimeTicket==ticket and context.resource=='feather-inventory' then return true end
  return false,'native_recovery_audit_pending'
 end
 function T.Status()
  if corrupt then return {phase='journal_invalid_do_not_retry'} end
  return {phase=j and j.phase or 'idle',mode=j and j.mode,connectionId=j and j.connectionId,
   providerOutcome=j and j.providerOutcome,automaticRetries=0,itemId=229}
 end
 function T.Run(mode,expected)
  if corrupt or (j and j.phase~='cleared') or (mode~='rollback' and mode~='disconnect') then return T.Status() end
  if j and j.used[mode] then return {phase='refused',reason='mode_already_used_no_retry'} end
  local before=api.capture()
  if not api.current() or not api.fixture(before) or before.revision~=expected then
   return {phase='refused',reason='exact_current_fixture_revision_required'}
  end
  j={version=1,phase='prepared',mode=mode,before=before,used=j and j.used or {},history=j and j.history or {}}
  j.used[mode]=true
  if not save() then return T.Status() end -- journal readback must precede dispatch
  executing=true
  local called,result=pcall(api.execute,mode,before,ticket,function(id)
   if type(id)~='number' or id<1 or id%1~=0 then error('invalid_connection_id') end
   j.connectionId=id;if not save() then error('journal_not_durable') end
  end)
  executing=false
  j.phase='awaiting_readback'
  j.providerOutcome=called and type(result)=='table' and result.outcome or 'unknown'
  j.providerCode=called and type(result)=='table' and result.error and result.error.code or nil
  if j.providerCode=='recovery_probe_rollback' then j.providerOutcome='rolled_back' end
  if j.providerOutcome~='rolled_back' and j.providerOutcome~='not_executed' then j.providerOutcome='unknown' end
  if not save() then return T.Status() end
  return T.Status()
 end
 function T.Verify()
  if corrupt or not j or j.phase~='awaiting_readback' then return T.Status() end
  -- Baseline-looking rows alone cannot prove an outstanding transaction rolled back.
  if j.providerOutcome~='rolled_back' and
   not (j.mode=='disconnect' and j.connectionId and api.connectionGone(j.connectionId)==true) then
   return {phase='unresolved',reason='rollback_or_terminated_connection_not_established',automaticRetries=0}
  end
  local after=api.capture()
  if not api.equal(after,j.before) then return {phase='unresolved',reason='durable_fixture_mismatch',automaticRetries=0} end
  j.phase='verified_rollback';if not save() then return T.Status() end
  return T.Status()
 end
 function T.Clear()
  if corrupt or not j or j.phase~='verified_rollback' then return {phase='refused',reason='verified_rollback_required'} end
  -- Recheck immediately before releasing the durable diagnostic hold.
  if not api.equal(api.capture(),j.before) then return {phase='unresolved',reason='fixture_changed_after_verification'} end
  j.history[#j.history+1]={mode=j.mode,revision=j.before.revision,outcome=j.providerOutcome}
  j.phase='cleared';if not save() then return T.Status() end
  return T.Status()
 end
 return T
end
