-- One bounded console-only fixture probe. No grants, bypasses or SQL delay hooks.
if Config.DevMode then
 local used={}
 local function run(source,args,kind)
  local flag=kind=='ack_loss' and 'feather_native_move_ack_probe' or 'feather_native_move_contention_probe'
  if source~=0 or Config.DevMode~=true or Config.CharacterAmmunitionEnabled~=true
   or GetResourceState('feather-weapons')~='started' or not GuardsAPI.HasRegisteredGuard('feather-weapons')
   or GetConvarInt(flag,0)~=1 then return end
  SetConvar(flag,'0')
  local label=kind=='ack_loss' and 'InvNativeMoveAckLossProbe' or 'InvNativeMoveContentionProbe'
  local function report(v) print('['..label..'] '..json.encode(v)) end
  local actor,target,revision=tonumber(args and args[1]),tonumber(args and args[2]),tonumber(args and args[3])
  if used[kind] or not args or #args~=3 or not actor or actor<1 or actor%1~=0
   or not target or target<1 or target%1~=0 or not revision or revision<0 or revision%1~=0 then
   return report({phase='refused',reason='unused_probe_current_source_stash_expected_revision_required'})
  end
  local session=InventoryIdentity.GetSession(actor)
  local cid='6a2fd060-c46f-11f1-9ae2-e0d55eaa2deb'
  if not session or not session.ok or session.value.characterId~=cid then return report({phase='refused',reason='jane_session_required'}) end
  local sid=session.value.sessionId
  local own=tonumber(InventoryControllers.GetInventoryByCharacter(cid))
  if not own or own==target then return report({phase='refused',reason='distinct_existing_stash_required'}) end
  local function current()
   local now=InventoryIdentity.GetSession(actor)
   return Config.DevMode==true and Config.CharacterAmmunitionEnabled==true
    and GetResourceState('feather-weapons')=='started' and GuardsAPI.HasRegisteredGuard('feather-weapons')
    and now and now.ok and now.value.characterId==cid and now.value.sessionId==sid
  end
  local context={actorSource=actor,actorCharacterId=cid,sessionId=sid,
   resource='feather-inventory',reason='native_move_'..kind..'_probe'}
  local access=InventoryAPI.CanAccessInventory(actor,target,InventoryAPI.AccessModes.INSERT,context)
  if not Result.IsOk(access) then return report({phase='refused',reason='open_authorized_stash_required'}) end
  local function capture()
   return DB.query('SELECT id,inventory_id,item_id,slot_index,row_revision,metadata FROM inventory_items WHERE inventory_id IN (?,?) ORDER BY id',own,target)
  end
  local function metadata(v) return type(v)=='table' and v or json.decode(v) end
  local function equal(a,b)
   if type(a)=='table' and a.id and type(b)=='table' and b.id then
    return tonumber(a.id)==tonumber(b.id) and tonumber(a.inventory_id)==tonumber(b.inventory_id)
     and tonumber(a.item_id)==tonumber(b.item_id) and tonumber(a.slot_index)==tonumber(b.slot_index)
     and tonumber(a.row_revision)==tonumber(b.row_revision)
     and InventoryMetadata.DocumentsEqual(metadata(a.metadata),metadata(b.metadata))
   end
   return InventoryMetadata.DocumentsEqual(metadata(a),metadata(b))
  end
  local before=capture();local fixture
  for _,r in ipairs(before or {}) do if tonumber(r.id)==229 then fixture=r end end
  local m=fixture and metadata(fixture.metadata)
  if not current() or not fixture or tonumber(fixture.inventory_id)~=own
   or tonumber(fixture.row_revision)~=revision or type(m)~='table'
   or m.weaponDefinitionId~='utility_lasso' or m.serialNumber~='FW-LASS-6AE6BCBA-26771B-0001'
   or not m.provenance or m.provenance.reference~='native-jane-ownership-lasso-alpha-v1' then
   return report({phase='refused',reason='exact_owned_fixture_revision_required'})
  end
  used[kind]=true -- never re-arm an uncertain or completed run in this resource lifetime
  local executor=kind=='ack_loss' and NativeMoveContentionProbe.RunAckLoss or NativeMoveContentionProbe.Run
  local ok,value=pcall(executor,{
   spawn=CreateThread,wait=function() Wait(0) end,now=GetGameTimer,current=current,
   capture=capture,equal=equal,
   move=function() return InventoryControllers.MoveInventoryItems(own,target,{229},context) end
  },before,229,own,target)
  report(ok and value or {phase='failed',reason='probe_exception_inspect_before_retry'})
 end
 RegisterCommand('InvNativeMoveContentionProbe',function(source,args) run(source,args,'contention') end,true)
 RegisterCommand('InvNativeMoveAckLossProbe',function(source,args) run(source,args,'ack_loss') end,true)
end
