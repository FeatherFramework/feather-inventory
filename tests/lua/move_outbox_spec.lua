local clone
clone=function(v) if type(v)~='table' then return v end;local t={};for k,x in pairs(v) do t[k]=clone(x) end;return t end
local documents,sequence={},0
json={encode=function(v) sequence=sequence+1;local s='doc'..sequence;documents[s]=clone(v);return s end,decode=function(s) return clone(assert(documents[s])) end}
local metadata=json.encode({weaponDefinitionId='utility_lasso',serialNumber='ORIGINAL'})
local commands={}
RegisterCommand=function(name,fn) commands[name]=fn end
Config={DevMode=true}
local rows,pending,ack={},true,false
local calls,signals=0,{}
GetPlayers=function() return {'91','92'} end
InventoryIdentity={GetSession=function(id) return {ok=true,value={characterId=id==91 and 'Jane' or 'John'}} end}
TriggerClientEvent=function(name,id) signals[#signals+1]={name,id} end
GetResourceState=function() return 'started' end
exports={['feather-weapons']={ApplyInventoryMoveDelivery=function(_,id,raw)
 calls=calls+1;assert(documents[raw].moves[1].serialNumber=='ORIGINAL');return {ok=ack}
end}}
DB={query=function(sql)
 if sql:find('SELECT operation_id,payload',1,true) then return pending and clone(rows) or {} end
 error(sql)
end,exec=function(sql,id) assert(sql:find('SET delivered=1',1,true));pending=false end}
dofile('server/services/move_outbox.lua')
local scope={sourceInventory=2,targetInventory=15,deliveryHeaders={['2']='Jane'}}
local result={kind='slot_move',movedIds={229},swappedIds={230},facts={[229]={definitionId=39,revision=9,metadata=metadata}},swapFacts={[230]={definitionId=40,revision=3}}}
local id='00000000-0000-0000-0000-000000000001'
local doc=InventoryMoveOutbox.Build(id,result,{actorCharacterId='Jane',actorSource=1},scope)
assert(#doc.moves==2 and doc.moves[1].serialNumber=='ORIGINAL' and doc.moves[2].fromInventoryId==15 and doc.moves[2].toInventoryId==2 and doc.moves[2].reason=='slot_swap')
InventoryMoveOutbox.Append(function(sql,p) assert(sql:find('INSERT INTO inventory_move_outbox',1,true));rows={{operation_id=p[1],payload=p[2]}};return {affectedRows=1} end,id,result,{actorCharacterId='Jane'},scope)
InventoryMoveOutbox.Sweep();assert(pending and calls==1 and #signals==0,'no consumer acknowledgement retains delivery')
ack=true
-- Recreate the service, representing a resource restart; only SQL rows persist.
dofile('server/services/move_outbox.lua')
InventoryMoveOutbox.Sweep();assert(not pending and calls==2 and #signals==2)
for _,signal in ipairs(signals) do assert(signal[2]==91,'resolve current session, never stale actorSource or John') end
InventoryMoveOutbox.Sweep();assert(calls==2,'acknowledged row is not replayed')
print('PASS move outbox: immutable move/swap snapshots, atomic append, consumer outage/restart, acknowledgement fence and current-recipient UI/hotbar refresh')

local deposit=clone(doc);deposit.operationId='00000000-0000-0000-0000-000000000002';deposit.moves={deposit.moves[1]};deposit.moves[1].serialNumber='FW-LASS-6AE6BCBA-26771B-0001'
local pickup=clone(deposit);pickup.operationId='00000000-0000-0000-0000-000000000003';pickup.moves[1].fromInventoryId=15;pickup.moves[1].toInventoryId=2;pickup.moves[1].revision=10
rows={{operation_id=pickup.operationId,payload=json.encode(pickup),delivered=1},{operation_id=deposit.operationId,payload=json.encode(deposit),delivered=1}}
DB.query=function(sql) assert(sql:find('ORDER BY created_at',1,true));return clone(rows) end
local redeliveries=0
exports['feather-weapons'].AuditInventoryMoveDelivery=function(_,id) return {ok=true,events=1,eventIds={id==deposit.operationId and 51 or 52}} end
exports['feather-weapons'].ApplyInventoryMoveDelivery=function(_,id) redeliveries=redeliveries+1;return {ok=true,replayed=true,eventIds={id==deposit.operationId and 51 or 52}} end
commands.InvMoveDeliveryAcceptance(99,{});assert(redeliveries==0,'players cannot invoke acceptance')
commands.InvMoveDeliveryAcceptance(0,{})
local report=documents['doc'..sequence]
assert(report.phase=='passed' and report.checks==4 and report.provenanceEvents==2 and redeliveries==4 and report.itemWrites==0)
print('PASS live delivery acceptance wiring: two committed fixture snapshots, four already-recorded redeliveries, independent before/after audits, no item writes')
