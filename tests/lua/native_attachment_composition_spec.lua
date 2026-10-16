-- Real export + all three transaction bodies. Only DB/transport are mocked.
Result={Ok=function(v) return {ok=true,value=v} end,Err=function(c,m) return {ok=false,error={code=c,message=m}} end}
Config={DevMode=true,CharacterAmmunitionEnabled=true}
local function copy(v) if type(v)~='table' then return v end; local out={}; for k,x in pairs(v) do out[k]=copy(x) end; return out end
local registered,db,mode,spec={},nil,nil,nil
local writes,payments=0,0
GetInvokingResource=function() return 'feather-weapons' end
GetResourceState=function() return 'started' end
GetConvarInt=function() return 1 end
exports=setmetatable({['feather-core']={IsSessionCurrent=function() return true end},
 ['feather-weapons']={ValidateNativeEquipmentCommit=function(_,context,reserved)
  assert(context.ticket=='ticket' and reserved.itemRevision==8,'authority must retain original revision')
  return not (mode=='authority' and payments>0)
 end}},{__call=function(_,name,fn) registered[name]=fn end})
local tx={query=function(sql)
 if sql:find('FROM inventory WHERE',1,true) then return {{id=2}} end
 if sql:find('FROM character_equipment',1,true) then
  return {{slot='weapon_shoulder',inventory_items_id=135,row_revision=db.revision,owner_character='Jane'}}
 end
 if sql:find('FROM items WHERE',1,true) then return {{id=9,name='carbine_wide_sight'}} end
 error('unexpected query '..sql)
end}
function tx:GetItemForUpdate(id)
 assert(id==135)
 return Result.Ok({inventoryId=2,revision=db.revision,metadata=copy(db.metadata),definition={name='weapon_repeater_carbine'}})
end
function tx:SetMetadata(id,metadata,revision)
 assert(id==135 and revision==db.revision)
 writes=writes+1
 if mode=='cas' and writes==2 then return Result.Err('conflict','attachment CAS refused') end
 db.metadata=copy(metadata)
 -- Match the observed native-float JSON precision loss on the actual DB boundary.
 db.metadata.maintenance.dirt=tonumber(string.format('%.14g',db.metadata.maintenance.dirt))
 db.revision=db.revision+1
 return Result.Ok(true)
end
function tx:RemoveQuantity(inv,id,count)
 assert(inv==2 and id==9 and count==1)
 if mode=='payment' then return Result.Err('insufficient','payment refused') end
 db.quantity=db.quantity-1; payments=payments+1; return Result.Ok(true)
end
function tx:AddQuantity(inv,id,count)
 assert(inv==2 and id==9 and count==1)
 if mode=='capacity' then return Result.Err('capacity','return cannot fit') end
 db.quantity=db.quantity+1; payments=payments+1; return Result.Ok(true)
end
TransactionAPI={Transaction=function(_,body)
 local baseline=copy(db); local result=body(tx)
 if not result.ok then db=baseline end
 return result
end}
dofile('server/services/native_repair_commit.lua')
dofile('server/services/native_lifecycle_wear.lua')
dofile('server/services/native_attachment_commit.lua')
dofile('server/services/native_equipment_commit.lua')
local function run(remove,failure)
 mode=failure; writes=0; payments=0
 local attachment={{definitionId='carbine_wide_sight',slot='sight'}}
 local before={weaponDefinitionId='repeater_carbine',serialNumber='ordinary',condition=100,
  maintenance={degradation=0,permanentDegradation=0,damage=0,dirt=0,soot=0},attachments=remove and copy(attachment) or {}}
 local wear=copy(before); wear.maintenance.dirt=0.20000000298023224
 local after=copy(wear); after.attachments=remove and {} or copy(attachment)
 db={revision=8,metadata=copy(before),quantity=remove and 0 or 1}
 spec={characterId='Jane',itemId=135,itemRevision=8,before=before,after=after,
  action=remove and 'attachment-remove' or 'attachment-install',attachmentId='carbine_wide_sight',
  material={definitionId=9,itemName='carbine_wide_sight',quantity=1,direction=remove and 'return' or 'consume'},
  expected={weapon_shoulder={itemId=135,revision=8}},lifecycleSnapshot={},
  lifecycleWear={{itemId=135,itemRevision=8,before=copy(before),after=wear}}}
 local result=registered.CommitNativeAttachmentTransition(
  {actorSource=2,characterId='Jane',sessionId='s',epoch='e',ticket='ticket'},spec)
 assert(spec.itemRevision==8 and spec.expected.weapon_shoulder.revision==8,'immutable original reservation')
 if failure then
  assert(not result.ok and db.revision==8 and db.metadata.maintenance.dirt==0 and db.quantity==(remove and 0 or 1),
   'wear, payment and metadata roll back together: '..failure)
 else
  assert(result.ok and db.revision==10 and writes==2 and payments==1)
  assert(math.abs(db.metadata.maintenance.dirt-0.2)<0.000001)
  assert(db.quantity==(remove and 1 or 0) and (#db.metadata.attachments==(remove and 0 or 1)))
 end
end
run(false); run(true)
run(false,'payment'); run(true,'capacity'); run(false,'cas'); run(false,'authority')
print('Attachment composition PASS (real export/wear/repair/attachment bodies, JSON rounding, changed install/remove, atomic rollback failures)')
