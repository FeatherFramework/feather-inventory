local root=arg and arg[1] or '.'
warn=function() end;CreateThread=function() end
Boolean={[0]=false,[1]=true};json={decode=function() return {serialNumber='paid-108'} end}
Result={Codes={DENIED='denied',NOT_FOUND='missing',INVALID_INPUT='invalid'},
 Ok=function(v) return {ok=true,value=v} end,Err=function(c) return {ok=false,code=c} end,IsOk=function(v) return v.ok end}
DB={query=function() error('separate database connection forbidden inside transaction') end}
InstancesAPI={GetInstance=function() error('nontransactional instance read forbidden') end}
dofile(root..'/server/controllers/inventory.lua')
dofile(root..'/server/services/guards.lua')
local equipped,denied,writes,locks=false,false,0,0
GuardsAPI.RegisterMoveGuard('test',function(instance,context)
 assert(instance.id==108 and instance.metadata.serialNumber=='paid-108' and instance.definition.name=='weapon_thrown_tomahawk')
 assert(instance.definition.usable and context.resource=='feather-weapons')
 local value,known=GuardsAPI.GetLockedEquipmentState(108)
 assert(known and value==equipped,'guard sees transaction-locked equipment state')
 return not denied and not value
end)
Tx={}
local file=assert(io.open(root..'/server/services/transactions.lua'));local source=file:read('*a');file:close()
local first=assert(source:find('function Tx:MoveInstance(',1,true))
local last=assert(source:find('function Tx:AssertAccess(',first,true))
assert(load(source:sub(first,last-1)))()
local tx=setmetatable({context={resource='feather-weapons'}},{__index=Tx})
tx.query=function(sql,params)
 if sql:find('FROM inventory_items ii INNER JOIN items',1,true) then
  assert(sql:find('FOR UPDATE',1,true));locks=locks+1
  return {{id=108,item_id=10,inventory_id=5,row_revision=1,slot_index=0,metadata='{}',
   name='weapon_thrown_tomahawk',type='item_weapon',instance_mode='unique',usable=1}}
 elseif sql:find('FROM `character_equipment`',1,true) then return equipped and {{inventory_items_id=108}} or {}
 elseif sql:find('SELECT `inventory_id`',1,true) then return {{inventory_id=5,item_id=10,slot_index=0,row_revision=1}}
 elseif sql:find('UPDATE `inventory_items`',1,true) then writes=writes+1;return {affectedRows=1}
 elseif sql:find('DELETE FROM `character_equipment`',1,true) then return {affectedRows=0} end
 error(sql)
end
assert(tx:MoveInstance(108,99,0).ok and writes==1 and locks==1)
equipped=true;assert(not tx:MoveInstance(108,99,0).ok and writes==1)
equipped=false;denied=true;assert(not tx:MoveInstance(108,99,0).ok and writes==1)
print('Transaction move guard PASS: same-connection item/equipment locks, full normalized item, equipped/external veto and no separate DB read')
