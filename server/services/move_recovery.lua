-- Always-on ordinary-move outcome receipts. Schema is owned by Inventory and
-- initialized before readiness. Never replays gameplay writes or invents rows.
InventoryMoveRecovery={}
local R=InventoryMoveRecovery
local ready=false
local cursor=''
local function integer(v) local n=tonumber(v);return n and n>0 and n%1==0 and n<9007199254740992 and n end
local function inventories(scope)
 local a,b=integer(scope.sourceInventory),integer(scope.targetInventory)
 assert(a and b,'invalid_move_recovery_scope')
 if a>b then a,b=b,a end
 return a,b
end
local function raw(tx)
 return function(sql,params) return tx.raw(sql,table.unpack(params or {},1,CountPlaceholders(sql))) end
end
local function lockScopes(query,a,b)
 query('INSERT INTO inventory_move_scopes (inventory_id) VALUES (?),(?) ON DUPLICATE KEY UPDATE inventory_id=inventory_move_scopes.inventory_id',{a,b})
 local rows=query('SELECT inventory_id,operation_id FROM inventory_move_scopes WHERE inventory_id IN (?,?) ORDER BY inventory_id FOR UPDATE',{a,b})
 assert(type(rows)=='table' and #rows==(a==b and 1 or 2),'move_scope_unavailable')
 return rows
end
local function receipt(query,id)
 local rows=query('SELECT operation_id,state,source_inventory,target_inventory,result_json FROM inventory_move_outcomes WHERE operation_id=? FOR UPDATE',{id})
 assert(type(rows)=='table' and #rows==1,'move_receipt_unavailable')
 return rows[1]
end
local function notify(id)
 -- Refresh only already-open books; client RefreshInventory never opens a UI.
 -- This signal contains no item data or authority, and may be repeated safely.
 local rows=DB.query('SELECT actor_character_id,source_inventory,target_inventory FROM inventory_move_outcomes WHERE operation_id=?',id)
 local row=rows and rows[1];if not row then return end
 local headers=DB.query('SELECT character_id FROM inventory WHERE id IN (?,?)',row.source_inventory,row.target_inventory)
 local recipients={[row.actor_character_id or '']=true}
 for _,header in ipairs(headers or {}) do if header.character_id then recipients[header.character_id]=true end end
 for _,src in ipairs(GetPlayers()) do
  local session=InventoryIdentity.GetSession(tonumber(src))
  if session and session.ok and recipients[session.value.characterId] then
   TriggerClientEvent('Feather:Inventory:RefreshInventory',tonumber(src))
  end
 end
 -- Unknown acknowledgement here just repeats a harmless refresh next sweep.
 DB.exec('UPDATE inventory_move_outcomes SET refresh_pending=0 WHERE operation_id=? AND state IN (?,?)',id,'committed','rolled_back')
end
local adapters={
 reserve=function(scope,context)
  assert(ready,'move_recovery_not_ready')
  local a,b=inventories(scope)
  local id=DB.value('SELECT UUID()');assert(type(id)=='string' and #id==36,'move_operation_id_unavailable')
  local committed=DB.transaction(function(tx)
   local query=raw(tx);local locks=lockScopes(query,a,b)
   for _,row in ipairs(locks) do if row.operation_id then return false end end
   query('INSERT INTO inventory_move_outcomes (operation_id,source_inventory,target_inventory,actor_character_id,state) VALUES (?,?,?,?,?)',
    {id,scope.sourceInventory,scope.targetInventory,context and context.actorCharacterId,'pending'})
   local write=query('UPDATE inventory_move_scopes SET operation_id=? WHERE inventory_id IN (?,?) AND operation_id IS NULL',{id,a,b})
   assert(tonumber(write and write.affectedRows)==(a==b and 1 or 2),'move_scope_reservation_failed')
   return true
  end)
  if committed==true then return id end
  return nil,'busy'
 end,
 transaction=function(body,metrics,context) return RunLegacyStyleTransaction(body,metrics,context) end,
 lock=function(query,id,scope)
  local a,b=inventories(scope);local locks=lockScopes(query,a,b)
  for _,row in ipairs(locks) do if row.operation_id~=id then return false end end
  if receipt(query,id).state~='pending' then return false end
  scope.deliveryHeaders=InventoryMoveOutbox.Headers(query,a,b)
  return true
 end,
 commitReceipt=function(query,id,result,context,scope)
  InventoryMoveOutbox.Append(query,id,result,context,scope)
  local document=json.encode({version=1,result=result})
  assert(#document<=1048576,'move_receipt_too_large')
  local updated=query('UPDATE inventory_move_outcomes SET state=?,result_json=?,completed_at=CURRENT_TIMESTAMP WHERE operation_id=? AND state=?',{'committed',document,id,'pending'})
  assert(tonumber(updated and updated.affectedRows)==1,'move_receipt_write_failed')
  -- Free the move scopes in the same commit as its receipt and item writes.
  query('UPDATE inventory_move_scopes SET operation_id=NULL WHERE operation_id=?',{id})
 end,
 resolve=function(id)
  local read=DB.query('SELECT source_inventory,target_inventory FROM inventory_move_outcomes WHERE operation_id=?',id)
  assert(type(read)=='table' and #read==1,'move_outcome_unavailable')
  local a,b=inventories({sourceInventory=read[1].source_inventory,targetInventory=read[1].target_inventory})
  local outcome
  local committed=DB.transaction(function(tx)
   local query=raw(tx);lockScopes(query,a,b);local row=receipt(query,id)
   if row.state=='pending' then
    query('UPDATE inventory_move_outcomes SET state=?,completed_at=CURRENT_TIMESTAMP WHERE operation_id=? AND state=?',{'rolled_back',id,'pending'})
    outcome='rolled_back'
   elseif row.state=='committed' or row.state=='rolled_back' then
    if row.state=='committed' then
     local ok,document=pcall(json.decode,row.result_json)
     assert(ok and type(document)=='table' and document.version==1 and type(document.result)=='table','move_receipt_invalid')
    end
    outcome=row.state
   else error('move_receipt_invalid') end
   query('UPDATE inventory_move_scopes SET operation_id=NULL WHERE inventory_id IN (?,?) AND operation_id=?',{a,b,id})
   return true
  end)
  assert(committed==true,'move_resolution_unconfirmed')
  return outcome
 end,
 pending=function()
  local rows=DB.query([[SELECT operation_id FROM inventory_move_outcomes
   WHERE refresh_pending=1 AND operation_id>? AND ((state='pending' AND created_at<=DATE_SUB(NOW(),INTERVAL 30 SECOND))
    OR (state IN ('committed','rolled_back') AND refresh_pending=1))
   ORDER BY operation_id LIMIT 25]],cursor)
  assert(type(rows)=='table','move_recovery_scan_unavailable')
  local ids={};for _,row in ipairs(rows) do
   if not InventoryRestartAudit or not InventoryRestartAudit.Paused(row.operation_id) then ids[#ids+1]=row.operation_id end
  end
  cursor=#ids>0 and ids[#ids] or '';return ids
 end,
 changed=function(id,refresh)
  if refresh then pcall(notify,id) else
   -- The normal controller already refreshes its recipients on known success.
   pcall(DB.exec,'UPDATE inventory_move_outcomes SET refresh_pending=0 WHERE operation_id=? AND state IN (?,?)',id,'committed','rolled_back')
  end
 end,
}
local engine=InventoryMoveRecoveryEngine.New(adapters)
function R.Run(body,metrics,context,scope)
 if not ready then return false,{outcome='not_executed',code='move_recovery_unavailable'} end
 return engine.Run(body,metrics,context,scope)
end
function R.Start()
 DB.exec([[CREATE TABLE IF NOT EXISTS inventory_move_outcomes (
  operation_id CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL PRIMARY KEY,
  source_inventory BIGINT UNSIGNED NOT NULL,target_inventory BIGINT UNSIGNED NOT NULL,
  actor_character_id CHAR(36) NULL,state VARCHAR(16) NOT NULL,result_json LONGTEXT NULL,
  refresh_pending TINYINT NOT NULL DEFAULT 1,created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  KEY pending_moves(refresh_pending,operation_id)
 ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin]])
 DB.exec([[CREATE TABLE IF NOT EXISTS inventory_move_scopes (
  inventory_id BIGINT UNSIGNED NOT NULL PRIMARY KEY,
  operation_id CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NULL,
  KEY active_operation(operation_id)
 ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin]])
 for _,name in ipairs({'inventory_move_outcomes','inventory_move_scopes'}) do
  local rows=DB.query('SELECT ENGINE FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME=?',name)
  assert(rows and rows[1] and rows[1].ENGINE=='InnoDB','Move recovery requires InnoDB tables')
  local indexes=DB.query('SHOW INDEX FROM '..name)
  local primary={}
  for _,index in ipairs(indexes or {}) do if index.Key_name=='PRIMARY' then primary[tonumber(index.Seq_in_index)]=index.Column_name end end
  assert(#primary==1 and primary[1]==(name=='inventory_move_outcomes' and 'operation_id' or 'inventory_id'),'Move recovery primary key is incompatible')
 end
 -- Check the complete runtime column surface before admitting any mutations.
 DB.query('SELECT operation_id,state,source_inventory,target_inventory,actor_character_id,result_json,refresh_pending,created_at FROM inventory_move_outcomes LIMIT 0')
 DB.query('SELECT inventory_id,operation_id FROM inventory_move_scopes LIMIT 0')
 InventoryMoveOutbox.Start()
 InventoryMoveMaintenance.Start()
 ready=true
 CreateThread(function()
  while ready do engine.Sweep();Wait(2000) end
 end)
end
function R.Status() return {ready=ready,automaticMutationRetries=0} end

-- Fully automated diagnostic uses receipt/scope tables only, never item rows.
-- It simulates loss at the caller boundary; the separate provider wire tests
-- establish actual transport-loss classification. No database kill or restart.
local acceptanceBusy=false
if type(RegisterCommand)=='function' then RegisterCommand('InvMoveRecoveryAcceptance',function(source,args)
 if source~=0 or Config.DevMode~=true or not ready or acceptanceBusy or (args and #args>0) then return end
 acceptanceBusy=true
 local ok,result=pcall(function()
  local scope={sourceInventory=9007199254740990,targetInventory=9007199254740991,
   result=function() return {kind='receipt_self_test',itemWrites=0} end}
  assert(#DB.query('SELECT id FROM inventory WHERE id IN (?,?)',scope.sourceInventory,scope.targetInventory)==0,'diagnostic_scope_collision')
  local calls=0
  local test={};for k,v in pairs(adapters) do test[k]=v end
  test.transaction=function(body,metrics,context)
   local executed,committed=adapters.transaction(body,metrics,context)
   assert(executed and committed==true,'self_test_commit_unconfirmed')
   return false,{outcome='unknown'} -- discard acknowledgement after actual commit
  end
  local e=InventoryMoveRecoveryEngine.New(test)
  local executed,committed=e.Run(function(query) calls=calls+1;query('SELECT 1',{});return true end,nil,{},scope)
  assert(executed and committed==true and calls==1,'lost_reply_recovery_failed')
  e=InventoryMoveRecoveryEngine.New(adapters)
  executed,committed=e.Run(function() calls=calls+1;return false end,nil,{},scope)
  assert(executed and committed==false and calls==2,'rollback_recovery_failed')
  local id=assert(adapters.reserve(scope,{}))
  assert(adapters.resolve(id)=='rolled_back','abandoned_reservation_not_fenced')
  local entered=false
  adapters.transaction(function(query)
   if not adapters.lock(query,id,scope) then return false end
   entered=true;return true
  end,nil,{})
  assert(not entered,'late_original_not_fenced')
  test={};for k,v in pairs(adapters) do test[k]=v end
  local unknownId
  test.reserve=function(s,c) unknownId=adapters.reserve(s,c);return unknownId end
  test.resolve=function() error('simulated_resolution_unavailable') end
  e=InventoryMoveRecoveryEngine.New(test)
  test.transaction=function(body,m,c)
   local x,y=adapters.transaction(body,m,c);assert(x and y==true);return false,{outcome='unknown'}
  end
  executed,committed=e.Run(function() calls=calls+1;return true end,nil,{},scope)
  assert(executed==false and committed.outcome=='unknown' and calls==3,'unknown_outcome_not_retained')
  local sweep={};for k,v in pairs(adapters) do sweep[k]=v end
  sweep.pending=function() return {unknownId} end
  assert(InventoryMoveRecoveryEngine.New(sweep).Sweep(),'background_recovery_failed')
  assert(adapters.resolve(unknownId)=='committed' and calls==3,'background_replayed_mutation')
  return {phase='passed',checks=4,automaticMutationRetries=0,itemWrites=0,
   lostCallerReply=true,rollback=true,lateOriginalFenced=true,backgroundRecovered=true}
 end)
 acceptanceBusy=false
 print('[InvMoveRecoveryAcceptance] '..json.encode(ok and result or {phase='failed',automaticMutationRetries=0,itemWrites=0,reason='inspect_recovery_receipts_no_blind_repeat'}))
end,true) end
