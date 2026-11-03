-- Durable built-in projections. Legacy broadcasts remain best-effort and are
-- never replayed here. No networked callbacks, gameplay writes or grants.
InventoryMoveOutbox={}
local O=InventoryMoveOutbox
local cursor=''
function O.Headers(query,a,b)
 local rows=query('SELECT id,character_id FROM inventory WHERE id IN (?,?) ORDER BY id',{a,b})
 assert(type(rows)=='table','move_delivery_headers_unavailable')
 local headers={};for _,row in ipairs(rows) do headers[tostring(row.id)]=row.character_id end
 return headers
end
function O.Build(id,result,context,scope)
 context=context or {};scope=scope or {}
 local headers=scope.deliveryHeaders or {}
 local document={version=1,operationId=id,moves={},occurredAt=os.time(),
  actorCharacterId=context.actorCharacterId,resource=context.resource or 'feather-inventory',
  correlationId=context.correlationId,reason=context.reason or result.reason or 'inventory_move',
  sourceInventory=tonumber(scope.sourceInventory),targetInventory=tonumber(scope.targetInventory),
  deletedContainer=result.deletedContainer,deleteReason=result.deleteReason}
 local function add(itemId,extra,from,to,reason)
  extra=extra or {};from=tonumber(from);to=tonumber(to)
  local metadata=extra.metadata
  if type(metadata)=='string' then local ok,v=pcall(json.decode,metadata);metadata=ok and v or nil end
  document.moves[#document.moves+1]={instanceId=tonumber(itemId),definitionId=tonumber(extra.definitionId),
   revision=tonumber(extra.revision),fromInventoryId=from,toInventoryId=to,fromSlot=extra.fromSlot,toSlot=extra.toSlot,
   fromCharacterId=headers[tostring(from)],toCharacterId=headers[tostring(to)],reason=reason or document.reason,
   weaponDefinitionId=type(metadata)=='table' and metadata.weaponDefinitionId or nil,
   serialNumber=type(metadata)=='table' and metadata.serialNumber or nil}
 end
 if result.kind=='slot_move' or result.kind=='item_move' then
  for _,itemId in ipairs(result.movedIds or {}) do add(itemId,(result.facts or {})[itemId],scope.sourceInventory,scope.targetInventory) end
  for _,itemId in ipairs(result.swappedIds or {}) do add(itemId,(result.swapFacts or {})[itemId],scope.targetInventory,scope.sourceInventory,'slot_swap') end
 elseif result.kind=='slot_split' then
  for _,fact in ipairs(result.facts or {}) do add(fact.instanceId,fact,scope.sourceInventory,scope.targetInventory) end
 end
 return document
