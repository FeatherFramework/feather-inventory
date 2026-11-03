-- Dedicated restart diagnostics. Only an abandoned diagnostic reservation and
-- redelivery of an ALREADY recorded projection; no gameplay item mutation.
InventoryRestartAudit={}
local A=InventoryRestartAudit
local resource=GetCurrentResourceName()
local path='native-restart-probe.json'
local tokenName='feather_restart_process_token'
local token=GetConvar(tokenName,'')
if token=='' then token=('%s:%s:%s'):format(os.time(),GetGameTimer(),math.random(1,2147483647));SetConvar(tokenName,token) end
local raw=LoadResourceFile(resource,path)
local journal,corrupt
if raw and raw~='' then local ok,v=pcall(json.decode,raw);journal=ok and v or nil
 corrupt=not ok or type(journal)~='table' or journal.version~=1
  or type(journal.probeId)~='string' or #journal.probeId~=36
  or type(journal.deliveryId)~='string' or #journal.deliveryId~=36
  or type(journal.history)~='table' or type(journal.payload)~='string'
  or (journal.mode~='server' and journal.mode~='database')
  or (journal.phase~='prepared' and journal.phase~='verified')
  or type(journal.hostToken)~='string' or type(journal.databaseUptime)~='number'
  or type(journal.released)~='boolean' or type(journal.offlineObserved)~='boolean'
