-- Actual runtime SQL/wiring against a transactionally rolled-back model.
dofile('server/internal/move_recovery.lua')
local copy
copy=function(v) if type(v)~='table' then return v end;local o={};for k,x in pairs(v) do o[k]=copy(x) end;return o end
local state={operations={},scopes={},outbox={},marker=0}
local failOutbox,loseMutationReply=false,false
local commands,threads,documents={},{},{}
local serial,jsonSerial=0,0
Config={DevMode=true}
CountPlaceholders=function(sql) local _,n=sql:gsub('%?','');return n end
json={encode=function(v) jsonSerial=jsonSerial+1;documents[tostring(jsonSerial)]=copy(v);return tostring(jsonSerial) end,
 decode=function(raw) return copy(documents[raw]) end}
GetPlayers=function() return {} end
TriggerClientEvent=function() error('no players expected') end
RegisterCommand=function(n,fn,restricted) assert(restricted);commands[n]=fn end
CreateThread=function(fn) threads[#threads+1]=fn end
Wait=function() coroutine.yield() end
local itemSQL=0
local function query(sql,...)
 local p={...};if sql:find('inventory_items',1,true) then itemSQL=itemSQL+1;error('self test cannot touch items') end
 if sql=='UPDATE test_gameplay_marker' then state.marker=state.marker+1;return {affectedRows=1} end
 if sql:match('SELECT id,character_id FROM inventory') then return {} end
 if sql:match('INSERT INTO inventory_move_outbox') then
  if failOutbox then error('outbox unavailable') end
  assert(not state.outbox[p[1]]);state.outbox[p[1]]=p[2];return {affectedRows=1}
 end
 if sql:match('^CREATE TABLE') then return {} end
 if sql:match('SELECT ENGINE') then return {{ENGINE='InnoDB'}} end
 if sql:match('SHOW INDEX') then return {{Key_name='PRIMARY',Seq_in_index=1,Column_name=sql:find('outcomes') and 'operation_id' or 'inventory_id'}} end
 if sql:find('LIMIT 0',1,true) then return {} end
 if sql:match('INSERT INTO inventory_move_scopes') then
  for _,id in ipairs(p) do if not state.scopes[id] then state.scopes[id]={inventory_id=id} end end;return {}
 end
 if sql:match('SELECT inventory_id,operation_id FROM inventory_move_scopes') then
  local rows={};for id,row in pairs(state.scopes) do if id==p[1] or id==p[2] then rows[#rows+1]=copy(row) end end
  table.sort(rows,function(a,b) return a.inventory_id<b.inventory_id end);return rows
 end
 if sql:match('INSERT INTO inventory_move_outcomes') then
  assert(not state.operations[p[1]])
  state.operations[p[1]]={operation_id=p[1],source_inventory=p[2],target_inventory=p[3],actor_character_id=p[4],state=p[5],refresh_pending=1};return {affectedRows=1}
 end
 if sql:match('UPDATE inventory_move_scopes SET operation_id=%?') then
  local changed=0;for id,row in pairs(state.scopes) do if (id==p[2] or id==p[3]) and not row.operation_id then row.operation_id=p[1];changed=changed+1 end end
  return {affectedRows=changed}
 end
 if sql:match('UPDATE inventory_move_scopes SET operation_id=NULL') then
  local id=#p==1 and p[1] or p[3]
  for _,row in pairs(state.scopes) do if row.operation_id==id then row.operation_id=nil end end;return {}
 end
 if sql:match('SELECT operation_id,state,source_inventory') then return {copy(assert(state.operations[p[1]]))} end
 if sql:match('SELECT source_inventory,target_inventory') or sql:match('SELECT actor_character_id,source_inventory') then return {copy(assert(state.operations[p[1]]))} end
 if sql:match('UPDATE inventory_move_outcomes SET state=%?,result_json') then
  local row=assert(state.operations[p[3]]);assert(row.state==p[4]);row.state=p[1];row.result_json=p[2];return {affectedRows=1}
 end
 if sql:match('UPDATE inventory_move_outcomes SET state=%?') then state.operations[p[2]].state=p[1];return {affectedRows=1} end
 if sql:match('UPDATE inventory_move_outcomes SET refresh_pending') then state.operations[p[1]].refresh_pending=0;return {} end
 if sql:match('SELECT character_id FROM inventory') or sql:match('SELECT id FROM inventory') then return {} end
 if sql:match('SELECT operation_id FROM inventory_move_outcomes') then return {} end
 if sql=='SELECT 1' then return {{one=1}} end
 error('unexpected SQL: '..sql)
end
DB={query=query,exec=query,value=function(sql) assert(sql=='SELECT UUID()');serial=serial+1;return ('00000000-0000-0000-0000-%012d'):format(serial) end}
DB.transaction=function(body)
 local before=copy(state)
 local ok,v=pcall(body,{raw=query})
 if not ok or v==false then state=before end
 if not ok then error(v) end
 if loseMutationReply and state.marker>before.marker then loseMutationReply=false;error('lost reply after actual commit') end
 return v~=false
end
RunLegacyStyleTransaction=function(body)
 return pcall(DB.transaction,function(tx) return body(function(sql,p) return tx.raw(sql,table.unpack(p or {},1,CountPlaceholders(sql))) end) end)
end
InventoryMoveMaintenance={Start=function() end}
InventoryMoveOutbox={Start=function() end,Headers=function() return {} end,Append=function() end}
dofile('server/services/move_recovery.lua')
assert(InventoryMoveRecovery.Run(function() error('unready body') end,nil,{},{} )==false)
InventoryMoveRecovery.Start();assert(InventoryMoveRecovery.Status().ready and #threads==1)
commands.InvMoveRecoveryAcceptance(99,{})
assert(serial==0,'player may not invoke tests')
commands.InvMoveRecoveryAcceptance(0,{})
local report=documents[tostring(jsonSerial)]
assert(report.phase=='passed' and report.checks==4 and report.itemWrites==0 and serial==4)
assert(itemSQL==0)
for _,row in pairs(state.scopes) do assert(row.operation_id==nil,'diagnostic scopes must be released') end
local committed,rolled=0,0
for _,row in pairs(state.operations) do if row.state=='committed' then committed=committed+1 else assert(row.state=='rolled_back');rolled=rolled+1 end end
assert(committed==2 and rolled==2)
print('PASS actual move recovery runtime: schema readiness, real transaction adapter, atomic receipt/scope SQL and four-step no-item-write acceptance')

-- Compose the actual outbox append into the actual recovery transaction adapter.
dofile('server/services/move_outbox.lua')
local scope={sourceInventory=9007199254740990,targetInventory=9007199254740991,result=function() return {kind='item_move',movedIds={}} end}
failOutbox=true
local executed,committed=InventoryMoveRecovery.Run(function(q) q('UPDATE test_gameplay_marker',{});return true end,nil,{},scope)
assert(executed and committed==false and state.marker==0 and next(state.outbox)==nil,'outbox failure rolls back original body and outcome receipt')
failOutbox=false;loseMutationReply=true
executed,committed=InventoryMoveRecovery.Run(function(q) q('UPDATE test_gameplay_marker',{});return true end,nil,{},scope)
assert(executed and committed==true and state.marker==1,'lost committed acknowledgement never repeats original body')
local count=0;for id,document in pairs(state.outbox) do count=count+1;assert(state.operations[id].state=='committed' and documents[document].operationId==id) end
assert(count==1,'one actual outbox entry commits with one original mutation')
print('PASS actual recovery/outbox composition: append failure rolls back original mutation and receipt; lost commit reply preserves one outbox entry without replay')
