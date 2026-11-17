import assert from 'node:assert/strict';
import {equipmentBusyMessage} from '../src/equipmentPresentation.js';
import {isNativeFirearm,isNativeMelee,loadMeleeContextAction} from '../src/meleeContextAction.js';
for(const name of ['knife','machete','hammer','cleaver','hatchet']) assert(isNativeMelee({name:'weapon_melee_'+name}));
for(const name of ['weapon_melee_davy_lantern','weapon_revolver_cattleman','consumable_apple']) assert(!isNativeMelee({name}));
for(const action of ['equip','unequip']) {
 const menu={};let writes=0;
 await loadMeleeContextAction(menu,42,async(route,payload)=>{
  assert.equal(route,'Feather:Inventory:NativeEquipmentOptions');assert.equal(payload.itemId,42);writes++;
  return {data:{ok:true,value:{options:[{action,slot:'weapon_melee_secondary'}],identity:{epoch:'e'}}}};
 },()=>true);
 assert.equal(menu.equipmentAction.option.action,action);assert.equal(menu.equipmentAction.itemId,42);assert.equal(menu.equipmentLoading,false);assert.equal(writes,1);
}
for(const options of [[],[{action:'repair',slot:'weapon_melee'}],[{action:'equip',slot:'weapon'}],[{action:'equip',slot:'weapon_melee'},{action:'unequip',slot:'weapon_melee'}]]) {
 const menu={};await loadMeleeContextAction(menu,42,async()=>({data:{ok:true,value:{options,identity:{epoch:'e'}}}}),()=>true);assert.equal(menu.equipmentAction,null);
}
let resolve;let current=true;const menu={};
const pending=loadMeleeContextAction(menu,42,()=>new Promise(r=>{resolve=r}),()=>current);
assert(menu.equipmentLoading);current=false;
resolve({data:{ok:true,value:{options:[{action:'equip',slot:'weapon_melee'}],identity:{epoch:'old'}}}});await pending;
assert.equal(menu.equipmentAction,null,'closed/replaced context must not receive late action');
const failed={};await loadMeleeContextAction(failed,42,async()=>{throw Error('offline')},()=>true);assert.equal(failed.equipmentAction,null);assert.equal(failed.equipmentLoading,false);
console.log('PASS melee context: authoritative action, read-only fetch, late context refusal and failure without retry');

for (const name of ['revolver_cattleman','pistol_m1899','repeater_henry','rifle_boltaction','sniperrifle_carcano','shotgun_pump']) assert(isNativeFirearm({name:'weapon_'+name}));
assert(!isNativeFirearm({name:'weapon_kit_binoculars'}));

// Exercise the actual App handlers: one click submits only the equipment route.
const {readFileSync}=await import('node:fs');
const {runInNewContext}=await import('node:vm');
const app=readFileSync(new URL('../src/App.vue',import.meta.url),'utf8');
const pick=(from,to)=>app.slice(app.indexOf(from),app.indexOf(to,app.indexOf(from)));
for(const ok of [true,false]) {
 let complete,calls=0,generation=0,closed=0;
 const ref=(value)=>({value});
 const scope={characterId:'c',sessionId:'s',epoch:'e'};
 const ctx={equipmentBusyMessage,equipmentBusy:ref(false),ammoBusy:ref(false),mutationBusy:ref(false),contextIsDirectEquipment:ref(true),
  contextMenu:ref({equipmentAction:{itemId:42,scope,option:{action:'equip',slot:'weapon_melee'}}}),
  contextStack:()=>({items:[{id:42}]}),equipmentScope:ref(null),equipmentItem:ref(null),
  equipmentPanel:ref(null),equipmentSlots:ref([]),equipmentMessage:ref(''),
  equipmentLifetime:{capture:()=>generation,current:(ticket)=>ticket===generation},
  withMutationBusy:async(_,fn)=>fn(),
  api:{post:(route,payload)=>{calls++;assert.equal(route,'Feather:Inventory:NativeEquipmentChange');assert.equal(payload.itemId,42);assert.equal(payload.scope.epoch,'e');return new Promise(r=>{complete=r});}},
 };
 ctx.closeAmmoPanel=()=>{generation++;ctx.equipmentScope.value=null;};
 ctx.closeEquipmentPanel=()=>{generation++;closed++;ctx.equipmentScope.value=null;};
 runInNewContext(pick('async function onContextDirectEquipment()', 'async function onContextEquipment()')+
  pick('async function changeEquipment(', 'async function onContextAmmo()')+';globalThis.activate=onContextDirectEquipment;',ctx);
 const operation=ctx.activate();await ctx.activate();assert.equal(calls,1,'duplicate click refused while request pending');
 complete({data:{ok}});await operation;assert.equal(calls,1,'no automatic mutation retry');
 assert.equal(closed,ok?1:0);if(!ok)assert.equal(ctx.equipmentMessage.value,'ui_equipment_uncertain');
}
