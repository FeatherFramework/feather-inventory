-- Diagnostic orchestration only. All mutations use the normal move controller.
NativeMoveContentionProbe={}
-- Confirmed-provider-result/lost-caller-ack simulation only. No claim of a DB
-- connection fault: deliberately discard success and require external readback.
function NativeMoveContentionProbe.RunAckLoss(api,before,itemId,sourceInventory,targetInventory)
 if not api.current() then return {phase='refused',reason='session_changed'} end
 local called,result=pcall(api.move)
 if not called or type(result)~='table' or result.error==true then
  return {phase='failed',reason='move_unconfirmed_inspect_do_not_retry'}
 end
 result=nil -- the diagnostic caller must not treat the returned success as its acknowledgement
 return {phase='awaiting_independent_readback',itemId=itemId,
  sourceInventoryId=sourceInventory,targetInventoryId=targetInventory,
  providerCommitConfirmed=true,simulatedCallerAcknowledgementLost=true,
  automaticRetries=0}
end
function NativeMoveContentionProbe.Run(api,before,itemId,sourceInventory,targetInventory)
 local started,finished,go=0,0,false
 local active,overlap=0,false
 local results={}
 for index=1,2 do
  local n=index
  api.spawn(function()
   while not go do api.wait() end
   local entered=false
   local called,value=pcall(function()
    if not api.current() then return {error=true,code='session_changed'} end
    started=started+1;active=active+1;entered=true
    if active==2 then overlap=true end
    return api.move()
   end)
   if entered then active=active-1 end
   results[n]={ok=called and type(value)=='table' and value.error~=true,
    code=called and type(value)=='table' and (value.code or (value.error and 'unclassified_refusal' or 'committed')) or 'exception'}
   finished=finished+1
  end)
 end
 go=true
 local began=api.now()
 while finished<2 and (api.now()-began)%4294967296<15000 do api.wait() end
 if finished~=2 then return {phase='failed',reason='outstanding_moves_do_not_retry_or_restart',completed=finished} end
 local successes,staleRefused=0,false
 for _,r in ipairs(results) do
  if r.ok then successes=successes+1
  elseif r.code=='not_found' or r.code=='conflict' then staleRefused=true end
 end
 local after=api.capture()
 if type(after)~='table' or not api.current() then return {phase='failed',reason='final_read_or_session_unavailable',results=results} end
 local old,new={},{}
 for _,row in ipairs(before) do
  local id=tonumber(row.id);if not id or old[id] then return {phase='failed',reason='invalid_baseline'} end
  old[id]=row
 end
 for _,row in ipairs(after) do
  local id=tonumber(row.id);if not id or new[id] or not old[id] then return {phase='failed',reason='item_set_changed'} end
  new[id]=row
 end
 local conserved=true
 for id,row in pairs(old) do
  local got=new[id]
  if id==itemId then
   conserved=conserved and got~=nil and tonumber(row.inventory_id)==sourceInventory
    and tonumber(got.inventory_id)==targetInventory
    and tonumber(got.row_revision)==tonumber(row.row_revision)+1
    and tonumber(got.item_id)==tonumber(row.item_id)
    and api.equal(got.metadata,row.metadata)
  else conserved=conserved and got~=nil and api.equal(got,row) end
 end
 if successes~=1 or not staleRefused or not conserved then return {phase='failed',reason='conservation_or_single_commit_failed',results=results} end
 return {phase=overlap and 'passed' or 'inconclusive',reason=overlap and 'single_move_conserved' or 'calls_did_not_overlap_do_not_repeat',
  itemId=itemId,inventoryId=targetInventory,revision=tonumber(new[itemId].row_revision),
  overlappingMoveCalls=overlap,results=results}
end
