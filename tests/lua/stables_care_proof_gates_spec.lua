local root=arg[1]
Config={DevMode=true,TrustedConsumptionCallers={}}
InventoryReadiness={state='ready'}
Result={Ok=function(v) return {ok=true,value=v} end,Err=function(code,message) return {ok=false,error={code=code,message=message}} end}
local sql=0
DB={one=function() sql=sql+1; error('no active fixture') end}
dofile(root..'/server/services/stables_care_proof.lua')
local P=StablesCareConsumptionProof
assert(P.Step('prepare','other').error.code=='authorization_denied' and sql==0)
Config.DevMode=false; assert(P.Step('prepare','bcc-stables').error.code=='authorization_denied' and sql==0)
assert(P.TryInspect({operationId='bccb000b-0000-4000-8000-000000000001'},'bcc-stables')==false)
Config.DevMode=true; InventoryReadiness.state='starting'
assert(P.Step('consume','bcc-stables').error.code=='authorization_denied' and sql==0)
InventoryReadiness.state='ready'
assert(P.Step('unknown','bcc-stables').error.code=='invalid_input' and sql==0)
assert(P.TryInspect({operationId='10000000-0000-4000-8000-000000000001'},'bcc-stables')==false and sql==0)
assert(P.TryInspect({operationId='bccb000b-0000-4000-8000-000000000001'},'other')==false and sql==0)
local handled,result=P.TryInspect({operationId='bccb000b-0000-4000-8000-000000000001'},'bcc-stables')
assert(handled and result.error.code=='fixture_refused' and sql==1)
assert(P.Step('consume','bcc-stables').error.code=='fixture_outcome_unknown' and sql==2)
assert(next(Config.TrustedConsumptionCallers)==nil)
print('PASS Stables care provider proof gates: exact caller/development/readiness/action/reserved receipt identity, no global policy change')
