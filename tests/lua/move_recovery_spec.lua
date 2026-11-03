dofile('server/internal/move_recovery.lua')
local function fixture()
 local db,seq,bodyCalls,refresh={},0,0,0
 local api={
  reserve=function() seq=seq+1;local id=tostring(seq);db[id]={state='pending',held=true};return id end,
  transaction=function(body) local ok=body({});return true,ok end,
  lock=function(_,id) return db[id].held and db[id].state=='pending' end,
  commitReceipt=function(_,id,result) db[id].state='committed';db[id].result=result;db[id].held=false end,
  resolve=function(id)
   local row=db[id]
   if row.state=='pending' then row.state='rolled_back' end
   row.held=false;return row.state
  end,
  pending=function() local ids={};for id in pairs(db) do ids[#ids+1]=id end;return ids end,
  changed=function() refresh=refresh+1 end}
 local scope={result=function() return {ids={229},revision=9} end}
 local function body() bodyCalls=bodyCalls+1;return true end
 return api,scope,db,body,function() return bodyCalls,refresh end
end
local api,scope,db,body,counts=fixture()
local e=InventoryMoveRecoveryEngine.New(api)
local x,y=e.Run(body,nil,{},scope);assert(x and y and counts()==1 and db['1'].state=='committed')
-- Real SQL body committed, but the caller receives an unknown provider reply.
api,scope,db,body,counts=fixture()
local original=api.transaction
api.transaction=function(callback) original(callback);return false,{outcome='unknown'} end
e=InventoryMoveRecoveryEngine.New(api)
x,y=e.Run(body,{}, {},scope)
assert(x and y and counts()==1 and db['1'].result.revision==9,'read committed receipt without replay')
-- Original transaction rolled back: model persistence of pending reservation.
api,scope,db,body,counts=fixture()
api.transaction=function(callback) callback({});db['1'].state='pending';db['1'].held=true;return false,{outcome='unknown'} end
e=InventoryMoveRecoveryEngine.New(api)
x,y=e.Run(body,nil,{},scope);assert(x and y==false and counts()==1 and db['1'].state=='rolled_back')
-- DB unavailable for outcome readback: preserve the exact original receipt.
api,scope,db,body,counts=fixture()
original=api.transaction
api.transaction=function(callback) original(callback);return false,{outcome='unknown'} end
local resolve=api.resolve
api.resolve=function() error('database down') end
e=InventoryMoveRecoveryEngine.New(api)
x,y=e.Run(body,nil,{},scope);assert(not x and y.outcome=='unknown' and y.operationId=='1' and counts()==1)
api.resolve=resolve
e=InventoryMoveRecoveryEngine.New(api) -- resource restart: persistence is in DB, not engine locals
assert(e.Sweep() and db['1'].state=='committed' and counts()==1,'background resolution must not replay body')
-- Reservation acknowledgement lost: original item mutation must never start.
api,scope,db,body,counts=fixture()
local reserve=api.reserve
api.reserve=function() reserve();error('lost reservation acknowledgement') end
e=InventoryMoveRecoveryEngine.New(api)
x,y=e.Run(body,nil,{},scope);assert(not x and y.outcome=='not_executed' and counts()==0)
api.reserve=reserve;assert(e.Sweep() and db['1'].state=='rolled_back' and counts()==0)
-- Recovery fencing wins before a delayed original begins.
api,scope,db,body,counts=fixture()
api.transaction=function(callback) api.resolve('1');return true,callback({}) end
e=InventoryMoveRecoveryEngine.New(api)
x,y=e.Run(body,nil,{},scope);assert(x and not y and counts()==0)
-- A policy refusal remains rollback, not success or an unknown retry loop.
api,scope,db,body,counts=fixture();e=InventoryMoveRecoveryEngine.New(api)
x,y=e.Run(function() return false end,nil,{},scope);assert(x and not y)
-- Protect against a globally configured provider callback retry.
api,scope,db,body,counts=fixture()
api.transaction=function(callback)
 callback({});db['1'].state='pending';db['1'].held=true
 return true,callback({})
end
e=InventoryMoveRecoveryEngine.New(api)
x,y=e.Run(body,nil,{},scope);assert(x and not y and counts()==1,'no mutation callback retry')
print('PASS durable move outcome protocol: committed/rollback reply loss, unavailable DB, restart sweep, late-original fencing, policy refusal and provider retry suppression')