end
function O.Append(query,id,result,context,scope)
 local document=json.encode(O.Build(id,result,context,scope))
 assert(#document<=1048576,'move_delivery_too_large')
 local inserted=query('INSERT INTO inventory_move_outbox (operation_id,payload) VALUES (?,?)',{id,document})
 assert(tonumber(inserted and inserted.affectedRows)==1,'move_delivery_append_failed')
end
local function deliver(row)
 local document=json.decode(row.payload)
 assert(type(document)=='table' and document.version==1 and document.operationId==row.operation_id and type(document.moves)=='table','invalid_move_delivery')
 local weapon=false
 for _,fact in ipairs(document.moves) do
  if (fact.weaponDefinitionId or fact.serialNumber) and fact.fromInventoryId~=fact.toInventoryId then weapon=true end
 end
 if weapon then
  -- Returning only after a durable, deduplicated consumer commit is essential:
  -- TriggerEvent cannot provide an acknowledgement of asynchronous side effects.
  if GetResourceState('feather-weapons')~='started' then return false end
  local result=exports['feather-weapons']:ApplyInventoryMoveDelivery(row.operation_id,row.payload)
  if type(result)~='table' or result.ok~=true then return false end
 end
 -- Safe to repeat if acknowledgement is lost. Resolve recipients from CURRENT
 -- character sessions, never reuse the source number captured before restart.
 local recipients={}
 for _,fact in ipairs(document.moves) do
  if fact.fromCharacterId then recipients[fact.fromCharacterId]=true end
  if fact.toCharacterId then recipients[fact.toCharacterId]=true end
 end
 if document.actorCharacterId then recipients[document.actorCharacterId]=true end
 for _,rawSource in ipairs(GetPlayers()) do
  local source=tonumber(rawSource);local session=InventoryIdentity.GetSession(source)
  if session and session.ok and recipients[session.value.characterId] then
   TriggerClientEvent('Feather:Inventory:RefreshInventory',source)
   TriggerClientEvent('Feather:Inventory:HotbarRefresh',source)
  end
 end
 DB.exec('UPDATE inventory_move_outbox SET delivered=1,delivered_at=COALESCE(delivered_at,CURRENT_TIMESTAMP) WHERE operation_id=? AND delivered=0',row.operation_id)
 return true
end
function O.Sweep()
 local rows=DB.query('SELECT operation_id,payload FROM inventory_move_outbox WHERE delivered=0 AND operation_id>? ORDER BY operation_id LIMIT 25',cursor)
 assert(type(rows)=='table','move_delivery_scan_unavailable')
 for _,row in ipairs(rows) do
  if not InventoryRestartAudit or not InventoryRestartAudit.Paused(row.operation_id) then pcall(deliver,row) end
 end
 cursor=#rows>0 and rows[#rows].operation_id or ''
end
function O.Start()
 DB.exec([[CREATE TABLE IF NOT EXISTS inventory_move_outbox (
  operation_id CHAR(36) CHARACTER SET ascii COLLATE ascii_bin NOT NULL PRIMARY KEY,
  payload LONGTEXT NOT NULL,delivered TINYINT NOT NULL DEFAULT 0,delivered_at TIMESTAMP NULL DEFAULT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
  KEY pending_delivery(delivered,operation_id)
 ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_bin]])
 local columns=DB.query('SHOW COLUMNS FROM inventory_move_outbox LIKE ?', 'delivered_at')
 assert(type(columns)=='table','delivery_timestamp_schema_unavailable')
 if #columns==0 then DB.exec('ALTER TABLE inventory_move_outbox ADD COLUMN delivered_at TIMESTAMP NULL DEFAULT NULL') end
 local rows=DB.query('SELECT ENGINE FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME=?','inventory_move_outbox')
 assert(rows and rows[1] and rows[1].ENGINE=='InnoDB','Move outbox requires InnoDB')
 DB.query('SELECT operation_id,payload,delivered,created_at FROM inventory_move_outbox LIMIT 0')
 local indexes=DB.query('SHOW INDEX FROM inventory_move_outbox');local primary={}
 for _,index in ipairs(indexes or {}) do if index.Key_name=='PRIMARY' then primary[tonumber(index.Seq_in_index)]=index.Column_name end end
 assert(#primary==1 and primary[1]=='operation_id','Move outbox primary key incompatible')
 CreateThread(function() while true do pcall(O.Sweep);Wait(2000) end end)
end

-- Console acceptance reads the existing developer fixture's two real moves;
-- redelivers only already-acknowledged projections, never moves the fixture.
local acceptanceBusy=false
RegisterCommand('InvMoveDeliveryAcceptance',function(source,args)
 if source~=0 or Config.DevMode~=true or acceptanceBusy or (args and #args>0) then return end
 acceptanceBusy=true
 local ok,result=pcall(function()
  local rows=DB.query('SELECT operation_id,payload,delivered FROM inventory_move_outbox ORDER BY created_at DESC,operation_id DESC LIMIT 100')
  local deposit,pickup
  for _,row in ipairs(rows or {}) do
   local doc=json.decode(row.payload)
   for _,move in ipairs(doc.moves or {}) do
    if move.instanceId==229 and move.serialNumber=='FW-LASS-6AE6BCBA-26771B-0001' then
     if move.fromInventoryId==2 and move.toInventoryId==15 and not deposit then deposit={row=row,move=move} end
     if move.fromInventoryId==15 and move.toInventoryId==2 and not pickup then pickup={row=row,move=move} end
    end
   end
  end
  assert(deposit and pickup,'complete_the_single_lasso_roundtrip_first')
  assert(tonumber(deposit.row.delivered)==1 and tonumber(pickup.row.delivered)==1,'wait_for_background_delivery')
  assert(pickup.move.revision==deposit.move.revision+1,'fixture_roundtrip_revision_mismatch')
  local function same(a,b)
   if type(a)~='table' or type(b)~='table' or #a~=#b then return false end
   for i,id in ipairs(a) do if tonumber(id)~=tonumber(b[i]) then return false end end;return true
  end
  local total=0
  for _,fixture in ipairs({deposit,pickup}) do
   local row=fixture.row
   local before=exports['feather-weapons']:AuditInventoryMoveDelivery(row.operation_id,row.payload)
   assert(before and before.ok,'delivery_audit_before_failed')
   for attempt=1,2 do
    local reply=exports['feather-weapons']:ApplyInventoryMoveDelivery(row.operation_id,row.payload)
    assert(reply and reply.ok and reply.replayed==true and same(before.eventIds,reply.eventIds),'delivery_redelivery_mismatch')
   end
   local after=exports['feather-weapons']:AuditInventoryMoveDelivery(row.operation_id,row.payload)
   assert(after and after.ok and same(before.eventIds,after.eventIds),'delivery_audit_after_failed')
   total=total+after.events
  end
  return {phase='passed',checks=4,fixtureItemId=229,roundtrip=true,duplicateDeliveryConserved=true,
   durableSnapshots=true,provenanceEvents=total,newProvenanceEvents=0,itemWrites=0,automaticMutationRetries=0}
 end)
 acceptanceBusy=false
 local report=result
 if not ok then
  local reason='move_delivery_check_unavailable'
  for _,code in ipairs({'complete_the_single_lasso_roundtrip_first','wait_for_background_delivery','fixture_roundtrip_revision_mismatch','delivery_audit_before_failed','delivery_redelivery_mismatch','delivery_audit_after_failed'}) do
   if tostring(result):find(code,1,true) then reason=code;break end
  end
  report={phase=(reason=='complete_the_single_lasso_roundtrip_first' or reason=='wait_for_background_delivery') and 'waiting' or 'review_required',itemWrites=0,automaticMutationRetries=0,reason=reason}
 end
 print('[InvMoveDeliveryAcceptance] '..json.encode(report))
end,true)
