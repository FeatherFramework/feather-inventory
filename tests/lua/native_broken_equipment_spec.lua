local root=arg and arg[1] or '.'
local function copy(v) if type(v)~='table' then return v end; local out={}; for k,x in pairs(v) do out[k]=copy(x) end; return out end
Result={Ok=function(v) return {ok=true,value=v} end,Err=function(c,m) return {ok=false,error={code=c,message=m}} end}
InventoryIdentity={NormalizeCharacterId=function(v) return v end}
RegisterCommand=function() end
dofile(root..'/server/services/native_repair_commit.lua')
dofile(root..'/server/services/conditional_equipment.lua')
dofile(root..'/server/services/native_lifecycle_wear.lua')
local db,active,veto,failWrite,vetoAfterDetach,deathGuard,vetoPromotion
GuardsAPI={CanChangeInstance=function(id,context)
 if deathGuard then
  assert(context.operation=='equipment_write' and (context.equipmentAction=='unequip' or context.equipmentAction=='equip') and context.resource=='feather-weapons')
  assert(context.runtimeEpoch=='epoch' and context.runtimeTicket=='ticket' and context.actorSource==1
   and context.characterId=='Jane' and context.sessionId=='session')
  assert(context.equipmentItemId==(context.equipmentAction=='equip' and 129 or db.equipment[context.equipmentSlot]))
 end
 return not veto and not (vetoAfterDetach and db.equipment.weapon_offhand==nil)
  and not (vetoPromotion and context.equipmentAction=='equip'),'independent hold'
end}
local before={condition=10,maintenance={degradation=0.9,permanentDegradation=0,damage=0.9,dirt=0.3,soot=0},
 serialNumber='original',attachments={{slot='sight',definitionId='saved-sight'}},ammo={ownership='character'}}
local after=copy(before); after.condition=0; after.maintenance.damage=1
local spec={characterId='Jane',action='shutdown',expected={weapon={itemId=128,revision=2},
 weapon_offhand={itemId=129,revision=4},weapon_shoulder={itemId=135,revision=1}},
 lifecycleWear={{itemId=128,itemRevision=2,before=before,after=after}},
 brokenEquipment={weapon={itemId=128,minimum=1,reason='broken'},weapon_offhand={itemId=129,reason='primary_broken'}}}
local function reset()
 active,veto,failWrite,vetoAfterDetach,deathGuard=true,false,false,false,false
 vetoPromotion=false
 db={items={[128]={revision=2,metadata=copy(before)},[129]={revision=4,metadata={condition=100}},
  [135]={revision=1,metadata={condition=100}}},equipment={weapon=128,weapon_offhand=129,weapon_shoulder=135},ammo=17,material=2}
end
local tx={}
function tx.query(sql,p)
 if sql:find('SELECT ii.id, ii.row_revision',1,true) then return {{id=p[1],row_revision=db.items[p[1]].revision}} end
 if sql:find('INSERT INTO character_equipment',1,true) then db.equipment[p[2]]=p[3]; return 1 end
 if sql:find('SELECT id FROM inventory',1,true) then return {{id=2}} end
 if sql:find('DELETE FROM character_equipment',1,true) then db.equipment[p[2]]=nil; return 1 end
 if sql:find('FROM character_equipment',1,true) then
  local rows={}; for slot,id in pairs(db.equipment) do rows[#rows+1]={slot=slot,inventory_items_id=id,
   row_revision=db.items[id].revision,owner_character='Jane'} end; return rows
 end
 error('unexpected SQL '..sql)
end
function tx:GetItemForUpdate(id)
 local item=db.items[id]; return Result.Ok({inventoryId=2,revision=item.revision,metadata=copy(item.metadata)})
end
function tx:SetMetadata(id,value,revision)
 if failWrite then return Result.Err('cas','revision refused') end
 assert(db.items[id].revision==revision)
 db.items[id].metadata=copy(value); db.items[id].revision=revision+1; return Result.Ok({})
end
local function apply(value,guardContext)
 local snapshot=copy(db)
 local result=NativeLifecycleWear.Apply(tx,value or spec,function() return active end,guardContext)
 if not result.ok then db=snapshot end -- models TransactionAPI rollback boundary
 return result
end
reset(); local result=apply()
assert(result.ok and db.equipment.weapon==nil and db.equipment.weapon_offhand==nil and db.equipment.weapon_shoulder==135)
assert(db.items[128].revision==3 and db.items[128].metadata.condition==0 and db.items[128].metadata.serialNumber=='original')
assert(db.items[128].metadata.attachments[1].definitionId=='saved-sight' and db.items[129].revision==4)
assert(db.items[129].metadata.condition==100 and db.ammo==17 and db.material==2)
assert(result.value.expected.weapon==nil and spec.expected.weapon.revision==2,'working snapshot only is rebased')
reset(); veto=true; assert(not apply().ok and db.items[128].revision==2 and db.equipment.weapon==128,'independent hold rolls wear and detach back')
reset(); vetoAfterDetach=true; assert(not apply().ok and db.items[128].revision==2 and db.equipment.weapon_offhand==129
 and db.equipment.weapon==128,'failure after first detach rolls the partial equipment change back')
