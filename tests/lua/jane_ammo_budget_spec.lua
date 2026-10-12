local jane='6a2fd060-c46f-11f1-9ae2-e0d55eaa2deb'
Config={DevMode=true,CharacterAmmunitionEnabled=false,TrustedIdempotentGrantCallers={['feather-shops']=true}}
InventoryReadiness={state='ready'}
Result={Ok=function(value) return {ok=true,value=value} end,Err=function(code,message) return {ok=false,error={code=code,message=message}} end}
InventoryIdentity={NormalizeCharacterId=function(v) return v==jane and v or nil end}
local commands,output={},{}
RegisterCommand=function(name,fn) commands[name]=fn end
local scope,current,character='1',true,jane
GetConvar=function() return scope end; GetResourceState=function() return 'stopped' end
exports={['feather-core']={GetSessionContext=function() return {ok=true,value={characterId=character,sessionId='s'}} end,
    IsSessionCurrent=function() return current end}}
ItemControllers={GetItemDefinitionByName=function() return {id=8,type='item_ammo',instance_mode='stack'} end}
local receipt,loose=nil,0
local documents,sequence={},0
json={encode=function(v) sequence=sequence+1; documents[tostring(sequence)]=v; return tostring(sequence) end,
    decode=function(v) local out={}; for k,x in pairs(documents[v]) do out[k]=x end; return out end}
local tx={}
local loseSession=false
tx.query=function(sql,args)
    if sql:find('INSERT IGNORE',1,true) then receipt=receipt or {request_fingerprint=args[3]}; return {} end
    if sql:find('SELECT `request_fingerprint`',1,true) then return {receipt} end
    if sql:find('FROM `items`',1,true) then return {{id=8,name='ammo_revolver_regular',type='item_ammo',instance_mode='stack'}} end
    if sql:find('FROM `inventory`',1,true) then return {{id=1}} end
    if sql:find('UPDATE `inventory_grant_receipts`',1,true) then receipt.result_json=args[1]; return {} end
    error(sql)
end
tx.AddQuantity=function(_,_,id,quantity)
    assert(id==8 and quantity==2); loose=loose+quantity
    if loseSession then current=false end
    return Result.Ok({101})
end
local transactions=0
TransactionAPI={Transaction=function(_,fn)
    transactions=transactions+1
    local beforeLoose=loose
    local beforeReceipt
    if receipt then beforeReceipt={request_fingerprint=receipt.request_fingerprint,result_json=receipt.result_json} end
    local result=fn(tx)
    if not result.ok then loose=beforeLoose; receipt=beforeReceipt end
    return result
end}
DB={}
local originalPrint=print; print=function(v) output[#output+1]=v end
dofile('server/services/grants_once.lua')
local run=commands.InvJaneAmmoBudget
local request={characterId=jane,grantId='native-test-jane-revolver-regular-two-v1',definitionId=8,itemName='ammo_revolver_regular',quantity=2}
assert(not GrantOnceAPI.Grant(request,'feather-inventory',{},function() return true end).ok,'external imitation lacks private key')
assert(not GrantOnceAPI.Grant(request,'feather-weapons').ok,'no broadened caller trust')
run(1,{'1',jane}); scope='0'; run(0,{'1',jane}); assert(transactions==0)
scope='1'; character='original'; run(0,{'1',jane}); assert(transactions==0)
character=jane; loseSession=true; run(0,{'1',jane})
assert(loose==0 and receipt==nil,'post-write session loss rolls back grant and receipt')
current=true; loseSession=false; run(0,{'1',jane}); assert(loose==2 and receipt.result_json)
run(0,{'1',jane}); assert(loose==2 and output[#output]:find('replayed=true',1,true),'retry cannot grant twice')
Config.CharacterAmmunitionEnabled=true; run(0,{'1',jane}); assert(loose==2)
Config.CharacterAmmunitionEnabled=false
local previewScope='0'
GetConvar=function(name) return name=='feather_jane_preview_budget' and previewScope or scope end
local preview=commands.InvJanePreviewBudget
local beforeTransactions=transactions
preview(0,{'1',jane}); assert(transactions==beforeTransactions,'old convar cannot enable preview budget')
previewScope='1'
-- Simulate the independent SQL row for the new fixed grant ID.
local oldReceipt=receipt
receipt=nil
preview(0,{'1',jane}); assert(loose==4 and receipt.result_json)
assert(documents[receipt.result_json].grantId=='native-test-jane-preview-regular-two-v1')
preview(0,{'1',jane}); assert(loose==4 and output[#output]:find('replayed=true',1,true))
assert(documents[oldReceipt.result_json].grantId=='native-test-jane-revolver-regular-two-v1')
previewScope='0'; beforeTransactions=transactions
preview(0,{'1',jane}); assert(transactions==beforeTransactions)
print=originalPrint
print('Jane preview budget PASS (separate opt-in/fixed grant receipt, two rounds only, replay safe)')
print('Jane two-round budget PASS (private fixed scope, console/session/gates, real GrantOnce, rollback on session loss, durable retry; mocked SQL/CFX)')
