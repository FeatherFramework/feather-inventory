local function copy(v)
    if type(v)~='table' then return v end
    local r={}; for k,x in pairs(v) do r[k]=copy(x) end; return r
end
local documents,n={},0
json={encode=function(v) n=n+1; documents[tostring(n)]=copy(v); return tostring(n) end,
    decode=function(v) assert(documents[v]); return copy(documents[v]) end}
Result={Codes={CONFLICT='conflict',DENIED='denied'},Ok=function(v) return {ok=true,value=v} end,
    Err=function(c,m) return {ok=false,error={code=c,message=m}} end,IsOk=function(v) return v and v.ok end}
InventoryIdentity={NormalizeCharacterId=function(id) return id=='char' and id end}
local command
RegisterCommand=function(_,fn) command=fn end
Config={DevMode=true}
GuardsAPI={HasRegisteredGuard=function() return false end}
GetResourceState=function() return 'stopped' end
exports={['feather-core']={IsSessionCurrent=function() return true end}}
dofile('server/helpers/metadata_compatibility.lua')
dofile('../feather-weapons/shared/ammunition_migration_preview.lua')
dofile('server/services/character_ammunition.lua')
dofile('server/services/character_ammunition_enrollment.lua')
local catalog={weapons={gun={id='gun',itemName='weapon_gun',family='repeater',capacity=7,
    ammunitionType='ammo_repeater_regular',ammunitionTypes={'ammo_repeater_regular','ammo_repeater_express'}}},
    ammunition={ammo_repeater_regular={nativeAmmoName='AMMO_REPEATER'},ammo_repeater_express={nativeAmmoName='AMMO_REPEATER_EXPRESS'}}}
local limits={ammo_repeater_regular=200,ammo_repeater_express=200}
local original={weaponDefinitionId='gun',serial='keep',condition={value=73},attachments={sight='keep'},
    ammo={type='ammo_repeater_regular',loaded=7,reserve=1,pools={ammo_repeater_regular=8,ammo_repeater_express=4}}}
local database,writeFail,receiptFail,ledgerFail
local function reset()
    database={rows={{id=1,name='weapon_gun',type='item_weapon',row_revision=12,metadata=json.encode(original)}},ledger=nil,receipt=nil,operations={},loose=0}
    writeFail,receiptFail,ledgerFail=false,false,false
end
local tx={}
function tx.query(sql,p)
    if sql:find('SELECT id FROM inventory',1,true) then return {{id=7}} end
    if sql:find('SELECT revision, pools',1,true) then return database.ledger and {copy(database.ledger)} or {} end
    if sql:find('SELECT result FROM',1,true) then
        local receipt=p[2]=='alpha-character-ammo-enrollment-v1' and database.receipt or database.operations[p[2]]
        return receipt and {{result=receipt}} or {}
    end
    if sql:find('SELECT id, type, instance_mode',1,true) then return {{id=9,type='item_ammo',instance_mode='stack'}} end
    if sql:find('UPDATE feather_character_ammunition',1,true) then
        assert(database.ledger.revision==p[4]); database.ledger={pools=p[1],revision=p[2]}; return {affectedRows=1}
    end
    if sql:find('FROM character_equipment',1,true) then
        local row=copy(database.rows[1]); row.equipped_slot='weapon'; row.itemName=row.name; row.owner_character='char'
        return {row}
    end
    if sql:find('FROM inventory_items',1,true) then return copy(database.rows) end
    if sql:find('INSERT INTO feather_character',1,true) then
        if ledgerFail then return {affectedRows=0} end
        database.ledger={revision=0,pools=p[2]}; return {affectedRows=1}
    end
    if sql:find('INSERT INTO feather_ammunition',1,true) then
        if receiptFail then return {affectedRows=0} end
        if p[2]=='alpha-character-ammo-enrollment-v1' then database.receipt=p[3] else database.operations[p[2]]=p[3] end
        return {affectedRows=1}
    end
    error(sql)
end
function tx:SetMetadata(id,document,revision)
    assert(id==1 and revision==database.rows[1].row_revision)
    if writeFail then return Result.Err('conflict','injected') end
    database.rows[1].metadata=json.encode(document); database.rows[1].row_revision=revision+1
    return Result.Ok({revision=revision+1})
end
function tx:GetItemForUpdate()
    local row=database.rows[1]
    return Result.Ok({metadata=json.decode(row.metadata),revision=row.row_revision})
