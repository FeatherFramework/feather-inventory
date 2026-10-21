Result={Err=function(code,message) return {ok=false,error={code=code,message=message}} end,
 Ok=function(value) return {ok=true,value=value} end}
dofile('server/services/native_repair_verify.lua')
local function copy(v)
 if type(v)~='table' then return v end
 local out={}; for k,x in pairs(v) do out[k]=copy(x) end; return out
end
local metadata={condition=50,maintenance={dirt=1},serialNumber='serial',ammo={ownership='character',type='regular'}}
local before={characterId='jane',items={
 [112]={id=112,definitionId=2,revision=1,metadata=metadata,itemName='cattleman',inventoryId=4},
 [113]={id=113,definitionId=9,revision=0,metadata={},itemName='gun_oil',inventoryId=4},
 [114]={id=114,definitionId=3,revision=0,metadata={},itemName='ammo_revolver_regular',inventoryId=4}},
 equipment={{slot='weapon',inventory_items_id=112}},ledger={{revision=25,pools='unchanged'}},
 operations={{operation_id='receipt',result='unchanged'}},grants={{grant_id='grant',result_json='unchanged'}}}
local spec={characterId='jane',itemId=112,itemRevision=1,before=copy(metadata),after=copy(metadata),
 material={definitionId=9,itemName='gun_oil',quantity=1}}
