dofile('server/internal/native_move_contention_probe.lua')
for _,mode in ipairs({'confirmed','refused','exception','session'}) do
 local calls=0
 local api={
  current=function() return mode~='session' end,
  capture=function() error('no hidden resolution or readback') end,
  move=function()
   calls=calls+1
   if mode=='exception' then error('unconfirmed outcome') end
   if mode=='refused' then return {error=true,code='denied'} end
   return {sourceItems={},targetItems={}}
  end}
 local result=NativeMoveContentionProbe.RunAckLoss(api,{},229,2,15)
 assert(calls==(mode=='session' and 0 or 1),'never retry')
 if mode=='confirmed' then
  assert(result.phase=='awaiting_independent_readback' and result.providerCommitConfirmed
   and result.simulatedCallerAcknowledgementLost and result.automaticRetries==0)
  assert(not result.ok and not result.sourceItems and not result.targetItems,'success reply not forwarded')
 elseif mode=='session' then assert(result.phase=='refused')
 else assert(result.phase=='failed' and not result.simulatedCallerAcknowledgementLost) end
end
print('PASS confirmed-commit caller-ack loss simulation, no hidden readback/retry, unknown/refusal remains unresolved')
