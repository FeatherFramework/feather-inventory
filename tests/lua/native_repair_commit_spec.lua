Result={Err=function(code,message) return {ok=false,error={code=code,message=message}} end,
    Ok=function(value) return {ok=true,value=value} end}
dofile('server/services/native_repair_commit.lua')
local function copy(v)
    if type(v)~='table' then return v end
    local out={}; for k,x in pairs(v) do out[k]=copy(x) end; return out
end
local before={condition=50,maintenance={dirt=1},serialNumber='serial',ammo={ownership='character',type='regular'}}
local after=copy(before); after.condition=100; after.maintenance.dirt=0
local spec={characterId='jane',itemId=112,itemRevision=1,before=before,after=after,expected={},
    material={definitionId=9,itemName='gun_oil',quantity=1}}
local function run(options)
    options=options or {}
    local state={material=1,metadata=copy(before)}
    local staged=copy(state)
    local active=true
    local tx={}
    local function boundary(name) if options.expire==name then active=false end end
    function tx.query(sql)
        if sql:find('SELECT slot, inventory_items_id',1,true) then
            boundary('finalEquipment')
            return options.assigned and not options.equipmentLost and {{slot='weapon',inventory_items_id=112}} or {}
        end
        if sql:find('FROM character_equipment',1,true) then
            boundary('equipment'); return (options.equipmentChanged or options.assigned) and {{slot='weapon',inventory_items_id=112,row_revision=1,owner_character='jane'}} or {}
        end
        if sql:find('FROM inventory ',1,true) then boundary('header'); return {{id=4}} end
        boundary('definition'); return {{id=9,name=options.badMaterial and 'wrong' or 'gun_oil'}}
    end
    function tx:GetItemForUpdate(id)
        assert(id==112); boundary('item')
        return Result.Ok({inventoryId=options.wrongOwner and 5 or 4,
            revision=options.stale and 2 or 1,metadata=copy(before)})
    end
    function tx:RemoveQuantity(inventory,id,quantity)
        assert(inventory==4 and id==9 and quantity==1)
        boundary('remove')
        if options.missing then return Result.Err('missing','No material') end
        staged.material=0; return Result.Ok({99})
    end
    function tx:SetMetadata(id,metadata,revision)
        assert(id==112 and revision==1); boundary('write')
        if options.cas then return Result.Err('conflict','CAS failed') end
        staged.metadata=copy(metadata); return Result.Ok({})
    end
    local intent=copy(spec)
    if options.observing then
        intent.action='maintenance'; intent.material=nil
        intent.after.condition=40; intent.after.maintenance.dirt=1
    end
    if options.heal then intent.after.condition=60 end
    if options.assigned then intent.expected={weapon={itemId=112,revision=1}} end
    if options.changeAmmo then intent.after.ammo.type='express' end
    local result=NativeRepairCommit.Apply(tx,intent,function() return active end)
    -- Same commit/refusal rule as Inventory transaction ownership; not a SQL integration test.
    if result.ok then state=staged end
    if options.success then
        assert(result.ok and state.material==(options.observing and 1 or 0)
            and state.metadata.condition==(options.observing and 40 or 100))
        assert(state.metadata.ammo.type=='regular' and state.metadata.serialNumber=='serial')
    else
        assert(not result.ok and state.material==1 and state.metadata.condition==50)
    end
end
run({success=true})
for _,boundary in ipairs({'header','equipment','item','definition','remove','write','finalEquipment'}) do run({expire=boundary}) end
run({assigned=true,success=true})
run({assigned=true,equipmentLost=true})
-- Complete maintenance shape required for monotonic wear validation.
for _,key in ipairs({'degradation','permanentDegradation','damage','soot'}) do
    before.maintenance[key]=0; spec.before.maintenance[key]=0; spec.after.maintenance[key]=0
end
run({observing=true,assigned=true,success=true})
run({observing=true,heal=true})
for _,failure in ipairs({'wrongOwner','stale','badMaterial','missing','cas','changeAmmo','equipmentChanged'}) do run({[failure]=true}) end
assert(before.condition==50 and before.maintenance.dirt==1)
print('native_repair_commit_spec PASS (owned revision, reserved authority boundaries, payment/CAS rollback contract, ammo preservation; mocked transaction)')
