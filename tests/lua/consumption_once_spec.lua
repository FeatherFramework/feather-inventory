local root=arg[1]
local function copy(v) if type(v)~='table' then return v end; local r={}; for k,x in pairs(v) do r[k]=copy(x) end; return r end
local docs,serial={},0
json={encode=function(v) serial=serial+1; docs[tostring(serial)]=copy(v); return tostring(serial) end,
    decode=function(v) assert(docs[v]); return copy(docs[v]) end}
Result={Ok=function(v) return {ok=true,value=v} end,Err=function(c,m) return {ok=false,error={code=c,message=m}} end}
Config={TrustedConsumptionCallers={['bcc-stables']={['care.v1']={apple=true}}}}
InventoryIdentity={NormalizeCharacterId=function(v)
    return type(v)=='string' and v:match('^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$') and v:lower() or nil
end}
local state,failSave,unknown,blocked,archived
local function request()
    return {operationId='10000000-0000-4000-8000-000000000001',characterId='20000000-0000-4000-8000-000000000002',
        instanceId=5,definitionId=10,expectedRevision=3,itemName='apple',purpose='care.v1',effectReference='horse.uuid:policy1'}
end
local tx={}
function tx.query(sql,p)
    local key=tostring(p[1])..'|'..tostring(p[2])
    if sql:find('INSERT IGNORE',1,true) then
        if state.receipts[key] then return {affectedRows=0} end
        state.receipts[key]={request_fingerprint=p[3]}; return {affectedRows=1}
    elseif sql:find('SELECT request_fingerprint',1,true) then return {state.receipts[key]}
    elseif sql:find('UPDATE inventory_consumption',1,true) then
        if failSave then return {affectedRows=0} end
        state.receipts[p[2]..'|'..p[3]].result_json=p[1]; return {affectedRows=1}
    elseif sql:find('FROM inventory WHERE',1,true) then return {{id=7}}
    elseif sql:find('FROM items WHERE',1,true) then return {{archived_at=archived and 'date' or nil}} end
    error(sql)
end
function tx:GetItemForUpdate(id)
    assert(id==5); if not state.item then return Result.Err('not_found','absent') end
    return Result.Ok(copy(state.item))
