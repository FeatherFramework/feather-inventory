Result={Ok=function(v) return {ok=true,value=v} end,Err=function(c,m) return {ok=false,error={code=c,message=m}} end}
local character='jane'
InventoryIdentity={NormalizeCharacterId=function(v) return v==character and v or nil end}
local commands={}
RegisterCommand=function(name,fn) commands[name]=fn end
dofile('server/services/conditional_equipment.lua')
local assigned={weapon=112}
local itemRevision=1
local current,held,loseAfterWrite=true,false,false
local writes=0
GuardsAPI={CanChangeInstance=function(id,spec)
 assert(id==112 and spec.operation=='equipment_write'); return not held
end}
local tx={query=function(sql,args)
 if sql:find('SELECT id FROM inventory',1,true)==1 then return {{id=1}} end
 if sql:find('SELECT ce.slot',1,true)==1 then
  local rows={}
  for slot,id in pairs(assigned) do rows[#rows+1]={slot=slot,inventory_items_id=id,row_revision=itemRevision,owner_character=character} end
  return rows
 end
 if sql:find('SELECT ii.id',1,true)==1 then return {{id=112,row_revision=itemRevision}} end
 if sql:find('DELETE',1,true)==1 then writes=writes+1; assigned[args[2]]=nil
 elseif sql:find('INSERT',1,true)==1 then writes=writes+1; assigned[args[2]]=args[3]
 else error(sql) end
 if loseAfterWrite then current=false end
 return {}
end}
local function run(spec)
 local before={}; for k,v in pairs(assigned) do before[k]=v end
 local result=ConditionalEquipment.Apply(tx,spec,function() return current end)
 if not result.ok then assigned=before end -- transaction caller's rollback contract
 return result
end
local expected={weapon={itemId=112,revision=1}}
local unequip={characterId='jane',slot='weapon',action='unequip',expected=expected}
assert(not run({characterId='foreign',slot='weapon',action='unequip',expected=expected}).ok and writes==0)
assert(not run({characterId='jane',slot='weapon',action='unequip',expected={}}).ok and writes==0)
held=true; assert(not run(unequip).ok and assigned.weapon==112 and writes==0); held=false
itemRevision=2; assert(not run(unequip).ok and writes==0); itemRevision=1
assert(run(unequip).ok and assigned.weapon==nil and writes==1)
local equip={characterId='jane',slot='weapon',action='equip',expected={},itemId=112,itemRevision=1}
itemRevision=2; assert(not run(equip).ok and writes==1); itemRevision=1
assert(run(equip).ok and assigned.weapon==112 and writes==3)
local before=writes
assert(not run({characterId='jane',slot='offhand',action='equip',expected=expected,itemId=112,itemRevision=1}).ok and writes==before)
loseAfterWrite=true
assert(not run(unequip).ok and assigned.weapon==112,'caller rollback preserves assignment on session loss after write')
character='6a2fd060-c46f-11f1-9ae2-e0d55eaa2deb'
current=true; loseAfterWrite=false
Config={DevMode=true,CharacterAmmunitionEnabled=false}
GetResourceState=function() return 'stopped' end
GuardsAPI.HasRegisteredGuard=function() return false end
InventoryIdentity.GetSession=function() return {ok=true,value={characterId=character,sessionId='s'}} end
exports={['feather-core']={IsSessionCurrent=function() return current end}}
TransactionAPI={Transaction=function(_,fn)
 local before={}; for k,v in pairs(assigned) do before[k]=v end
 local result=fn(tx)
 if not result.ok then assigned=before end
 return result
end}
local originalPrint=print
local output
print=function(v) output=v end
commands.InvConditionalEquipmentSmokeTest(0,{'5'})
assert(output:find('PASS staleRejected/unequip/equip',1,true) and assigned.weapon==112)
print=originalPrint
print('Conditional equipment rollback command PASS (actual helper, console/current Jane, no committed assignment)')
print('Conditional equipment PASS (full snapshot CAS, owned revision, native hold veto, duplicate slot refusal, rollback on session loss)')
