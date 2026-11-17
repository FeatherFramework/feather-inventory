-- Opt-in, request-local diagnostics. Never grants, caches authority, retries or
-- changes transaction results. Inclusive body/authority times must not be added.
NativeCollectionTiming={}
function NativeCollectionTiming.New(stage,source,itemId,api)
 if stage~='binding' and stage~='claim' then return nil end
 if not api then
  local ok,flag=pcall(function() return GetConvarInt('feather_native_collection_timing',0) end)
  if not ok or flag~=1 then return nil end
  api={enabled=true,now=GetGameTimer,emit=function(record) print('[NativeCollectionTiming] '..json.encode(record)) end}
 end
 if api.enabled~=true then return nil end
 local samples={}
 local function clock()
  local ok,value=pcall(api.now)
  return ok and type(value)=='number' and value==value and math.abs(value)<math.huge and value or nil
 end
 local function elapsed(started)
  local finished=clock()
  return started and finished and (finished-started)%4294967296 or nil
 end
 local P={}
 function P.Wrap(name,fn)
  assert(name=='authority' or name=='body','Unsupported collection timing span')
  return function(...)
   local started=clock()
   local values=table.pack(pcall(fn,...))
   local ms=elapsed(started)
   local row=samples[name] or {calls=0,totalMs=0,maxMs=0};samples[name]=row
   row.calls=row.calls+1
   if ms then row.totalMs=row.totalMs+ms;row.maxMs=math.max(row.maxMs,ms) else row.clockUnavailable=true end
   if not values[1] then error(values[2],0) end
   return table.unpack(values,2,values.n)
  end
 end
 function P.Run(fn)
  local started=clock()
  local values=table.pack(pcall(fn))
  local result=values[2]
  local report={stage=stage,source=source,itemId=itemId,totalMs=elapsed(started),inclusive=true,
   authority=samples.authority,body=samples.body,ok=values[1] and type(result)=='table' and result.ok==true or false}
  -- Logging/clock faults may not turn a committed transaction into uncertainty.
  pcall(api.emit,report)
  if not values[1] then error(values[2],0) end
  return table.unpack(values,2,values.n)
 end
 return P
end