end
InventoryAPI={AccessModes={REMOVE='remove',INSERT='insert'}}
function tx:RequireAccess() return nil end
function tx:AddQuantity(_,_,amount) database.loose=database.loose+amount; return Result.Ok(true) end
function tx:RemoveQuantity(_,_,amount) assert(database.loose>=amount); database.loose=database.loose-amount; return Result.Ok(true) end
function tx:GetQuantity() return database.loose end
InventoryControllers={GetInventoryByCharacter=function() return 7 end,InventoryItemCount=function() return database.loose end}
ItemControllers={GetItemDefinitionByName=function() return {id=9} end}
TransactionAPI={Transaction=function(_,body)
    local before=copy(database)
    local ok,result=pcall(body,tx)
    if not ok or not result.ok then database=before end
    return ok and result or Result.Err('exception',tostring(result))
end}
local function apply(rollback)
    return TransactionAPI.Transaction({},function(t)
        local result=CharacterAmmoEnrollment.Apply(t,'char',catalog,WeaponAmmoMigrationPreview,limits)
        if result.ok and rollback then return Result.Err('denied','forced') end
        return result
    end)
end
reset(); local result=apply(); assert(result.ok and result.value.pools.ammo_repeater_regular==8 and result.value.pools.ammo_repeater_express==4)
local migrated=json.decode(database.rows[1].metadata)
assert(migrated.serial=='keep' and migrated.condition.value==73 and migrated.attachments.sight=='keep')
assert(migrated.ammo.ownership=='character' and migrated.ammo.type=='ammo_repeater_regular' and migrated.ammo.pools==nil and migrated.ammo.loaded==nil)
assert(database.rows[1].row_revision==13 and database.ledger and database.receipt)
assert(not apply().ok and database.rows[1].row_revision==13,'duplicate cannot credit again')
for _,failure in ipairs({'metadata','receipt','ledger','rollback','invalid'}) do
    reset(); local before=copy(database)
    if failure=='metadata' then writeFail=true elseif failure=='receipt' then receiptFail=true elseif failure=='ledger' then ledgerFail=true
    elseif failure=='invalid' then local bad=copy(original); bad.ammo.pools.ammo_repeater_regular=9; database.rows[1].metadata=json.encode(bad); before=copy(database) end
    assert(not apply(failure=='rollback').ok)
    assert(InventoryMetadata.DocumentsEqual(before,database),'all writes rolled back: '..failure)
end
-- Exercise the real console wrapper, including DB readback, not just Apply.
reset()
InventoryIdentity.GetSession=function() return {ok=true,value={characterId='char',sessionId='session'}} end
CharacterAmmoCutoverPreview={Load=function() return catalog,WeaponAmmoMigrationPreview,limits end}
CharacterAmmoNativePreview={Load=function() return catalog,{Build=function()
    local complete=copy(limits); complete.ammo_unused=100
    return {limits=complete}
end},
    {Loadout=function(rows)
        local row=rows.primary
        local metadata=row.metadata
        assert(metadata.ammo.ownership=='character' and metadata.ammo.loaded==nil and metadata.ammo.pools==nil)
        return {slots={primary={itemInstanceId=row.id,itemRevision=row.revision}}}
    end}, {Build=function(rows) return {rows=rows} end}, {New=function(plan)
        local revision=plan.rows.primary.revision
        return {Contains=function(id) return id==1 end,Validate=function(snapshot)
            return snapshot.equipment.primary.revision==revision
        end}
    end} end}