end
local function save()
 local value=json.encode(journal);local ok=SaveResourceFile(resource,path,value,#value)
 return (ok==true or ok==1) and LoadResourceFile(resource,path)==value
end
local function uptime()
 local rows=DB.query("SHOW GLOBAL STATUS LIKE 'Uptime'")
 local n=rows and rows[1] and tonumber(rows[1].Value or rows[1].value)
 assert(n and n>=0,'database_uptime_unavailable');return n
end
local function poll()
 if corrupt or not journal or journal.phase=='verified' or journal.released then return end
 if journal.mode=='server' then
  if journal.hostToken~=token then journal.released=true
   if not save() then journal.released=false end
  end
 else
  local ok,value=pcall(uptime)
  if not ok then
   if not journal.offlineObserved then journal.offlineObserved=true;if not save() then journal.offlineObserved=false end end
  elseif journal.offlineObserved and value<journal.databaseUptime then
   journal.released=true;journal.databaseUptimeAfter=value
   if not save() then journal.released=false end
  elseif value>=journal.databaseUptime+5 then
   local previous=journal.databaseUptime;journal.databaseUptime=value
   if not save() then journal.databaseUptime=previous end
  end
 end
end
function A.Paused(id)
 return not corrupt and journal and journal.phase~='verified' and not journal.released
  and (id==journal.probeId or id==journal.deliveryId) or false
end
local function allowed(readOnly)
 return GetInvokingResource()=='feather-weapons' and Config.DevMode==true and (readOnly or GetConvarInt('feather_native_restart_suite',0)==1)
end
local function status()
 return {ok=not corrupt,phase=corrupt and 'journal_invalid' or journal and journal.phase or 'idle',
  mode=journal and journal.mode,released=journal and journal.released,offlineObserved=journal and journal.offlineObserved,
  probeId=journal and journal.probeId,deliveryId=journal and journal.deliveryId,hostToken=token}
end
exports('PrepareRestartRecovery',function(mode)
 if not allowed() or (mode~='server' and mode~='database') or corrupt or (journal and journal.phase~='verified') then return {ok=false,reason='restart_probe_not_available'} end
 local ok,result=pcall(function()
  assert(InventoryMoveMaintenance.Health().state=='healthy','healthy_recovery_required')
  local a,b=9007199254740990,9007199254740991
  assert(#DB.query('SELECT id FROM inventory WHERE id IN (?,?)',a,b)==0,'diagnostic_scope_collision')
  local selected
  local rows=DB.query('SELECT operation_id,payload FROM inventory_move_outbox WHERE delivered=1 ORDER BY created_at DESC,operation_id DESC LIMIT 100')
  for _,row in ipairs(rows or {}) do
   local doc=json.decode(row.payload)
   for _,move in ipairs(doc.moves or {}) do
    if move.instanceId==229 and move.serialNumber=='FW-LASS-6AE6BCBA-26771B-0001' then selected=row;break end
   end
   if selected then break end
  end
  assert(selected,'accepted_lasso_delivery_required')
  local audit=exports['feather-weapons']:AuditInventoryMoveDelivery(selected.operation_id,selected.payload)
  assert(audit and audit.ok and audit.events==1,'prior_delivery_audit_required')
  local previous=journal and journal.history or {}
  journal={version=1,phase='prepared',mode=mode,hostToken=token,databaseUptime=uptime(),
   probeId=DB.value('SELECT UUID()'),deliveryId=selected.operation_id,payload=selected.payload,eventIds=audit.eventIds,
   released=false,offlineObserved=false,history=previous}
  assert(save(),'probe_journal_not_durable') -- evidence/pauses before ANY probe SQL
  local committed=DB.transaction(function(tx)
   tx.raw('INSERT INTO inventory_move_scopes (inventory_id) VALUES (?),(?) ON DUPLICATE KEY UPDATE inventory_id=inventory_move_scopes.inventory_id',a,b)
   local scopes=tx.raw('SELECT inventory_id,operation_id FROM inventory_move_scopes WHERE inventory_id IN (?,?) ORDER BY inventory_id FOR UPDATE',a,b)
   assert(scopes and #scopes==2,'probe_scopes_unavailable')
   for _,scope in ipairs(scopes) do assert(not scope.operation_id,'probe_scope_busy') end
   tx.raw([[INSERT INTO inventory_move_outcomes (operation_id,source_inventory,target_inventory,state,created_at)
    VALUES (?,?,?,'pending',DATE_SUB(NOW(),INTERVAL 31 SECOND))]],journal.probeId,a,b)
   local write=tx.raw('UPDATE inventory_move_scopes SET operation_id=? WHERE inventory_id IN (?,?) AND operation_id IS NULL',journal.probeId,a,b)
   assert(write and tonumber(write.affectedRows)==2,'probe_fence_failed')
   local delivery=tx.raw('SELECT payload,delivered FROM inventory_move_outbox WHERE operation_id=? FOR UPDATE',journal.deliveryId)
   assert(delivery and #delivery==1 and delivery[1].payload==journal.payload and tonumber(delivery[1].delivered)==1,'prior_delivery_changed')
   tx.raw('UPDATE inventory_move_outbox SET delivered=0,delivered_at=NULL WHERE operation_id=? AND delivered=1',journal.deliveryId)
   return true
  end)
  assert(committed==true,'probe_prepare_unconfirmed_no_retry')
  return status()
 end)
 return ok and result or {ok=false,reason='restart_probe_prepare_unconfirmed_no_retry'}
end)
exports('ReadRestartRecovery',function(verify)
 if not allowed(verify~=true) then return {ok=false,reason='restart_probe_disabled'} end
 local ok,result=pcall(function()
  poll()
  if not verify then return status() end
  assert(not corrupt and journal and journal.released,'restart_boundary_not_observed')
  local rows=DB.query('SELECT state,refresh_pending FROM inventory_move_outcomes WHERE operation_id=?',journal.probeId)
  assert(rows and #rows==1 and rows[1].state=='rolled_back' and tonumber(rows[1].refresh_pending)==0,'probe_recovery_pending')
  assert(#DB.query('SELECT inventory_id FROM inventory_move_scopes WHERE operation_id=?',journal.probeId)==0,'probe_scope_not_released')
  local delivery=DB.query('SELECT payload,delivered FROM inventory_move_outbox WHERE operation_id=?',journal.deliveryId)
  assert(delivery and #delivery==1 and delivery[1].payload==journal.payload and tonumber(delivery[1].delivered)==1,'delivery_recovery_pending')
  local audit=exports['feather-weapons']:AuditInventoryMoveDelivery(journal.deliveryId,journal.payload)
  assert(audit and audit.ok and audit.events==1,'delivery_audit_failed')
  assert(#audit.eventIds==#journal.eventIds,'delivery_event_count_changed')
  for i,id in ipairs(audit.eventIds) do assert(tonumber(id)==tonumber(journal.eventIds[i]),'delivery_event_identity_changed') end
  assert(InventoryMoveMaintenance.Health().state=='healthy','recovery_not_settled')
  if journal.phase~='verified' then
   journal.history[#journal.history+1]={mode=journal.mode,probeId=journal.probeId,deliveryId=journal.deliveryId,eventIds=journal.eventIds}
   journal.phase='verified';assert(save(),'probe_verification_not_durable')
  end
  return {ok=true,mode=journal.mode,phase='verified',reservationRolledBack=true,deliveryConserved=true,gameplayWrites=0,hostToken=token}
 end)
 return ok and result or {ok=false,reason='restart_boundary_or_recovery_not_ready'}
end)
CreateThread(function() while true do Wait(1000);pcall(poll) end end)