reset(); failWrite=true; assert(not apply().ok and db.equipment.weapon_offhand==129,'failed wear cannot detach')
reset(); local forged=copy(spec); forged.brokenEquipment.weapon.itemId=135
assert(not apply(forged).ok and db.items[128].revision==2)
reset(); forged=copy(spec); forged.brokenEquipment.weapon=nil
assert(not apply(forged).ok and db.equipment.weapon_offhand==129,'dependent offhand requires broken primary')
reset(); forged=copy(spec); forged.lifecycleWear={}
assert(not apply(forged).ok and db.equipment.weapon==128,'healthy metadata cannot be detached as broken')
reset(); active=false; assert(not apply().ok and db.items[128].revision==2)
reset(); local dead=copy(spec); dead.action='death'
assert(not apply(dead).ok and db.items[128].revision==2 and db.equipment.weapon==128,'death cannot use released-owner path without reserved context')
local context={resource='feather-weapons',actorSource=1,characterId='Jane',sessionId='session',runtimeEpoch='epoch',runtimeTicket='ticket',
 equipmentAction='equip',equipmentSlot='forged',equipmentItemId=999,operation='move'}
reset(); deathGuard=true; assert(apply(dead,context).ok and db.equipment.weapon==nil and db.equipment.weapon_offhand==nil)
assert(context.equipmentAction=='equip','guard context is private and actual action overrides forged context fields')
reset(); deathGuard=true; vetoAfterDetach=true
assert(not apply(dead,context).ok and db.equipment.weapon==128 and db.equipment.weapon_offhand==129 and db.items[128].revision==2)
print('Broken equipment composition PASS (real wear/conditional bodies, exact primary+dependent offhand detach, untouched shoulder/serial/attachments/ammo/material, guard/CAS/authority rollback; mocked DB)')

-- Compose the actual final ammo export wrapper, wear body and equipment body.
-- Only database transport/Core/runtime authority are mocked here.
local documents,sequence={},0
json={encode=function(value) sequence=sequence+1; documents[tostring(sequence)]=copy(value); return tostring(sequence) end,
 decode=function(value) return copy(documents[value]) end}
Result.Codes={DENIED='denied',CONFLICT='conflict',INVALID_INPUT='invalid',NOT_FOUND='missing'}
Config={DevMode=true,CharacterAmmunitionEnabled=true}
exports={['feather-core']={IsSessionCurrent=function() return active end},
 ['feather-weapons']={ValidateCharacterAmmoRuntimeOperation=function() return active end}}
TransactionAPI={Transaction=function(_,body)
 local snapshot=copy(db); local outcome=body(tx)
 if not outcome.ok then db=snapshot end
 return outcome
end}
local baseQuery=tx.query
function tx.query(sql,p)
 if sql:find('SELECT revision, pools',1,true) then return {{revision=db.ledgerRevision,pools=json.encode({ammo=db.ammo})}} end
 if sql:find('UPDATE feather_character_ammunition',1,true) then
  assert(db.ledgerRevision==p[4]); db.ammo=json.decode(p[1]).ammo; db.ledgerRevision=p[2]; return {affectedRows=1}
 end
 return baseQuery(sql,p)
end
dofile(root..'/server/services/character_ammunition.lua')
local observation={expectedRevision=25,pools={ammo=16},limits={ammo=20},finalWear=dead}
reset(); db.ledgerRevision=25; deathGuard=true; vetoAfterDetach=true
assert(not CharacterAmmunitionAPI.Observe(context,observation,'feather-weapons').ok)
assert(db.ammo==17 and db.ledgerRevision==25 and db.items[128].revision==2
 and db.equipment.weapon==128 and db.equipment.weapon_offhand==129,'partial equipment failure rolls ammo, wear and assignments back together')
reset(); db.ledgerRevision=25; deathGuard=true
assert(CharacterAmmunitionAPI.Observe(context,observation,'feather-weapons').ok)
assert(db.ammo==16 and db.ledgerRevision==26 and db.items[128].revision==3
 and db.equipment.weapon==nil and db.equipment.weapon_offhand==nil and db.equipment.weapon_shoulder==135)
reset(); db.ledgerRevision=25; db.ammo=0; deathGuard=true; observation.pools.ammo=0
assert(CharacterAmmunitionAPI.Observe(context,observation,'feather-weapons').ok and db.ledgerRevision==25
 and db.items[128].revision==3 and db.equipment.weapon==nil,'zero ammo still persists wear/detach without ledger churn')
print('Death broken atomic composition PASS (actual ammo observation + wear + guarded equipment transaction, funded/zero belt, partial-detach rollback; mocked DB)')
local promote=copy(dead); promote.brokenEquipment.weapon_offhand.promote=true
promote.brokenEquipment.weapon_offhand.minimum=1
reset(); local livingPromotion=copy(promote); livingPromotion.action='shutdown'
assert(apply(livingPromotion).ok and db.equipment.weapon==129 and db.items[129].revision==4,'released living path promotes without metadata revision churn')
reset(); deathGuard=true
assert(apply(promote,context).ok and db.equipment.weapon==129 and db.equipment.weapon_offhand==nil)
assert(db.items[129].revision==4 and db.items[129].metadata.condition==100 and db.ammo==17 and db.material==2)
reset(); deathGuard=true; vetoPromotion=true
assert(not apply(promote,context).ok and db.equipment.weapon==128 and db.equipment.weapon_offhand==129 and db.items[128].revision==2)
reset(); db.items[129].metadata.condition=0
assert(not apply(promote,context).ok and db.equipment.weapon==128)
reset(); deathGuard=true; db.ledgerRevision=25; observation.finalWear=promote; observation.pools.ammo=16
assert(CharacterAmmunitionAPI.Observe(context,observation,'feather-weapons').ok and db.equipment.weapon==129 and db.ledgerRevision==26)
reset(); deathGuard=true; db.ledgerRevision=25; vetoPromotion=true
assert(not CharacterAmmunitionAPI.Observe(context,observation,'feather-weapons').ok and db.ammo==17 and db.ledgerRevision==25
 and db.equipment.weapon==128 and db.items[128].revision==2)
print('Healthy offhand promotion PASS (assignment-only move, exact guard context, funded death atomic rollback, unhealthy refusal)')
