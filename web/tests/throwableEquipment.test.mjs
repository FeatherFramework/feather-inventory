import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {runInNewContext} from 'node:vm';
import {carriedThrowableUnits,isNativeThrowable,loadMeleeContextAction} from '../src/meleeContextAction.js';
import {equipmentBusyMessage} from '../src/equipmentPresentation.js';
import {setStrings,t} from '../src/i18n.js';

assert(isNativeThrowable({name:'weapon_thrown_tomahawk'}));
assert(!isNativeThrowable({name:'weapon_thrown_tomahawk_ancient'}));
assert.deepEqual(carriedThrowableUnits([{id:42},{id:41}]),[{id:41},{id:42}]);
for(const input of [undefined,{},[{id:0}],[{id:NaN}],[{id:'41'}],[{id:41},{id:41}],Array.from({length:4},(_,i)=>({id:i+1}))]) {
 assert.deepEqual(carriedThrowableUnits(input),[]);
}
for(const action of ['equip','unequip']) {
 const menu={};await loadMeleeContextAction(menu,42,async()=>({data:{ok:true,value:{identity:{epoch:'e'},
  options:[{action,slot:'weapon_throwable'}]}}}),()=>true,true);
 assert.equal(menu.equipmentAction.option.action,action);
}
const app=readFileSync(new URL('../src/App.vue',import.meta.url),'utf8');
const pick=(from,to)=>app.slice(app.indexOf(from),app.indexOf(to,app.indexOf(from)));
for(const mode of ['success','failed','unavailable','stale','closed','wrong-action']) {
 let generation=0,reads=0,writes=0,resolveRead,resolveWrite,closed=0;
 const ref=value=>({value});
 const ctx={equipmentBusyMessage,loadMeleeContextAction,visible:ref(true),
  equipmentBusy:ref(false),ammoBusy:ref(false),mutationBusy:ref(false),
  player:{carriedThrowables:[{id:41},{id:42}]},
  equipmentPanel:ref(null),equipmentSlots:ref([]),equipmentScope:ref(null),equipmentItem:ref(null),equipmentMessage:ref(''),
  equipmentLifetime:{capture:()=>generation,current:ticket=>ticket===generation},
  api:{post:(route,payload)=>{
   assert.equal(payload.itemId,42,'unequip stable highest unit ID');
   if(route==='Feather:Inventory:NativeEquipmentOptions') {reads++;return new Promise(resolve=>{resolveRead=resolve;});}
   assert.equal(route,'Feather:Inventory:NativeEquipmentChange');assert.equal(payload.action,'unequip');
   assert.equal(payload.slot,'weapon_throwable');assert.equal(payload.scope.epoch,'current');writes++;
   return new Promise(resolve=>{resolveWrite=resolve;});
  }},
 };
 ctx.withMutationBusy=async(label,fn)=>{assert.equal(label,'ui_equipment_unequipping');ctx.mutationBusy.value=true;try{return await fn();}finally{ctx.mutationBusy.value=false;}};
 ctx.closeAmmoPanel=()=>{generation++;ctx.equipmentScope.value=null;};
 ctx.closeEquipmentPanel=()=>{generation++;closed++;ctx.equipmentPanel.value=null;ctx.equipmentScope.value=null;};
 runInNewContext(pick('async function onUnequipThrowable()', 'async function onContextEquipment()')+
  pick('async function changeEquipment(', 'async function onContextAmmo()')+';globalThis.activate=onUnequipThrowable;',ctx);
 const pending=ctx.activate();await ctx.activate();assert.equal(reads,1,'duplicate click never starts a second read');
 if(mode==='stale') generation++;
 if(mode==='closed') ctx.visible.value=false;
 resolveRead({data:{ok:true,value:{identity:{epoch:'current'},options:mode==='unavailable'?[]:
  [{action:mode==='wrong-action'?'equip':'unequip',slot:'weapon_throwable'}]}}});
 await new Promise(resolve=>setImmediate(resolve));
 if(['stale','closed','unavailable','wrong-action'].includes(mode)) {
  await pending;assert.equal(writes,0,'unavailable/stale selection cannot mutate');
 } else {
  assert.equal(writes,1);await ctx.activate();assert.equal(writes,1);
  resolveWrite({data:{ok:mode==='success'}});await pending;
  assert.equal(closed,mode==='success'?1:0);
  if(mode==='failed')assert.equal(ctx.equipmentMessage.value,'ui_equipment_uncertain');
 }
 assert.equal(ctx.player.carriedThrowables.length,2,'UI never optimistically returns a unit or decrements quantity');
 assert.equal(ctx.equipmentBusy.value,false);assert.equal(ctx.mutationBusy.value,false);
}
setStrings({ui_throwables_carried:'Tomahawks équipés : {n}',ui_throwable_unequip_one:'Ranger un'});
assert.equal(t('ui_throwables_carried',2),'Tomahawks équipés : 2');
setStrings({});assert.equal(t('ui_throwables_carried',1),'Tomahawks equipped: 1');
const book=readFileSync(new URL('../src/components/LedgerBook.vue',import.meta.url),'utf8');
assert(book.includes('+ props.carriedWeight'));
assert(book.includes('v-if="carriedThrowables > 0"'));
assert(book.includes("t('ui_throwables_carried', carriedThrowables)"));
console.log('PASS throwable equipment UI: direct actions, carried management, single-submit, stale/failure guards, authoritative counts and live locale fallback');
