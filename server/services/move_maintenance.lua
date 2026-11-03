-- Retain deduplication evidence in Weapons. This service only prunes settled
-- Inventory delivery/outcome payloads, never gameplay items or provenance.
InventoryMoveMaintenance={}
local M=InventoryMoveMaintenance
local ready,busy=false,false
local lastCleanup={phase='not_run',removed=0}
local function queryFor(tx)
 return function(sql,p) return tx.raw(sql,table.unpack(p or {},1,CountPlaceholders(sql))) end
end
function M.PruneLocked(query,candidate)
 local a,b=tonumber(candidate.source_inventory),tonumber(candidate.target_inventory)
 assert(a and b,'invalid_retention_scope');if a>b then a,b=b,a end
 -- Same scope -> outcome -> outbox lock order as original mutations.
 local scopes=query('SELECT inventory_id,operation_id FROM inventory_move_scopes WHERE inventory_id IN (?,?) ORDER BY inventory_id FOR UPDATE',{a,b})
 assert(type(scopes)=='table','retention_scope_unavailable')
 for _,scope in ipairs(scopes) do if scope.operation_id then return false end end
 local rows=query([[SELECT operation_id,state,refresh_pending,
  (completed_at<=DATE_SUB(NOW(),INTERVAL 30 DAY)) AS expired
  FROM inventory_move_outcomes WHERE operation_id=? FOR UPDATE]],{candidate.operation_id})
 if not rows or #rows~=1 then return false end
 local row=rows[1]
 if tonumber(row.expired)~=1 or tonumber(row.refresh_pending)~=0 then return false end
 local deliveries=query('SELECT delivered,(delivered_at<=DATE_SUB(NOW(),INTERVAL 30 DAY)) AS expired FROM inventory_move_outbox WHERE operation_id=? FOR UPDATE',{candidate.operation_id})
 assert(type(deliveries)=='table','retention_delivery_unavailable')
 if row.state=='committed' then
  if #deliveries~=1 or tonumber(deliveries[1].delivered)~=1 or tonumber(deliveries[1].expired)~=1 then return false end
 elseif row.state=='rolled_back' then
  if #deliveries~=0 then return false end
 else return false end
 if #deliveries==1 then query('DELETE FROM inventory_move_outbox WHERE operation_id=? AND delivered=1',{candidate.operation_id}) end
 local deleted=query('DELETE FROM inventory_move_outcomes WHERE operation_id=? AND refresh_pending=0',{candidate.operation_id})
 assert(deleted and tonumber(deleted.affectedRows)==1,'retention_delete_unconfirmed')
 return true
end
function M.Cleanup()
 if not ready or busy then return {phase='waiting',removed=0} end
 busy=true
 local ok,result=pcall(function()
  -- Existing terminal rows receive a new grace period on upgrade, never an
  -- immediate deletion based on the operation's original creation time.
  DB.exec([[UPDATE inventory_move_outcomes SET completed_at=CURRENT_TIMESTAMP
   WHERE completed_at IS NULL AND state IN ('committed','rolled_back') LIMIT 100]])
  DB.exec([[UPDATE inventory_move_outbox SET delivered_at=CURRENT_TIMESTAMP
   WHERE delivered=1 AND delivered_at IS NULL LIMIT 100]])
  local candidates=DB.query([[SELECT o.operation_id,o.source_inventory,o.target_inventory FROM inventory_move_outcomes o
   LEFT JOIN inventory_move_outbox d ON d.operation_id=o.operation_id
   WHERE o.state IN ('committed','rolled_back') AND o.refresh_pending=0
    AND o.completed_at<=DATE_SUB(NOW(),INTERVAL 30 DAY)
    AND ((o.state='committed' AND d.delivered=1 AND d.delivered_at<=DATE_SUB(NOW(),INTERVAL 30 DAY))
      OR (o.state='rolled_back' AND d.operation_id IS NULL))
    AND NOT EXISTS (SELECT 1 FROM inventory_move_scopes s
     WHERE s.inventory_id IN (o.source_inventory,o.target_inventory) AND s.operation_id IS NOT NULL)
   ORDER BY o.completed_at,o.operation_id LIMIT 25]])
  local removed=0
  for _,candidate in ipairs(candidates or {}) do
   local deleted=false
   local committed=DB.transaction(function(tx) deleted=M.PruneLocked(queryFor(tx),candidate);return true end)
   assert(committed==true,'retention_transaction_unconfirmed')
   if deleted then removed=removed+1 end
  end
  return {phase='complete',removed=removed,retentionDays=30,batchLimit=25}
 end)
 busy=false
 lastCleanup=ok and result or {phase='waiting_for_database',removed=0,retentionDays=30}
 return lastCleanup
