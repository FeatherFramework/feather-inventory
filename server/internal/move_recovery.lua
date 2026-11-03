-- Outcome reconciliation only: the original mutation callback is never retried.
InventoryMoveRecoveryEngine={}
function InventoryMoveRecoveryEngine.New(api)
 local T={}
 function T.Run(body,metrics,context,scope)
  local reserved,id,reason=pcall(api.reserve,scope,context)
  if not reserved or not id then return false,{outcome='not_executed',code=reason=='busy' and 'move_recovery_pending' or 'move_recovery_unavailable'} end
  if context then context.durableMoveOperationId=id end
  local entered,attempted=false,false
  local called,executed,committed=pcall(api.transaction,function(query)
   -- Even if an operator globally enabled provider deadlock retries, do not
   -- repeat this mutation callback or its Lua-side result accumulation.
   if attempted then return false end;attempted=true
   if api.lock(query,id,scope)~=true then return false end
   entered=true
   local accepted=body(query)
   if accepted~=true then return false end
   api.commitReceipt(query,id,scope.result and scope.result() or {},context,scope)
   return true
  end,metrics,context)
  if not called then executed,committed=false,{outcome='unknown'} end
  if executed and committed==true then api.changed(id,false);return true,true end
  -- Resolution locks the SAME scope and receipt rows as the original body.
  -- A pending receipt can be rolled back only after that lock is obtained;
  -- a delayed original body then sees the fence and cannot begin its writes.
  local resolved,outcome=pcall(api.resolve,id)
  if resolved and outcome=='committed' and entered then
   if metrics then metrics.committed=true;metrics.outcomeRecovered=not executed or committed~=true end
   api.changed(id,true);return true,true
  end
  if resolved and outcome=='rolled_back' then return true,false end
  return false,{outcome='unknown',code='move_recovery_pending',operationId=id,retrySafe=false}
 end
 function T.Sweep()
  local ok,ids=pcall(api.pending)
  if not ok or type(ids)~='table' then return false,1 end
  local waiting=0
  for _,id in ipairs(ids) do
   local resolved,outcome=pcall(api.resolve,id)
   if resolved and (outcome=='committed' or outcome=='rolled_back') then api.changed(id,true) else waiting=waiting+1 end
  end
  return true,waiting
 end
 return T
end
