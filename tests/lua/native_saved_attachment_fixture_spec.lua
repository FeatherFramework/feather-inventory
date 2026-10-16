Config={}
Result={Ok=function(v) return {ok=true,value=v} end,Err=function(c,m) return {ok=false,error={code=c,message=m}} end}
RegisterCommand=function() end
dofile('server/services/native_repair_fixture.lua')
local active,equipped,writes=true,false,0
local meta={weaponDefinitionId='repeater_carbine',serialNumber='FW-ALPHA-MIXED-JANE-V1-repeater_carbine',condition=100,
    attachments={},maintenance={damage=0,degradation=0,permanentDegradation=0,dirt=0,soot=0}}
local item={inventoryId=2,revision=0,definition={name='weapon_repeater_carbine'},metadata=meta}
local tx={query=function(sql)
    if sql:find('FROM inventory WHERE',1,true) then return {{id=2}} end
    if sql:find('character_equipment',1,true) then return equipped and {{inventory_items_id=135}} or {} end
    error('fixture must not write economic/equipment tables: '..sql)
end}
function tx:GetItemForUpdate(id) assert(id==135); return Result.Ok(item) end
function tx:SetMetadata(id,document,revision)
    assert(id==135 and revision==item.revision)
    writes=writes+1; item.metadata=document; item.revision=item.revision+1
    return Result.Ok({})
end
local contract={Validate=function() return true end}
local function run(mode) return NativeSavedAttachmentFixture.Apply(tx,function() return active end,mode,contract,{}) end
equipped=true; assert(not run('install').ok and writes==0); equipped=false
active=false; assert(not run('install').ok and writes==0); active=true
assert(run('install').ok and writes==1 and item.revision==1 and meta.attachments[1]==nil)
assert(run('install').value.unchanged and writes==1,'idempotent install never repeats metadata write')
assert(run('remove').ok and writes==2 and item.revision==2 and next(item.metadata.attachments)==nil)
assert(run('remove').value.unchanged and writes==2)
assert(not run('install').ok and writes==2,'one fixture cycle, no repeated revision churn')
item.metadata.serialNumber='foreign'; assert(not run('remove').ok and writes==2)
print('saved attachment fixture PASS (fixed135 serial/pristine/unequipped, CAS one-cycle/replay, metadata-only, unknown refusal)')
