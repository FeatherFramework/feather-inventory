Config={};GetGameTimer=function() return 1 end
warn=function() end;CreateThread=function() end
InventoryMutationMetrics={};GuardsAPI={EmitTransactionCommitted=function() error('unknown cannot emit commit') end}
dofile('server/helpers/result.lua')
local provider,bodyCalls
DB={transaction=function(body)
 body({raw=function() return {} end})
 error(provider)
end}
dofile('server/services/transactions.lua')
for _,failure in ipairs({
 {code='BRIDGE_ERROR',outcome='unknown'},
 {code='RESOURCE_STOPPED',outcome='unknown'},
 {code='WATCHDOG_TIMEOUT',outcome='unknown'},
 {code='BROKEN_PROVIDER_WITHOUT_OUTCOME'},
 'unclassified transport error'
}) do
 provider=failure;bodyCalls=0
 local before=TransactionAPI.GetMetrics()
 local result=TransactionAPI.Transaction({idempotencyKey='unknown',correlationId='c'},function()
  bodyCalls=bodyCalls+1;return Result.Ok({changed=true})
 end)
 assert(not result.ok and result.error.code=='transaction_outcome_unknown')
 assert(result.outcome=='unknown' and result.error.details.outcome=='unknown' and result.retrySafe==false)
 assert(result.correlationId=='c' and bodyCalls==1)
 local after=TransactionAPI.GetMetrics()
 assert(after.unknown==before.unknown+1 and after.rolledBack==before.rolledBack and after.committed==before.committed)
 assert(after.idempotentHits==before.idempotentHits,'never cache an unknown success')
end
provider={code='ER_LOCK_DEADLOCK',outcome='rolled_back'}
local known=TransactionAPI.Transaction({},function() return Result.Ok({}) end)
assert(not known.ok and known.error.code~='transaction_outcome_unknown')
print('PASS native transaction outcome preservation, no rollback/success/cache claim on ambiguous provider errors')