end
function M.Health()
 if not ready then return {state='unavailable',message='Inventory recovery is not ready.'} end
 local ok,result=pcall(function()
  local moves=DB.query([[SELECT COUNT(*) AS pending,COALESCE(MAX(TIMESTAMPDIFF(SECOND,created_at,NOW())),0) AS oldest
   FROM inventory_move_outcomes WHERE state='pending']])[1]
  local deliveries=DB.query([[SELECT COUNT(*) AS pending,COALESCE(MAX(TIMESTAMPDIFF(SECOND,created_at,NOW())),0) AS oldest
   FROM inventory_move_outbox WHERE delivered=0]])[1]
  local refreshes=DB.query([[SELECT COUNT(*) AS pending,COALESCE(MAX(TIMESTAMPDIFF(SECOND,COALESCE(completed_at,created_at),NOW())),0) AS oldest
   FROM inventory_move_outcomes WHERE refresh_pending=1 AND state IN ('committed','rolled_back')]])[1]
  local scopes=DB.query([[SELECT COUNT(*) AS active FROM inventory_move_scopes WHERE operation_id IS NOT NULL]])[1]
  assert(moves and deliveries and refreshes and scopes,'health_read_unavailable')
  local pendingMoves,pendingDeliveries=tonumber(moves.pending),tonumber(deliveries.pending)
  local moveAge,deliveryAge=tonumber(moves.oldest),tonumber(deliveries.oldest)
  local pendingRefreshes,refreshAge=tonumber(refreshes.pending),tonumber(refreshes.oldest)
  assert(pendingRefreshes and refreshAge and pendingMoves and pendingDeliveries and moveAge and deliveryAge and tonumber(scopes.active),'health_read_invalid')
  local state=(pendingMoves+pendingDeliveries+pendingRefreshes==0 and tonumber(scopes.active)==0) and 'healthy' or 'waiting'
  if moveAge>60 or deliveryAge>60 or refreshAge>60 or (tonumber(scopes.active)>0 and pendingMoves==0) or lastCleanup.phase=='waiting_for_database' then state='attention' end
  local messages={healthy='Inventory recovery is healthy. No action is needed.',waiting='Inventory recovery is working. Do not repeat pending transfers.',
   attention='Inventory recovery needs attention. Keep pending transfers unchanged and retain this report for support.'}
  return {state=state,message=messages[state],pendingMoves=pendingMoves,pendingDeliveries=pendingDeliveries,
   pendingRefreshes=pendingRefreshes,oldestRefreshSeconds=refreshAge,oldestMoveSeconds=moveAge,oldestDeliverySeconds=deliveryAge,activeScopes=tonumber(scopes.active),
   retentionDays=30,cleanup=lastCleanup,weaponDeduplicationPolicy='retain',automaticMutationRetries=0}
 end)
 return ok and result or {state='unavailable',message='Database recovery checks are unavailable. Recovery will continue when the database responds; do not repeat pending transfers.'}
end
function M.Start()
 local columns=DB.query('SHOW COLUMNS FROM inventory_move_outcomes LIKE ?', 'completed_at')
 assert(type(columns)=='table','retention_schema_unavailable')
 if #columns==0 then DB.exec('ALTER TABLE inventory_move_outcomes ADD COLUMN completed_at TIMESTAMP NULL DEFAULT NULL') end
 local indexes=DB.query('SHOW INDEX FROM inventory_move_outcomes');local found=false
 for _,index in ipairs(indexes or {}) do if index.Key_name=='completed_cleanup' then found=true end end
 if not found then DB.exec('ALTER TABLE inventory_move_outcomes ADD INDEX completed_cleanup (state,refresh_pending,completed_at)') end
 DB.query('SELECT completed_at FROM inventory_move_outcomes LIMIT 0')
 ready=true
 CreateThread(function()
  local lastState=nil
  while true do
   Wait(60000)
   M.Cleanup()
   local health=M.Health()
   if health.state~=lastState then
    if health.state=='attention' or health.state=='unavailable' or lastState=='attention' or lastState=='unavailable' then
     print('[feather-inventory] '..health.message)
    end
    lastState=health.state
   end
  end
 end)