DB={raw=function() return copy(database.rows) end,one=function() return nil end}
local output={}; print=function(s) output[#output+1]=s end
command(0,{'1'})
local found=false; for _,line in ipairs(output) do if line:find('done 8/8',1,true) then found=true end end
assert(found,'console rollback gate must pass all checks')
assert(database.ledger==nil and database.receipt==nil and database.rows[1].row_revision==12)
io.write('character ammo enrollment PASS (atomic rollback, failure injection, console wrapper)\n')
-- Exercise optional bridge wrapper with CFX-shaped service methods. The exact
-- sandboxed server service itself is covered by proof inventory_loadout_fixture_spec.
local function callable(fn) return setmetatable({__cfx_functionReference='mock'}, {__call=function(_,...) return fn(...) end}) end
exports['feather-weapons-native-proof']={CreateInventoryLoadoutFixture=function(_,identity,current,read,_,mutate,observe)
    assert(current(1,'session','char'))
    local held=false; local report; local opening
    local function observation(baseline)
        if baseline.revision~=report.revision then return Result.Err('stale','stale') end
        local changed=false
        for id,count in pairs(report.pools) do
            if baseline.pools[id]>count then return Result.Err('increase','increase') end
            changed=changed or baseline.pools[id]~=count
        end
        if not changed then return Result.Ok(copy(report)) end
        local saved=observe({actorSource=1,characterId='char',sessionId='session',runtimeTicket='issued'},
            {expectedRevision=baseline.revision,pools=baseline.pools,
                limits={ammo_repeater_regular=200,ammo_repeater_express=200,ammo_unused=100}})
        if saved.ok then report=copy(saved.value); report.phase='active' end
        return saved.ok and Result.Ok(copy(report)) or saved
    end
    return {OpenLoadout=callable(function(_,_,policy)
        if opening then return Result.Err('open_in_flight','overlap') end
        local reservation={}; opening=reservation
        local snapshot=read({ammo_repeater_regular=200,ammo_repeater_express=200,ammo_unused=100}); assert(snapshot.ok)
        if opening~=reservation then return Result.Err('open_context_changed','cancelled') end
        opening=nil
        held=true; report={characterId='char',revision=snapshot.value.revision,pools=snapshot.value.pools,phase='restoring'}
        return Result.Ok({runtime=report,creation={items={{itemInstanceId=1}}}})
    end),ConfirmRestore=callable(function() report.phase='active'; return Result.Ok(report) end),
    Observe=callable(function(_,baseline) return observation(baseline) end),
    CheckpointAndSeal=callable(function(_,baseline)
        if observe then local saved=observation(baseline); if not saved.ok then return saved end end
        report.phase='sealed'; return Result.Ok(report)
    end),
    ConfirmCleanup=callable(function() held=false; return Result.Ok(report) end),
    IsNativeItemBound=callable(function() return held end),
    Transfer=callable(function(_,baseline,id,amount,operationId)
        local caps={ammo_repeater_regular=200,ammo_repeater_express=200,ammo_unused=100}
        local snapshot=read(caps)
        if operationId=='fixture-stale-load' then
            assert(snapshot.value.equipment.primary.revision==14)
            return Result.Err('lease_changed','fixture changed')
        end
        assert(snapshot.value.equipment.primary.revision==13)
        if baseline.phase~='active' then return Result.Err('not_idle','restore required') end
        local saved=mutate({actorSource=1,characterId='char',sessionId='session',runtimeTicket='issued'},
            {ammunitionId=id,amount=amount,operationId=operationId,expectedRevision=baseline.revision,limits=caps})
        if not saved.ok then return saved end
        report=copy(saved.value); report.phase='restoring'; return Result.Ok(report)
    end),Revoke=callable(function() held=false; opening=nil end)}
end}
GetResourceState=function(name) return name=='feather-weapons-native-proof' and 'started' or 'stopped' end
reset(); output={}; command(0,{'1','service'})
found=false; for _,line in ipairs(output) do if line:find('done 15/15',1,true) then found=true end end
assert(found,'optional CFX service rollback wrapper must pass15/15: '..table.concat(output,'\n'))
assert(database.ledger==nil and database.receipt==nil and database.rows[1].row_revision==12)
io.write('enrollment service bridge wrapper PASS15/15 (CFX-shaped callbacks, rollback)\n')
reset(); output={}; command(0,{'1','service','transfer'})
found=false; for _,line in ipairs(output) do if line:find('done 21/21',1,true) then found=true end end
assert(found,'service economic bridge wrapper must pass21/21: '..table.concat(output,'\n'))
assert(database.ledger==nil and database.receipt==nil and database.loose==0 and next(database.operations)==nil)
io.write('enrollment service economic bridge PASS21/21 (real Inventory Apply, mocked SQL/CFX, full rollback)\n')
reset(); output={}; command(0,{'1','service','observe'})
found=false; for _,line in ipairs(output) do if line:find('done 22/22',1,true) then found=true end end
assert(found,'service observation bridge wrapper must pass22/22: '..table.concat(output,'\n'))
assert(database.ledger==nil and database.receipt==nil and database.rows[1].row_revision==12)
io.write('enrollment service observation bridge PASS22/22 (real Inventory ApplyObservation, mocked SQL/CFX, rollback)\n')
