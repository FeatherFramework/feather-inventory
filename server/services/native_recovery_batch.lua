-- Dedicated test-database fixture only. All probes/verification/cleanup ship together.
local resource=GetCurrentResourceName()
local path='native-recovery-batch.json'
local actor,sessionId
local cid='6a2fd060-c46f-11f1-9ae2-e0d55eaa2deb'
local function copy(v) if type(v)~='table' then return v end;local r={};for k,x in pairs(v) do r[k]=copy(x) end;return r end
local function capture()
 local rows=DB.query([[SELECT ii.id,ii.inventory_id,ii.item_id,ii.slot_index,ii.row_revision,ii.metadata,inv.character_id
  FROM inventory_items ii INNER JOIN inventory inv ON inv.id=ii.inventory_id WHERE ii.id=229]])
 if type(rows)~='table' or #rows~=1 then return nil end
 local r=rows[1];local ok,m=pcall(function() return type(r.metadata)=='table' and r.metadata or json.decode(r.metadata) end)
 if not ok then return nil end
 return {id=tonumber(r.id),inventoryId=tonumber(r.inventory_id),itemId=tonumber(r.item_id),
  slot=tonumber(r.slot_index),revision=tonumber(r.row_revision),characterId=r.character_id,metadata=m}
end
local function current()
 local s=InventoryIdentity.GetSession(actor)
 return Config.DevMode==true and Config.CharacterAmmunitionEnabled==true
  and GetResourceState('feather-weapons')=='started'
  and s and s.ok and s.value.characterId==cid and s.value.sessionId==sessionId
end
local function fixture(row)
 local m=row and row.metadata
 return row and row.id==229 and row.characterId==cid and type(m)=='table'
  and m.weaponDefinitionId=='utility_lasso' and m.serialNumber=='FW-LASS-6AE6BCBA-26771B-0001'
  and m.condition==100 and m.quality==100 and m.flags and m.flags.disabled==false and m.flags.evidence==false
  and m.provenance and m.provenance.reference=='native-jane-ownership-lasso-alpha-v1'
  and GuardsAPI.CanMoveInstance(229,{actorSource=actor,operation='recovery_probe_preflight'})==true
end
local batch=NativeRecoveryBatch.New({
 load=function()
  local raw=LoadResourceFile(resource,path)
  if not raw or raw=='' then return nil end
  local ok,v=pcall(json.decode,raw);return ok and v or false
 end,
 save=function(j)
  local raw=json.encode(j)
  local saved=SaveResourceFile(resource,path,raw,#raw)
  return (saved==true or saved==1) and LoadResourceFile(resource,path)==raw
 end,
 capture=capture,current=current,fixture=fixture,
 equal=function(a,b) return type(a)=='table' and type(b)=='table' and InventoryMetadata.DocumentsEqual(a,b) end,
 connectionGone=function(id)
  local rows=DB.query('SELECT ID FROM information_schema.PROCESSLIST WHERE ID=?',id)
  return type(rows)=='table' and #rows==0
 end,
 execute=function(mode,before,ticket,recordConnection)
  local context={actorSource=actor,actorCharacterId=cid,sessionId=sessionId,
   resource='feather-inventory',reason='native_recovery_batch',runtimeTicket=ticket}
  return TransactionAPI.Transaction(context,function(tx)
   if not current() then return Result.Err('recovery_session_changed') end
   local access=tx:AssertAccess(actor,before.inventoryId,InventoryAPI.AccessModes.REMOVE)
   if not access.ok then return access end
   local item=tx:GetItemForUpdate(229)
   if not item.ok then return item end
   if item.value.revision~=before.revision or item.value.inventoryId~=before.inventoryId
    or not InventoryMetadata.DocumentsEqual(item.value.metadata,before.metadata) then return Result.Err('recovery_fixture_changed') end
   local changed=copy(before.metadata);changed.condition=99
   local write=tx:SetMetadata(229,changed,before.revision)
   if not write.ok then return write end
   if mode=='rollback' then return Result.Err('recovery_probe_rollback','Deliberate fixture rollback.') end
   local rows=tx.query('SELECT CONNECTION_ID() AS connectionId',{})
   local id=rows and rows[1] and tonumber(rows[1].connectionId)
   if not id or id<1 or id%1~=0 then return Result.Err('recovery_connection_id_unavailable') end
   recordConnection(id) -- persisted before targeting this transaction's own connection
   tx.query(('KILL CONNECTION %d'):format(id),{})
   return Result.Err('recovery_disconnect_not_observed')
  end)
 end
})
-- The hold survives resource restart via the journal, even with opt-ins disabled.
for _,method in ipairs({'RegisterMoveGuard','RegisterDestroyGuard','RegisterInstanceChangeGuard'}) do
 local registered=GuardsAPI[method]('feather-native-recovery-batch',batch.Guard)
 assert(registered and registered.ok,'recovery batch hold registration failed')
end
SetConvar('feather_native_recovery_batch','0')
SetConvar('feather_native_recovery_disconnect','0')
local busy=false
RegisterCommand('InvNativeRecoveryBatch',function(source,args)
 if source~=0 then return end
 local function report(value) print('[InvNativeRecoveryBatch] '..json.encode(value)) end
 local action=args and args[1]
 if action=='status' and #args==1 then return report(batch.Status()) end
 if Config.DevMode~=true or busy then return report({phase='refused',reason='development_idle_command_required'}) end
 if action=='notice' and #args==3 then
  local target,kind=tonumber(args[2]),args[3]
  if not target or target<1 or target%1~=0 or (kind~='partial' and kind~='unknown') then
   return report({phase='refused',reason='notice_current_source_partial_or_unknown_required'})
  end
  local s=InventoryIdentity.GetSession(target)
  if not s or not s.ok then return report({phase='refused',reason='current_session_required'}) end
  local result=kind=='partial' and {movedCount=0,skippedCount=1,skipReason='native_recovery_audit_pending'}
   or {code='transaction_outcome_unknown'}
  Feather.Notify.RightNotify(target,TranslateResult(target,result,'err_give_failed'),4000)
  return report({phase='notice_preview',kind=kind,target=target,noWrites=true})
 end
 if (action=='verify' or action=='clear') and #args==1 then
  busy=true;local ok,v=pcall(action=='verify' and batch.Verify or batch.Clear);busy=false
  return report(ok and v or {phase='unresolved',reason='readback_failed_no_retry'})
 end
 if action~='run' or #args~=4 or GetConvarInt('feather_native_recovery_batch',0)~=1 then
  return report({phase='refused',reason='run_current_source_rollback_or_disconnect_expected_revision_required'})
 end
 SetConvar('feather_native_recovery_batch','0')
 local target,mode,expected=tonumber(args[2]),args[3],tonumber(args[4])
 if not target or target<1 or target%1~=0 or not expected or expected<0 or expected%1~=0
  or (mode~='rollback' and mode~='disconnect') then return report({phase='refused',reason='invalid_probe_arguments'}) end
 if mode=='disconnect' then
  if GetConvarInt('feather_native_recovery_disconnect',0)~=1 then return report({phase='refused',reason='dedicated_database_disconnect_optin_required'}) end
  SetConvar('feather_native_recovery_disconnect','0')
 end
 local s=InventoryIdentity.GetSession(target)
 if not s or not s.ok or s.value.characterId~=cid then return report({phase='refused',reason='current_jane_required'}) end
 actor,sessionId=target,s.value.sessionId
 busy=true;local ok,v=pcall(batch.Run,mode,expected);busy=false
 report(ok and v or {phase='unresolved',reason='probe_exception_no_retry'})
end,true)