end
function tx:RemoveInstances(inv,def,ids)
    assert(inv==7 and def==10 and #ids==1 and ids[1]==5)
    if blocked then return Result.Err('denied','guard refused') end
    state.item=nil; state.removed=state.removed+1; return Result.Ok({5})
end
function tx:SetMetadata(id,metadata,revision)
    assert(id==5 and revision==state.item.revision)
    if blocked then return Result.Err('denied','guard refused') end
    state.item.metadata=copy(metadata);state.item.revision=revision+1
    return Result.Ok({revision=revision+1})
end
TransactionAPI={Transaction=function(context,body)
    assert(context.resource=='bcc-stables' and context.idempotencyKey==nil)
    local before=copy(state); local result=body(tx)
    if not result.ok then state=before end
    if unknown then error('commit acknowledgement lost') end
    return result
end}
DB={exec=function() end,query=function(sql)
    if sql:find('information_schema',1,true) then return {{ENGINE='InnoDB'}} end
    if sql:find('SHOW INDEX',1,true) then return {{Key_name='PRIMARY',Seq_in_index=1,Column_name='source_resource'},
        {Key_name='PRIMARY',Seq_in_index=2,Column_name='operation_id'}} end
    local rows={}; for name,kind in pairs({source_resource='varchar(100)',operation_id='char(36)',request_fingerprint='varchar(700)',result_json='longtext',created_at='timestamp'}) do
        rows[#rows+1]={Field=name,Type=kind,Null=name=='result_json' and 'YES' or 'NO',Collation='utf8mb4_bin'}
    end
    return rows
end}
local function reset()
    state={receipts={},removed=0,item={id=5,inventoryId=7,revision=3,definition={id=10,name='apple',type='item_item',instanceMode='stack'}}}
    failSave,unknown,blocked,archived=false,false,false,false
    dofile(root..'/server/services/consumption_once.lua'); ConsumptionOnceAPI.Start()
end
local count=0
local function test(name,fn) reset(); fn(); count=count+1; print('PASS consumption '..name) end
local function run(mode,r,resource) return ConsumptionOnceAPI[mode or 'Consume'](r or request(),resource or 'bcc-stables') end
local function code(r,c) assert(not r.ok and r.error.code==c, r.error and r.error.code or 'unexpected success') end

test('consumed receipt survives reload; replay never removes again',function()
    assert(run().value.state=='consumed' and state.removed==1)
    dofile(root..'/server/services/consumption_once.lua'); ConsumptionOnceAPI.Start()
    assert(run().value.replayed and run('Inspect').value.state=='consumed' and state.removed==1)
    assert(run('Cancel').value.state=='consumed' and state.removed==1)
end)
test('cancel first permanently fences consumption',function()
    assert(run('Cancel').value.state=='cancelled')
    assert(run().value.state=='cancelled' and run().value.replayed and state.item and state.removed==0)
end)
test('every immutable request field binds receipt',function()
    assert(run().ok)
    for _,field in ipairs({'characterId','instanceId','definitionId','expectedRevision','effectReference'}) do
        local r=request(); r[field]=type(r[field])=='number' and r[field]+1 or (field=='characterId' and r.operationId or 'different')
        code(run('Consume',r),'receipt_conflict'); code(run('Cancel',r),'receipt_conflict')
    end
end)
test('same item under another operation cannot consume twice',function()
    assert(run().ok); local r=request(); r.operationId='30000000-0000-4000-8000-000000000003'
    code(run('Consume',r),'not_found'); assert(state.removed==1)
end)
test('item guards and receipt save failure roll back both changes',function()
    blocked=true; code(run(),'denied'); assert(state.item and next(state.receipts)==nil)
    blocked=false; failSave=true; code(run(),'outcome_unknown'); assert(state.item and state.removed==0 and next(state.receipts)==nil)
end)
test('lost commit reply resolves by durable inspect without replacement',function()
    unknown=true; code(run(),'outcome_unknown'); assert(state.removed==1)
    unknown=false; assert(run('Inspect').value.state=='consumed' and run().value.replayed and state.removed==1)
end)
test('missing inspect never creates or infers a cancellation',function()
    code(run('Inspect'),'not_found'); assert(next(state.receipts)==nil and state.item)
end)
test('foreign inventory revision definition unique and archived refuse removal',function()
    for _,mutate in ipairs({function() state.item.inventoryId=8 end,function() state.item.revision=4 end,
        function() state.item.definition.name='other' end,function() state.item.definition.instanceMode='unique' end,
        function() state.item.definition.type='item_standard' end,function() archived=true end}) do
        reset(); mutate(); assert(not run().ok and state.item and state.removed==0 and next(state.receipts)==nil)
    end
end)
test('caller purpose item and payload bounds fail closed',function()
    code(run('Consume',nil,'other'),'authorization_denied')
    for _,patch in ipairs({{instanceId='5'},{instanceId=1.5},{expectedRevision=-1},{instanceId=9007199254740992},
        {operationId='bad'},{effectReference='x|y'},{sourceResource='bcc-stables'}}) do
        local r=request(); for k,v in pairs(patch) do r[k]=v end; code(run('Consume',r),'invalid_input')
    end
    local r=request(); r.itemName='other'; code(run('Consume',r),'authorization_denied')
    assert(state.removed==0)
end)
test('corrupt and incomplete receipts retained without mutation',function()
    assert(run('Cancel').ok); local row=state.receipts['bcc-stables|'..request().operationId]
    row.result_json='invalid'; code(run(),'receipt_invalid')
    row.result_json=nil; code(run(),'receipt_invalid'); code(run('Cancel'),'receipt_invalid'); code(run('Inspect'),'receipt_invalid')
    assert(state.item and state.removed==0)
end)
test('readiness false before successful schema start',function()
    dofile(root..'/server/services/consumption_once.lua')
    assert(not ConsumptionOnceAPI.Contract().ready); code(run(),'not_ready')
    local query=DB.query; DB.query=function() return {} end
    assert(not pcall(ConsumptionOnceAPI.Start) and not ConsumptionOnceAPI.Contract().ready)
    DB.query=query
end)
local function tool()
    local r=request();r.itemName='horsebrush';r.purpose='brush.v1';r.wear=1;r.maximumDurability=100
    Config.TrustedConsumptionCallers['bcc-stables']['brush.v1']={horsebrush=true}
    state.item.definition.name='horsebrush';state.item.definition.instanceMode='unique'
    return r
end
test('wear commits metadata and receipt once, preserving other metadata',function()
    local r=tool();state.item.metadata={condition=20,custom='keep'}
    local v=run('Wear',r);assert(v.ok and v.value.state=='used' and v.value.remainingDurability==19)
    assert(state.item.metadata.custom=='keep' and state.item.metadata.condition==19)
    assert(run('Wear',r).value.replayed and run('CancelWear',r).value.state=='used')
    assert(state.item.metadata.condition==19 and ConsumptionOnceAPI.Contract().durableWear==1)
end)
test('last tool use breaks exactly once and replays after instance deletion',function()
    local r=tool();state.item.metadata={condition=1}
    local v=run('Wear',r);assert(v.ok and v.value.broken and v.value.remainingDurability==0 and state.removed==1)
    dofile(root..'/server/services/consumption_once.lua');ConsumptionOnceAPI.Start()
    assert(run('InspectWear',r).value.broken and run('Wear',r).value.replayed and state.removed==1)
end)
test('cancelled wear cannot later mutate tool',function()
    local r=tool();assert(run('CancelWear',r).value.state=='cancelled')
    assert(run('Wear',r).value.state=='cancelled' and state.item.revision==3)
end)
test('wear receipt loss and rollback do not lose or repeat durability',function()
    local r=tool();failSave=true;code(run('Wear',r),'outcome_unknown');assert(not state.item.metadata and state.item.revision==3)
    failSave=false;unknown=true;code(run('Wear',r),'outcome_unknown');assert(state.item.metadata.condition==99)
    unknown=false;assert(run('InspectWear',r).value.remainingDurability==99)
    assert(run('Wear',r).value.replayed and state.item.metadata.condition==99)
end)
test('wear policy and action kind are immutable',function()
    local r=tool();assert(run('Wear',r).ok)
    r.wear=2;code(run('Wear',r),'receipt_conflict')
    r.wear=1;r.maximumDurability=101;code(run('CancelWear',r),'receipt_conflict')
    r=tool();r.wear=nil;r.maximumDurability=nil;code(run('Consume',r),'receipt_conflict')
end)
test('wear refuses exhausted invalid and guarded tools without a receipt',function()
    local r=tool();state.item.metadata={condition=0};code(run('Wear',r),'item_unavailable')
    state.item.metadata={condition=101};code(run('Wear',r),'item_unavailable')
    state.item.metadata={condition=30};blocked=true;code(run('Wear',r),'denied')
    assert(next(state.receipts)==nil and state.item.metadata.condition==30)
end)
test('disabled durability still has a durable non-mutating use receipt',function()
    local r=tool();r.wear=0;assert(run('Wear',r).value.remainingDurability==100)
    assert(state.item.revision==3 and state.item.metadata==nil and run('Wear',r).value.replayed)
end)
test('wear rejects malformed policy and corrupt saved result',function()
    local r=tool();r.wear=-1;code(run('Wear',r),'invalid_input')
    r.wear=1;assert(run('Wear',r).ok)
    local receipt=state.receipts['bcc-stables|'..r.operationId]
    local v=json.decode(receipt.result_json);v.remainingDurability=nil;receipt.result_json=json.encode(v)
    code(run('InspectWear',r),'receipt_invalid')
end)
test('wear follows Inventory configurable condition key and maximum',function()
    local r=tool();Config.Condition={Key='tool_condition',Max=100}
    state.item.metadata={tool_condition=40,durability=9}
    assert(run('Wear',r).value.remainingDurability==39)
    assert(state.item.metadata.tool_condition==39 and state.item.metadata.durability==9)
    assert(ConsumptionOnceAPI.Contract().conditionKey=='tool_condition')
    Config.Condition=nil
end)
print(('%s/%s receipt cases passed; wear MariaDB concurrency/restart acceptance pending.'):format(count,count))
