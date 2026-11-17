local root=arg and arg[1] or '.'
Config={maxWeight=10,maxItemSlots=2}
Boolean={[0]=false,[1]=true,[false]=false,[true]=true}
local held=true
local publicWeight,weightLimit,publicCount,maximum,definitionWeight=7,10,1,6,2
local corrupt=false
local function query(sql,p)
 if sql:find('SELECT character_id FROM inventory WHERE id=',1,true) then
  return {p[1]==5 and {character_id='john'} or {}}
 end
 if sql:find('FROM inventory_character_collections c',1,true) then
  assert(sql:find("c.collection_key='native_throwable_units_v1'",1,true),'spent/other collection never adds carried weight')
  assert(p[1]=='john' and not sql:find('source.character_id',1,true),'bound UUID avoids mixed-collation join')
  if not held then return {} end
  return {{id=90,item_id=10,row_revision=1,metadata='{}',itemName='weapon_thrown_tomahawk',
   type='item_weapon',instance_mode='unique',weight='2.00',custody_id=99,
   location='character_collection',is_public=corrupt and 1 or 0,max_slots=3}}
 end
 if sql:find('SELECT SUM(',1,true) then return {{weight=tostring(publicWeight)}} end
 if sql:find('SELECT COALESCE(SUM(',1,true) then return {{weight=tostring(publicWeight)}} end
 if sql:find('SELECT `max_weight`',1,true) then return {{max_weight=weightLimit,ignore_item_limit=0,max_slots=2}} end
 if sql:find('GROUP BY `slot_index`',1,true) then return {{slot_index=0,item_id=11,count=1}} end
 if sql:find('FROM `items` WHERE `name`',1,true) then return {{id=10,max_quantity=maximum,max_stack_size=1,
  weight=definitionWeight,instance_mode='unique'}} end
 if sql:find('FROM `inventory_blacklist`',1,true) then return {} end
 if sql:find('SELECT COUNT(',1,true) then return {{count=publicCount}} end
 error(sql)
end
DB={query=function(sql,...) return query(sql,{...}) end}
dofile(root..'/server/services/native_throwable_unit_storage.lua')
dofile(root..'/server/controllers/inventory.lua')
dofile(root..'/server/helpers/move_planner.lua')
assert(InventoryControllers.GetInventoryTotalWeight(5)==9)
assert(InventoryControllers.GetInventoryTotalWeight(6)==7,'shared storage has no character-held weight')
local ok,code=InventoryControllers.AcceptanceInTransaction(query,5,{{item='weapon_thrown_tomahawk',quantity=1}})
assert(not ok and code=='weight_limit','carried units must not shed weight')
definitionWeight=1
assert(InventoryControllers.AcceptanceInTransaction(query,5,{{item='weapon_thrown_tomahawk',quantity=1}}),
 'private slots do not occupy public inventory compartments')
definitionWeight=2;weightLimit=9
assert(InventoryControllers.AcceptanceInTransaction(query,5,{{item='weapon_thrown_tomahawk',quantity=1}},{[90]=true}),
 'returning an already carried unit does not double-charge weight')
assert(not InventoryControllers.AcceptanceInTransaction(query,5,{{item='weapon_thrown_tomahawk',quantity=1}},{[91]=true}),
 'unknown return ID cannot discount weight')
weightLimit=100;definitionWeight=0;publicCount=5
ok,code=InventoryControllers.AcceptanceInTransaction(query,5,{{item='weapon_thrown_tomahawk',quantity=1}})
assert(not ok and code=='item_limit','carried quantity counts toward definition cap')
assert(InventoryControllers.AcceptanceInTransaction(query,5,{{item='weapon_thrown_tomahawk',quantity=1}},{[90]=true}),
 'returning the existing unit does not double-charge quantity')
local accounting=assert(NativeThrowableUnitStorage.Accounting(query,5,true))
assert(accounting.rows[1].slot_index==nil and accounting.counts['10']==1)
local policy={max_weight=2,max_slots=1,ignore_item_limit=0}
local candidate={id=1,item_id=10,weight=1,max_quantity=6,max_stack_size=1,instance_mode='unique'}
local plan,reason=InventoryMovePlanner.Plan(policy,accounting.rows,{candidate},{},false)
assert(not plan and reason=='weight_limit','same carried rows constrain greedy/ordinary move planner')
ok,code=InventoryMovePlanner.ValidateArrivals(policy,accounting.rows,{candidate},{})
assert(not ok and code=='weight_limit','same carried rows constrain cross-inventory slot swap')
corrupt=true
assert(NativeThrowableUnitStorage.Accounting(query,5,true)==nil)
assert(not pcall(InventoryControllers.GetInventoryTotalWeight,5),'corruption cannot silently report zero weight')
assert(not InventoryControllers.AcceptanceInTransaction(query,5,{{item='weapon_thrown_tomahawk',quantity=1}}))
print('Carried throwable weight PASS: display, add/checkout capacity, return neutrality, quantity caps, planner/swap budgets, no public slots, corruption refusal; mocked SQL')
