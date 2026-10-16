local root=arg and arg[1] or '.'
Result={Ok=function(v) return {ok=true,value=v} end,Err=function(code,message) return {ok=false,error={code=code,message=message}} end}
dofile(root..'/server/services/native_evidence_commit.lua')
local function copy(v) if type(v)~='table' then return v end; local t={}; for k,x in pairs(v) do t[k]=copy(x) end; return t end
local baseline={id=135,inventoryId=2,revision=13,definition={name='weapon_repeater_carbine'},metadata={
 serialNumber='SERIAL',weaponDefinitionId='repeater_carbine',flags={evidence=false,disabled=false,stolen=true},
 maintenance={dirt=0.2},condition=100,attachments={{slot='sight',definitionId='carbine_wide_sight'}},
 ammo={ownership='character',type='ammo_repeater_regular'},provenance={owner='Jane'}}}
local function reservation(item,held) return {characterId='Jane',itemId=item.id,itemRevision=item.revision,
 serialNumber='SERIAL',weaponDefinitionId='repeater_carbine',itemName='weapon_repeater_carbine',held=held,before=copy(item.metadata)} end
local function run(spec,options)
 options=options or {}; local saved=copy(baseline); local staged=copy(saved)
 if options.item then options.item(staged) end
 local boundaries,writes,queries=0,0,0
 local function current() boundaries=boundaries+1; return boundaries~=options.loseAt end
 local tx={query=function(sql)
  queries=queries+1
  assert(sql:find('FOR UPDATE',1,true),'all ownership/equipment reads lock current state')
  if sql:find('SELECT id FROM inventory',1,true) then return {{id=2}} end
  if options.equipped or options.lateEquip and writes>0 then return {{slot='weapon_shoulder',inventory_items_id=135}} end
  return {}
 end}
 function tx:GetItemForUpdate(id) assert(id==135); return Result.Ok(copy(staged)) end
 function tx:SetMetadata(id,metadata,revision)
  writes=writes+1
  if options.writeRefused then return Result.Err('guard','held') end
  assert(id==135 and revision==staged.revision)
  staged.metadata=copy(metadata); staged.revision=staged.revision+1
  return Result.Ok(true)
 end
 setmetatable(tx,{__index=function(_,key) error('unexpected economic/movement operation '..key) end})
 local callback=setmetatable({__cfx_functionReference='mock'},{__call=function() return current() end})
 local result=NativeEvidenceCommit.Apply(tx,spec,callback)
 if result.ok then saved=staged end -- owning TransactionAPI must roll back Err
 return result,saved,writes,queries
end
local spec=reservation(baseline,true)
local held,item=run(spec)
assert(held.ok and item.revision==14 and item.metadata.flags.evidence and not baseline.metadata.flags.evidence)
assert(item.metadata.serialNumber=='SERIAL' and item.metadata.flags.stolen and item.metadata.maintenance.dirt==0.2
 and item.metadata.attachments[1].definitionId=='carbine_wide_sight' and item.metadata.ammo.type=='ammo_repeater_regular')
baseline=item
local released,back=run(reservation(baseline,false))
assert(released.ok and back.revision==15 and back.metadata.flags.evidence==false)
for _,options in ipairs({{equipped=true},{lateEquip=true},{writeRefused=true},
 {item=function(i) i.inventoryId=9 end},{item=function(i) i.revision=i.revision+1 end},
 {item=function(i) i.metadata.serialNumber='OTHER' end},{item=function(i) i.definition.name='forged' end}}) do
 local result,unchanged=run(reservation(baseline,false),options)
 assert(not result.ok and unchanged.revision==baseline.revision and unchanged.metadata.flags.evidence==true)
end
for boundary=1,6 do
 local result,unchanged=run(reservation(baseline,false),{loseAt=boundary})
 assert(not result.ok and unchanged.revision==baseline.revision,'authority loss must roll back at boundary '..boundary)
end
local duplicate=reservation(baseline,true)
assert(not run(duplicate).ok,'already-applied state cannot replay')
print('Native evidence body PASS (hold/release, CFX current authority, own serial/revision, equipment/guard veto, rollback boundaries, metadata-only; mocked transaction)')