spec.after.condition=100; spec.after.maintenance.dirt=0
local after=copy(before); after.items[113]=nil; after.items[112].revision=2; after.items[112].metadata=copy(spec.after)
assert(NativeRepairVerify.Compare(before,after,spec).ok)
local diagnostic=NativeRepairVerify.Diagnose(before,after,spec)
assert(diagnostic.ok and diagnostic.value.beforeOil==1 and diagnostic.value.currentOil==0)
assert(diagnostic.value.currentItem.revision==2 and diagnostic.value.original112Unchanged==false)
assert(diagnostic.value.ledgerUnchanged and diagnostic.value.operationsUnchanged)
local lost=copy(after); lost.equipment={}
assert(#NativeRepairVerify.Diagnose(before,lost,spec).value.currentEquipment==0)
local mutations={
 function(v) v.ledger[1].revision=26 end,
 function(v) v.operations[1].result='changed' end,
 function(v) v.grants={} end,
 function(v) v.equipment={} end,
 function(v) v.items[114]=nil end,
 function(v) v.items[112].metadata.ammo.type='express' end,
 function(v) v.items[112].metadata.serialNumber='other' end,
 function(v) v.items[112].revision=3 end,
 function(v) v.items[113]=copy(before.items[113]) end,
 function(v) v.items[115]=copy(before.items[114]) end,
 function(v) v.items[114].inventoryId=5 end,
}
for _,mutate in ipairs(mutations) do
 local bad=copy(after); mutate(bad); assert(not NativeRepairVerify.Compare(before,bad,spec).ok)
end
local corrupt=copy(spec); corrupt.after.ammo.type='express'
assert(not NativeRepairVerify.Compare(before,after,corrupt).ok)
local queries=0
local tx={query=function(sql,params)
 queries=queries+1; assert(sql:match('^SELECT') and params[1]=='jane','audit SQL must be SELECT-only')
 if sql:find('FROM inventory_items',1,true) then return {{id=112,item_id=2,row_revision=1,metadata=metadata,itemName='cattleman',inventory_id=4}} end
 return {}
end}
assert(NativeRepairVerify.Read(tx,'jane').ok and queries==5)
local captured=NativeRepairVerify.Read(tx,'jane').value
captured.items[112].metadata.ammo.type='changed'; assert(metadata.ammo.type=='regular')
print('native_repair_verify_spec PASS (SELECT-only durable snapshots, exact payment/revision, unchanged ammo/equipment/identity, corruption refusal)')
local wearBefore=copy(before)
wearBefore.items[112].metadata.maintenance={degradation=0.5,permanentDegradation=0.1,damage=0,dirt=1,soot=0}
local wearSpec={characterId=before.characterId,itemId=112,itemRevision=1,
 before=copy(wearBefore.items[112].metadata),conditionMaximum=100}
assert(NativeRepairVerify.CompareWear(wearBefore,wearBefore,wearSpec).ok)
local worn=copy(wearBefore); worn.items[112].revision=2
worn.items[112].metadata.maintenance.degradation=0.6; worn.items[112].metadata.condition=40
assert(NativeRepairVerify.CompareWear(wearBefore,worn,wearSpec).ok)
local healed=copy(worn); healed.items[112].metadata.maintenance.degradation=0.4
assert(not NativeRepairVerify.CompareWear(wearBefore,healed,wearSpec).ok)
local payment=copy(worn); payment.items[113]=nil
assert(not NativeRepairVerify.CompareWear(wearBefore,payment,wearSpec).ok)
print('native wear durable verifier PASS (exact one/no-op revision, canonical monotonic condition, no material/ammo/other-item changes)')
local pair=copy(wearBefore)
pair.items[115]=copy(pair.items[112]); pair.items[115].id=115
pair.items[115].metadata.flags={disabled=false,evidence=false}
pair.equipment={{slot='weapon',inventory_items_id=112},{slot='weapon_offhand',inventory_items_id=115},
 {slot='weapon_shoulder',inventory_items_id=114}}
local promoted=copy(pair)
promoted.items[112].revision=2; promoted.items[112].metadata.condition=0
promoted.items[112].metadata.maintenance.degradation=1
promoted.equipment={{slot='weapon_shoulder',inventory_items_id=114},{slot='weapon',inventory_items_id=115}}
local promotionSpec=copy(wearSpec)
local accepted=NativeRepairVerify.ComparePromotionWear(pair,promoted,promotionSpec)
assert(accepted.ok and accepted.value.promotionVerified and accepted.value.promotedItemId==115)
assert(not accepted.value.equipmentUnchanged and accepted.value.ammoUnchanged and accepted.value.materialConsumed==0)
assert(not NativeRepairVerify.CompareWear(pair,promoted,promotionSpec).ok,'ordinary wear remains strict')
assert(#pair.equipment==3 and #promoted.equipment==2,'verifier never mutates snapshots')
for _,mutate in ipairs({
 function(v) v.equipment[2].inventory_items_id=112 end,
 function(v) v.equipment[3]={slot='weapon_offhand',inventory_items_id=112} end,
 function(v) v.equipment[1]=nil end,
 function(v) v.equipment[1].inventory_items_id=113 end,
 function(v) v.equipment[3]={slot='weapon',inventory_items_id=113} end,
 function(v) v.items[115].revision=2 end,
 function(v) v.items[115].metadata.maintenance.dirt=0 end,
 function(v) v.items[112].metadata.serialNumber='swapped' end,
 function(v) v.items[112].metadata.condition=1 end,
 function(v) v.items[112].revision=3 end,
 function(v) v.items[112].metadata.maintenance.soot=-1 end,
 function(v) v.items[113]=nil end,
 function(v) v.items[120]=copy(v.items[114]) end,
 function(v) v.ledger[1].revision=26 end,
 function(v) v.operations={} end,
 function(v) v.grants={} end,
}) do
 local bad=copy(promoted); mutate(bad)
 assert(not NativeRepairVerify.ComparePromotionWear(pair,bad,promotionSpec).ok,'promotion conservation refusal')
end
local disabled=copy(pair); disabled.items[115].metadata.flags.disabled=true
local disabledAfter=copy(promoted); disabledAfter.items[115]=copy(disabled.items[115])
assert(not NativeRepairVerify.ComparePromotionWear(disabled,disabledAfter,promotionSpec).ok)
local broken=copy(pair); broken.items[115].metadata.condition=0
local brokenAfter=copy(promoted); brokenAfter.items[115]=copy(broken.items[115])
assert(not NativeRepairVerify.ComparePromotionWear(broken,brokenAfter,promotionSpec).ok)
print('promotion wear audit PASS (exact promotion only; independent economic/item conservation; ordinary wear unchanged)')
