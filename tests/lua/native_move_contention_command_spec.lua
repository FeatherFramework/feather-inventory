Config={DevMode=true,CharacterAmmunitionEnabled=true}
local command,ackCommand,gate,reads,moves= nil,nil,0,0,0
local cid='6a2fd060-c46f-11f1-9ae2-e0d55eaa2deb'
local currentCid=cid
local m={weaponDefinitionId='utility_lasso',serialNumber='FW-LASS-6AE6BCBA-26771B-0001',
 provenance={reference='native-jane-ownership-lasso-alpha-v1'}}
GetResourceState=function() return 'started' end
GuardsAPI={HasRegisteredGuard=function() return true end}
GetConvarInt=function() return gate end
SetConvar=function(_,v) gate=tonumber(v) end
RegisterCommand=function(name,fn,restricted)
 assert(restricted)
 if name=='InvNativeMoveContentionProbe' then command=fn
 elseif name=='InvNativeMoveAckLossProbe' then ackCommand=fn else error(name) end
end
InventoryIdentity={GetSession=function() return {ok=true,value={characterId=currentCid,sessionId='s'}} end}
InventoryControllers={
 GetInventoryByCharacter=function() return 2 end,
 MoveInventoryItems=function(from,to,ids,context)
  assert(from==2 and to==15 and #ids==1 and ids[1]==229)
  assert(context.actorSource==3 and context.actorCharacterId==cid and context.sessionId=='s')
  assert(not context.allowTargetInsert);moves=moves+1;return {}
 end}
Result={IsOk=function(v) return v and v.ok==true end}
InventoryAPI={AccessModes={INSERT='insert'},CanAccessInventory=function(actor,target,action)
 assert(actor==3 and target==15 and action=='insert');return {ok=true}
end}
InventoryMetadata={DocumentsEqual=function(a,b) return a==b end}
json={encode=function() return '{}' end,decode=function() error('unexpected JSON') end}
DB={query=function() reads=reads+1;return {{id=229,inventory_id=2,item_id=1,slot_index=1,row_revision=4,metadata=m}} end}
NativeMoveContentionProbe={Run=function(api,before,id,from,to)
 assert(gate==0 and id==229 and from==2 and to==15 and api.current())
 assert(api.move());return {phase='passed'}
end}
NativeMoveContentionProbe.RunAckLoss=function(api,before,id,from,to)
 assert(gate==0 and id==229 and from==2 and to==15 and api.current())
 assert(api.move());return {phase='awaiting_independent_readback'}
end
dofile('server/services/native_move_contention_probe.lua')
command(0,{'3','15','4'});assert(reads==0 and moves==0,'default off')
gate=1;command(3,{'3','15','4'});assert(gate==1 and reads==0,'console only')
command(0,{});assert(gate==0 and reads==0,'consume before invalid input')
gate=1;currentCid='john';command(0,{'3','15','4'});assert(reads==0)
gate=1;currentCid=cid;command(0,{'3','15','3'});assert(reads==1 and moves==0,'exact expected revision')
gate=1;command(0,{'3','15','4'});assert(reads==2 and moves==1)
gate=1;command(0,{'3','15','4'});assert(reads==2 and moves==1,'one run per resource lifetime')
gate=1;ackCommand(3,{'3','15','4'});assert(reads==2 and moves==1,'ack console only')
ackCommand(0,{'3','15','4'});assert(reads==3 and moves==2 and gate==0)
gate=1;ackCommand(0,{'3','15','4'});assert(reads==3 and moves==2,'ack also one-shot')
print('PASS default-off console/Jane/fixture/revision/access gates and ordinary move context')