end
RegisterCommand('InvMoveHealth',function(source,args)
 if source~=0 or (args and #args>0) then return end
 print('[InvMoveHealth] '..json.encode(M.Health()))
end,true)

local acceptanceBusy=false
RegisterCommand('InvMoveMaintenanceAcceptance',function(source,args)
 if source~=0 or Config.DevMode~=true or not ready or acceptanceBusy or (args and #args>0) then return end
 acceptanceBusy=true
 local ok,result=pcall(function()
  local a,b=9007199254740990,9007199254740991
  assert(#DB.query('SELECT id FROM inventory WHERE id IN (?,?)',a,b)==0,'maintenance_fixture_collision')
  local ids={};for index=1,8 do ids[index]=DB.value('SELECT UUID()');assert(type(ids[index])=='string' and #ids[index]==36,'fixture_id_unavailable') end
  local checked=false
  local committed=DB.transaction(function(tx)
   local q=queryFor(tx)
   q('INSERT INTO inventory_move_scopes (inventory_id) VALUES (?),(?) ON DUPLICATE KEY UPDATE inventory_id=inventory_move_scopes.inventory_id',{a,b})
   local function fixture(index,state,refresh,delivered,recent,deliveryRecent)
    q([[INSERT INTO inventory_move_outcomes
     (operation_id,source_inventory,target_inventory,state,refresh_pending,completed_at)
     VALUES (?,?,?,?,?,IF(?=1,NOW(),DATE_SUB(NOW(),INTERVAL 31 DAY)))]],{ids[index],a,b,state,refresh,recent and 1 or 0})
    if delivered~=nil then q('INSERT INTO inventory_move_outbox (operation_id,payload,delivered,delivered_at) VALUES (?,?,?,IF(?=1,NOW(),DATE_SUB(NOW(),INTERVAL 31 DAY)))',{ids[index],'{}',delivered,deliveryRecent and 1 or 0}) end
    return {operation_id=ids[index],source_inventory=a,target_inventory=b}
   end
   assert(M.PruneLocked(q,fixture(1,'committed',0,1,false)),'old_settled_not_pruned')
   assert(M.PruneLocked(q,fixture(2,'rolled_back',0,nil,false)),'old_rollback_not_pruned')
   assert(not M.PruneLocked(q,fixture(3,'pending',0,nil,false)),'pending_operation_pruned')
   assert(not M.PruneLocked(q,fixture(4,'committed',0,1,true)),'recent_operation_pruned')
   assert(not M.PruneLocked(q,fixture(5,'committed',0,0,false)),'pending_delivery_pruned')
   assert(not M.PruneLocked(q,fixture(6,'committed',1,1,false)),'pending_refresh_pruned')
   assert(not M.PruneLocked(q,fixture(8,'committed',0,1,false,true)),'recent_delivery_pruned')
   local active=fixture(7,'committed',0,1,false)
   q('UPDATE inventory_move_scopes SET operation_id=? WHERE inventory_id IN (?,?)',{ids[7],a,b})
   assert(not M.PruneLocked(q,active),'active_scope_pruned')
   checked=true;return false -- all diagnostic inserts/deletes deliberately roll back
  end)
  assert(checked and committed==false,'diagnostic_rollback_unconfirmed')
  for _,id in ipairs(ids) do
   assert(#DB.query('SELECT operation_id FROM inventory_move_outcomes WHERE operation_id=?',id)==0,'diagnostic_outcome_leaked')
   assert(#DB.query('SELECT operation_id FROM inventory_move_outbox WHERE operation_id=?',id)==0,'diagnostic_outbox_leaked')
   assert(#DB.query('SELECT inventory_id FROM inventory_move_scopes WHERE operation_id=?',id)==0,'diagnostic_scope_leaked')
  end
  local health=M.Health();assert(health.state~='unavailable','health_unavailable')
  return {phase='passed',checks=9,retentionDays=30,oldSettledRemoved=true,unresolvedPreserved=true,
   recentPreserved=true,activeScopesPreserved=true,fixtureRollbackConfirmed=true,
   gameplayWrites=0,provenanceWrites=0,health=health.state}
 end)
 acceptanceBusy=false
 print('[InvMoveMaintenanceAcceptance] '..json.encode(ok and result or {phase='review_required',reason='maintenance_check_unconfirmed',gameplayWrites=0,provenanceWrites=0}))
end,true)
