Result={Ok=function(v) return {ok=true,value=v} end,Err=function(c,m) return {ok=false,error={code=c,message=m}} end}
dofile('server/services/native_attachment_commit.lua')
local function copy(v) if type(v)~='table' then return v end; local out={}; for k,x in pairs(v) do out[k]=copy(x) end; return out end
local db,active,failure
local function fixture(install)
    active=true; failure=nil
    local installed={{definitionId='carbine_wide_sight',slot='sight'}}
    local before={weaponDefinitionId='repeater_carbine',serialNumber='serial',condition=100,
        maintenance={dirt=0},ammo={ownership='character',type='regular'},attachments=install and {} or copy(installed)}
    local after=copy(before); after.attachments=install and copy(installed) or {}
    db={revision=2,metadata=copy(before),quantity=install and 1 or 0,assignment=135}
    return {characterId='Jane',itemId=135,itemRevision=2,before=before,after=after,
        expected={weapon_shoulder={itemId=135,revision=2}},attachmentId='carbine_wide_sight',
        action=install and 'attachment-install' or 'attachment-remove',
        material={definitionId=9,itemName='carbine_wide_sight',quantity=1,direction=install and 'consume' or 'return'}}
end
local tx={query=function(sql)
    if sql:find('FROM inventory WHERE',1,true) then return {{id=2}} end
    if sql:find('FROM character_equipment',1,true) then
        return {{slot='weapon_shoulder',inventory_items_id=db.assignment,row_revision=db.revision,owner_character='Jane'}}
    end
    if sql:find('FROM items WHERE',1,true) then return {{id=9,name=db.materialName or 'carbine_wide_sight'}} end
    error('unexpected SQL '..sql)
end}
function tx:GetItemForUpdate(id) assert(id==135); return Result.Ok({inventoryId=2,revision=db.revision,
    metadata=copy(db.metadata),definition={name=db.weaponName or 'weapon_repeater_carbine'}}) end
function tx:RemoveQuantity(inv,id,count)
    assert(inv==2 and id==9 and count==1)
    if db.quantity<1 then return Result.Err('insufficient','missing attachment') end
    db.quantity=db.quantity-1; if failure=='authority' then active=false end
    return Result.Ok(true)
end
function tx:AddQuantity(inv,id,count,metadata)
    assert(inv==2 and id==9 and count==1 and next(metadata)==nil)
    if failure=='capacity' then return Result.Err('capacity','return cannot fit') end
    db.quantity=db.quantity+1; return Result.Ok(true)
end
function tx:SetMetadata(id,metadata,revision)
    assert(id==135 and revision==2)
    if failure=='cas' then return Result.Err('conflict','CAS failed') end
    db.metadata=copy(metadata); db.revision=db.revision+1
    if failure=='equipment' then db.assignment=112 end
    return Result.Ok(true)
end
local function run(spec)
    local baseline=copy(db)
    local callback=setmetatable({__cfx_functionReference='current'},{__call=function() return active end})
    local result=NativeAttachmentCommit.Apply(tx,spec,callback)
    if not result.ok then db=baseline end -- owning TransactionAPI rollback
    return result
end
local spec=fixture(true); local result=run(spec)
assert(result.ok and result.value.materialConsumed==1 and db.quantity==0 and db.revision==3 and db.metadata.attachments[1])
spec=fixture(false); result=run(spec)
assert(result.ok and result.value.materialReturned==1 and db.quantity==1 and db.revision==3 and next(db.metadata.attachments)==nil)
for _,mode in ipairs({'cas','authority','equipment'}) do
    spec=fixture(true); failure=mode; result=run(spec)
    assert(not result.ok and db.quantity==1 and db.revision==2 and next(db.metadata.attachments)==nil,'rollback '..mode)
end
spec=fixture(false); failure='capacity'; assert(not run(spec).ok and db.quantity==0 and db.revision==2 and db.metadata.attachments[1])
spec=fixture(true); db.quantity=0; assert(not run(spec).ok and db.revision==2)
spec=fixture(true); spec.after.ammo.type='express'; assert(not run(spec).ok and db.quantity==1 and db.revision==2)
spec=fixture(true); spec.material.direction='return'; assert(not run(spec).ok)
spec=fixture(true); spec.expected.weapon_shoulder.revision='2'; assert(not run(spec).ok)
spec=fixture(true); db.assignment=112; assert(not run(spec).ok and db.quantity==1)
spec=fixture(true); spec.after.attachments[1].nativeComponentName='injected'; assert(not run(spec).ok)
spec=fixture(true)
spec.before.maintenance.dirt=0.20000000298023224
spec.after.maintenance.dirt=spec.before.maintenance.dirt
db.metadata.maintenance.dirt=0.20000000298023 -- JSON read after same-TX wear CAS
assert(run(spec).ok,'native float wear survives JSON rounding between wear CAS and attachment CAS')
spec=fixture(true); spec.before.maintenance.dirt=0.2; spec.after.maintenance.dirt=0.2
db.metadata.maintenance.dirt=0.21
assert(not run(spec).ok,'real wear mismatch is not rounding')
local function generic(install)
 local intent=fixture(install)
 intent.attachmentId='schofield_short_barrel'; intent.material.itemName=intent.attachmentId
 intent.attachmentPolicy={definitionId=intent.attachmentId,slot='barrel',itemName=intent.attachmentId,
  weaponDefinitionId='revolver_schofield',weaponItemName='weapon_revolver_schofield'}
 intent.before.weaponDefinitionId='revolver_schofield'; intent.after.weaponDefinitionId='revolver_schofield'
 local sight={definitionId='schofield_wide_sight',slot='sight'}
 local barrel={definitionId=intent.attachmentId,slot='barrel'}
 intent.before.attachments=install and {copy(sight)} or {copy(barrel),copy(sight)}
 intent.after.attachments=install and {copy(barrel),copy(sight)} or {copy(sight)}
 db.metadata=copy(intent.before); db.materialName=intent.material.itemName; db.weaponName=intent.attachmentPolicy.weaponItemName
 return intent
end
spec=generic(true); assert(run(spec).ok and #db.metadata.attachments==2 and db.quantity==0)
spec=generic(false); assert(run(spec).ok and #db.metadata.attachments==1 and db.metadata.attachments[1].slot=='sight' and db.quantity==1)
spec=generic(true); spec.after.attachments[2].definitionId='other_sight'; assert(not run(spec).ok and db.quantity==1)
spec=generic(true); spec.after.attachments[2]=nil; assert(not run(spec).ok)
spec=generic(true); spec.material.itemName='other_material'; assert(not run(spec).ok)
spec=generic(true); spec.attachmentPolicy.weaponItemName='foreign_weapon'; assert(not run(spec).ok)
spec=generic(true); spec.attachmentPolicy=true; assert(not run(spec).ok)
spec=generic(true); spec.after.attachments[3]=copy(spec.after.attachments[2]); assert(not run(spec).ok)
spec=generic(true); failure='cas'; assert(not run(spec).ok and db.quantity==1 and db.revision==2)
spec=generic(false); failure='capacity'; assert(not run(spec).ok and db.quantity==0 and #db.metadata.attachments==2)
print('native attachment commit PASS (reserved generic policy, slot-preserving exact delta, consume/return1, identity/CAS/capacity rollback; mocked transaction)')
