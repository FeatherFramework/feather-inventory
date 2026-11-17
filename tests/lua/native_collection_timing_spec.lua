dofile('server/internal/native_collection_timing.lua')
local f=assert(io.open('fxmanifest.lua'));local manifest=f:read('*a');f:close()
assert(assert(manifest:find('/server/internal/native_collection_timing.lua',1,true))<assert(manifest:find('/server/services/*.lua',1,true)))
GetConvarInt=function() return 0 end
assert(not NativeCollectionTiming.New('claim',1,113),'profiling defaults off')
local now,reports=4294967290,{}
local p=assert(NativeCollectionTiming.New('claim',1,113,{enabled=true,now=function() return now end,
 emit=function(r) reports[#reports+1]=r end}))
local authority=p.Wrap('authority',function() now=now+4;return true,nil,'extra' end)
local body=p.Wrap('body',function() assert(authority());now=(now+8)%4294967296;return {ok=true},nil,42 end)
local result,missing,extra=p.Run(body)
assert(result.ok and missing==nil and extra==42,'all original return values are preserved')
local report=reports[1]
assert(report.totalMs==12 and report.authority.calls==1 and report.authority.totalMs==4
 and report.body.totalMs==12 and report.inclusive and report.itemId==113 and report.ok)
local p=NativeCollectionTiming.New('binding',1,113,{enabled=true,now=function() error('clock fault') end,
 emit=function() error('logging fault') end})
assert(p.Run(p.Wrap('body',function() return {ok=true} end)).ok,'diagnostic faults cannot change committed success')
local marker={reason='original transaction failure'}
local p=NativeCollectionTiming.New('claim',1,113,{enabled=true,now=function() return 0 end,emit=function(r) assert(not r.ok) end})
local ok,err=pcall(p.Run,p.Wrap('body',function() error(marker) end))
assert(not ok and err==marker,'original error identity propagates without retries')
local calls=0
local p=NativeCollectionTiming.New('binding',1,113,{enabled=true,now=function() return 0 end,emit=function(r) assert(not r.ok) end})
assert(p.Run(function() calls=calls+1;return {ok=false,code='denied'} end).code=='denied' and calls==1)
print('PASS native collection timing: opt-in, inclusive counts/durations/wrap, no result/error change or retry, logging/clock failures isolated')
