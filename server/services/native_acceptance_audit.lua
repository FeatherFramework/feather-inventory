-- Read-only opt-in acceptance evidence. No SQL retries, writes, holds or fixture repair.
exports('ReadNativeAcceptanceAudit',function(actors)
 local guid=type(actors)=='table' and #actors==1 and GetConvarInt('feather_native_guid_suite',0)==1
 local legacy=Config.DevMode==true and (GetConvarInt('feather_native_acceptance_suite',0)==1
  or GetConvarInt('feather_native_restart_suite',0)==1) and type(actors)=='table' and #actors==2
 if GetInvokingResource()~='feather-weapons' or Config.CharacterAmmunitionEnabled~=true or not (guid or legacy) then
  return {ok=false,reason='acceptance_audit_disabled'}
 end
 for k,a in pairs(actors) do
  if type(k)~='number' or k%1~=0 or k<1 or k>#actors or type(a)~='table'
   or type(a.source)~='number' or a.source<1 or a.source%1~=0
   or type(a.characterId)~='string' or #a.characterId<1 or #a.characterId>128
   or type(a.sessionId)~='string' or #a.sessionId<1 or #a.sessionId>128 then return {ok=false,reason='acceptance_actor_invalid'} end
 end
 if not GuardsAPI.HasRegisteredGuard('feather-weapons') then return {ok=false,reason='native_guard_required'} end
 local expected={'6a2fd060-c46f-11f1-9ae2-e0d55eaa2deb','4560a489-ca6c-11f1-9ad4-e0d55eaa2deb'}
 local function current()
  for i,a in ipairs(actors) do
   local s=InventoryIdentity.GetSession(a.source)
   if (not guid and a.characterId~=expected[i]) or not s or not s.ok or s.value.characterId~=a.characterId
    or s.value.sessionId~=a.sessionId then return false end
  end
  return true
 end
 if not current() then return {ok=false,reason='acceptance_session_changed'} end
 local raw=LoadResourceFile(GetCurrentResourceName(),'native-recovery-batch.json')
 if raw and raw~='' then
  local ok,j=pcall(json.decode,raw)
  if not ok or type(j)~='table' or j.version~=1 or j.phase~='cleared' then return {ok=false,reason='recovery_audit_pending'} end
 end
 local result={}
 for i,a in ipairs(actors) do
  local headers=DB.query('SELECT id FROM inventory WHERE character_id=? ORDER BY id',a.characterId)
  if type(headers)~='table' or #headers~=1 then return {ok=false,reason='single_inventory_required'} end
  local items=DB.query('SELECT id,inventory_id,item_id,slot_index,row_revision,metadata FROM inventory_items WHERE inventory_id=? ORDER BY id',headers[1].id)
  local ammo=DB.query('SELECT revision,pools FROM feather_character_ammunition WHERE character_id=?',a.characterId)
  local equipment=DB.query('SELECT slot,inventory_items_id FROM character_equipment WHERE character_id=? ORDER BY slot',a.characterId)
  if type(items)~='table' or type(ammo)~='table' or #ammo~=1 or type(equipment)~='table' then
   return {ok=false,reason='acceptance_read_unavailable'}
  end
  for _,row in ipairs(items) do
   -- Ordinary inventory rows may have SQL NULL or empty metadata. Preserve
   -- that representation in evidence; never rewrite it to a weapon document.
   if row.metadata==nil then row.metadataState='sql_null'
   elseif row.metadata=='' then row.metadataState='empty'
   else
    local ok,document=pcall(function() return type(row.metadata)=='table' and row.metadata or json.decode(row.metadata) end)
    if not ok or type(document)~='table' then return {ok=false,reason='acceptance_metadata_invalid'} end
    row.metadata=document;row.metadataState='document'
   end
  end
  ammo[1].pools=type(ammo[1].pools)=='table' and ammo[1].pools or json.decode(ammo[1].pools)
  local guards={}
  for _,row in ipairs(equipment) do
   if type(row.slot)=='string' and row.slot:match('^weapon') and row.inventory_items_id then
    local id=tonumber(row.inventory_items_id)
    local allowed=GuardsAPI.CanMoveInstance(id,{actorSource=a.source,actorCharacterId=a.characterId,
     sessionId=a.sessionId,resource='feather-inventory',operation='acceptance_guard_read'})
    if allowed~=false then return {ok=false,reason='equipped_native_move_not_blocked'} end
    guards[#guards+1]={id=id,moveBlocked=true}
   end
  end
  result[i]={inventoryId=headers[1].id,items=items,ammo=ammo,equipment=equipment,guards=guards}
 end
 if not current() then return {ok=false,reason='acceptance_session_changed'} end
 return {ok=true,value=result}
end)
