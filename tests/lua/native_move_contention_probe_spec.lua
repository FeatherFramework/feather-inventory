dofile('server/internal/native_move_contention_probe.lua')
local function copy(v) if type(v)~='table' then return v end;local r={};for k,x in pairs(v) do r[k]=copy(x) end;return r end
local function equal(a,b)
 if type(a)~=type(b) then return false end;if type(a)~='table' then return a==b end
 for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
 for k in pairs(b) do if a[k]==nil then return false end end;return true
end
for _,mode in ipairs({'overlap','serial','exception','metadata_change','sibling_change','duplicate','session_change','timeout'}) do
 local before={{id=229,inventory_id=2,item_id=1,slot_index=1,row_revision=4,metadata={serial='same'}},
  {id=112,inventory_id=2,item_id=2,slot_index=2,row_revision=2,metadata={wear=1}}}
 local rows=copy(before);local threads,clock={},0
 local api={now=function() return clock end,current=function() return true end,
  capture=function() return copy(rows) end,equal=equal,
  spawn=function(fn) threads[#threads+1]=coroutine.create(fn) end}
 api.wait=function()
  if coroutine.isyieldable() then coroutine.yield();return end
  clock=clock+1000
  for _,co in ipairs(threads) do if coroutine.status(co)~='dead' then assert(coroutine.resume(co)) end end
 end
 api.move=function()
  if mode~='serial' then coroutine.yield() end
  if mode=='timeout' then while true do coroutine.yield() end end
  if mode=='exception' then error('SQL unknown') end
  if rows[1].inventory_id~=2 then return {error=true,code='not_found'} end
  rows[1].inventory_id=15;rows[1].row_revision=5
  if mode=='metadata_change' then rows[1].metadata.serial='changed' end
  if mode=='sibling_change' then rows[2].row_revision=3 end
  if mode=='duplicate' then rows[3]=copy(rows[1]) end
  if mode=='session_change' then api.current=function() return false end end
  return {}
 end
 local result=NativeMoveContentionProbe.Run(api,before,229,2,15)
 if mode=='overlap' then assert(result.phase=='passed' and result.revision==5 and result.overlappingMoveCalls)
 elseif mode=='serial' then assert(result.phase=='inconclusive' and not result.overlappingMoveCalls)
 else assert(result.phase=='failed',mode) end
end
print('PASS move probe overlap evidence, serial inconclusive, exact conservation and ambiguous/timeout refusal')
