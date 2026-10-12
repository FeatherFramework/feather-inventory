-- Durable enrollment test; every query is confined to disposable fixture tables.
local fixtureId='00000000-0000-4000-8000-000000000002'
local prefix='[InvCharacterAmmoEnrollmentReplayTest] '
local operation='alpha-character-ammo-enrollment-v1'
local tables={'fi_ammo_enroll_receipts','fi_ammo_enroll_ledger','fi_ammo_enroll_items','fi_ammo_enroll_header'}
local function FixtureTx(real)
    local fixture={}
    function fixture.query(sql,params)
        local observationUpdate=sql=='UPDATE feather_character_ammunition SET pools = ?, revision = ? WHERE character_id = ? AND revision = ?'
        assert((observationUpdate and params[3]==fixtureId) or params[1]==fixtureId or tonumber(params[1])==1,'Only reserved enrollment fixture allowed')
        if sql=='SELECT id FROM inventory WHERE character_id = ? LIMIT 1 FOR UPDATE' then
            return real.query('SELECT id FROM fi_ammo_enroll_header WHERE character_id = ? FOR UPDATE',params)
        end
        if sql:find('FROM inventory_items ii INNER JOIN items i',1,true) then
            assert(#params==1 and tonumber(params[1])==1)
            return real.query('SELECT id, row_revision, metadata, name, type FROM fi_ammo_enroll_items WHERE character_id = ? ORDER BY id FOR UPDATE',{fixtureId})
        end
        local mapped
        if sql=='SELECT revision, pools FROM feather_character_ammunition WHERE character_id = ? FOR UPDATE'
            or sql=='INSERT INTO feather_character_ammunition (character_id, revision, pools) VALUES (?, 0, ?)'
            or observationUpdate then
            mapped=sql:gsub('feather_character_ammunition','fi_ammo_enroll_ledger')
        elseif sql=='SELECT result FROM feather_ammunition_operations WHERE character_id = ? AND operation_id = ? FOR UPDATE'
            or sql=='INSERT INTO feather_ammunition_operations (character_id, operation_id, result) VALUES (?, ?, ?)' then
            assert(params[2]==operation,'Reserved enrollment operation required')
            mapped=sql:gsub('feather_ammunition_operations','fi_ammo_enroll_receipts')
        end
        assert(mapped,'Unmapped production SQL rejected: '..sql)
        return real.query(mapped,params)
    end
    function fixture:SetMetadata(id,document,revision)
        assert(id==1 or id==12 or id==52 or id==53,'Only fixture item IDs')
        local updated=real.query([[UPDATE fi_ammo_enroll_items SET metadata=?, row_revision=row_revision+1
            WHERE character_id=? AND id=? AND row_revision=?]],{json.encode(document),fixtureId,id,revision})
        if not updated or tonumber(updated.affectedRows)~=1 then return Result.Err(Result.Codes.CONFLICT,'Fixture item revision changed.') end
        return Result.Ok({revision=revision+1})
    end
    return fixture
end
local function schema()
    DB.exec([[CREATE TABLE IF NOT EXISTS fi_ammo_enroll_header (
        character_id CHAR(36) NOT NULL PRIMARY KEY, id INT NOT NULL) ENGINE=InnoDB]])
    DB.exec([[CREATE TABLE IF NOT EXISTS fi_ammo_enroll_items (
        character_id CHAR(36) NOT NULL, id INT NOT NULL, name VARCHAR(100) NOT NULL,
        type VARCHAR(40) NOT NULL, row_revision BIGINT UNSIGNED NOT NULL,
        metadata LONGTEXT NOT NULL, original_metadata LONGTEXT NOT NULL,
        PRIMARY KEY(character_id,id)) ENGINE=InnoDB]])
    DB.exec([[CREATE TABLE IF NOT EXISTS fi_ammo_enroll_ledger (
        character_id CHAR(36) NOT NULL PRIMARY KEY, revision BIGINT UNSIGNED NOT NULL,
        pools LONGTEXT NOT NULL) ENGINE=InnoDB]])
    DB.exec([[CREATE TABLE IF NOT EXISTS fi_ammo_enroll_receipts (
        character_id CHAR(36) NOT NULL, operation_id VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        result LONGTEXT NOT NULL, PRIMARY KEY(character_id,operation_id)) ENGINE=InnoDB]])
end
local function catalog()
    local definitions,planner,limits=CharacterAmmoCutoverPreview.Load()
    return definitions,planner,limits
end
local function snapshot()
    local ledger=DB.one('SELECT revision, pools FROM fi_ammo_enroll_ledger WHERE character_id=?',fixtureId)
    local receipt=DB.one('SELECT result FROM fi_ammo_enroll_receipts WHERE character_id=? AND operation_id=?',fixtureId,operation)
    local items=DB.raw('SELECT id, row_revision, metadata, original_metadata FROM fi_ammo_enroll_items WHERE character_id=? ORDER BY id',fixtureId)
    local count=DB.value('SELECT COUNT(*) FROM fi_ammo_enroll_receipts WHERE character_id=?',fixtureId)
    return {ledger=ledger,receipt=receipt,items=items,receiptCount=tonumber(count)}
end
local function decode(value)
    local ok,result=pcall(json.decode,value or '')
    return ok and type(result)=='table' and result or nil
end
local function inspect(value,reduced)
    local pools=value.ledger and decode(value.ledger.pools)
    local exact=pools and pools.ammo_pistol_express==(reduced and 1 or 3) and pools.ammo_repeater_regular==8
        and pools.ammo_repeater_express==4 and tonumber(value.ledger.revision)==(reduced and 2 or 0) and #value.items==4
    if pools then
        for id,amount in pairs(pools) do
            if id~='ammo_pistol_express' and id~='ammo_repeater_regular' and id~='ammo_repeater_express' and amount~=0 then exact=false end
        end
    end
    local ownership,identity=true,true
    local revisions={}
    for _,row in ipairs(value.items) do
        local document,original=decode(row.metadata),decode(row.original_metadata)
        local ammo=document and document.ammo
        ownership=ownership and type(original)=='table' and type(original.ammo)=='table'
            and type(ammo)=='table' and ammo.ownership=='character'
            and ammo.type==original.ammo.type and ammo.pools==nil and ammo.loaded==nil and ammo.reserve==nil and ammo.clips==nil
        local expected=original and decode(row.original_metadata)
        if expected then expected.ammo={ownership='character',type=original.ammo.type} end
        identity=identity and document~=nil and InventoryMetadata.DocumentsEqual(document,expected)
            and tonumber(row.row_revision)==2
        revisions[tostring(row.id)]=2
    end
    local receipt=value.receipt and decode(value.receipt.result)
    local enrolledPools=pools and decode(value.ledger.pools)
    if enrolledPools and reduced then enrolledPools.ammo_pistol_express=3 end
    if enrolledPools and receipt and receipt.value and type(receipt.value.pools)=='table' then
        for id,count in pairs(enrolledPools) do
            if receipt.value.pools[id]==nil and count==0 then enrolledPools[id]=nil end
        end
    end
    local receiptValid=receipt and receipt.fingerprint==operation and type(receipt.value)=='table'
        and receipt.value.characterId==fixtureId and receipt.value.items==4 and receipt.value.revision==0
        and InventoryMetadata.DocumentsEqual(receipt.value.pools,enrolledPools)
        and InventoryMetadata.DocumentsEqual(receipt.value.itemRevisions,revisions) and value.receiptCount==1
    return {committedState=exact==true,ownershipCleared=ownership and #value.items==4,
        identityPreserved=identity and #value.items==4,receiptPersisted=receiptValid==true}
end
RegisterCommand('InvCharacterAmmoEnrollmentReplayTest',function(source,args)
    if source~=0 or not Config.DevMode then return end
    if GetResourceState('feather-weapons')~='stopped' then print(prefix..'BLOCKED: keep production Weapons stopped'); return end
    local mode=args and args[1]
    if mode~='prepare' and mode~='verify' and mode~='cleanup' and mode~='observe' and mode~='verifyobserve' then
        print(prefix..'Usage: prepare | verify | observe | verifyobserve | cleanup'); return
    end
    schema()
    if mode=='cleanup' then
        local removed=TransactionAPI.Transaction({reason='ammo_enrollment_fixture_cleanup'},function(tx)
            tx.query('SELECT id FROM fi_ammo_enroll_header WHERE character_id=? FOR UPDATE',{fixtureId})
            for _,name in ipairs(tables) do tx.query('DELETE FROM '..name..' WHERE character_id=?',{fixtureId}) end
            return Result.Ok(true)
        end)
        local remaining=0
        for _,name in ipairs(tables) do remaining=remaining+tonumber(DB.value('SELECT COUNT(*) FROM '..name..' WHERE character_id=?',fixtureId)) end
        print(prefix..'cleanup '..(removed.ok and remaining==0 and 'PASS' or 'FAIL')..'; disposable fixture rows removed, empty tables retained')
        return
    end
    local definitions,planner,limits=catalog()
    if mode=='prepare' then
        local committed=TransactionAPI.Transaction({reason='ammo_enrollment_fixture_prepare'},function(tx)
            for _,name in ipairs(tables) do
                if #tx.query('SELECT character_id FROM '..name..' WHERE character_id=? FOR UPDATE',{fixtureId})>0 then
                    return Result.Err(Result.Codes.CONFLICT,'Fixture already exists; preserve evidence, do not prepare twice.')
                end
            end
            tx.query('INSERT INTO fi_ammo_enroll_header (character_id,id) VALUES (?,1)',{fixtureId})
            local stock={
                {id=1,definition='pistol_m1899',type='ammo_pistol_express',loaded=3,reserve=0,pools={ammo_pistol_express=3}},
                {id=12,definition='pistol_semiauto',type='ammo_pistol_regular',loaded=0,reserve=0,pools={ammo_pistol_regular=0}},
                {id=52,definition='repeater_carbine',type='ammo_repeater_express',loaded=4,reserve=0,pools={ammo_repeater_regular=8,ammo_repeater_express=4}},
                {id=53,definition='repeater_lancaster',type='ammo_repeater_regular',loaded=0,reserve=0,pools={ammo_repeater_regular=0}}
            }
            for _,item in ipairs(stock) do
                local metadata=json.encode({weaponDefinitionId=item.definition,serial='FIXTURE-'..item.id,
                    condition={value=73},attachments={fixture='preserve'},cosmetics={fixture='preserve'},
                    ammo={type=item.type,loaded=item.loaded,reserve=item.reserve,pools=item.pools}})
                tx.query([[INSERT INTO fi_ammo_enroll_items (character_id,id,name,type,row_revision,metadata,original_metadata)
                    VALUES (?,?,?,'item_weapon',1,?,?)]],{fixtureId,item.id,definitions.weapons[item.definition].itemName,metadata,metadata})
            end
            return CharacterAmmoEnrollment.Apply(FixtureTx(tx),fixtureId,definitions,planner,limits)
        end)
        if not committed.ok then print(prefix..'prepare FAIL '..json.encode(committed)); return end
        local checks=inspect(snapshot())
        local good=checks.committedState and checks.ownershipCleared and checks.identityPreserved and checks.receiptPersisted
        print(prefix..'prepare '..(good and 'PASS' or 'FAIL')..'; fixture only: firearms4, pistol Express3, repeater Regular8/Express4, ledger revision0, receipt1')
        print(prefix..'Restart Inventory, then verify; no real character/inventory/native changes')
        return
    end
    if mode=='observe' then
        local before=snapshot(); local checks=inspect(before)
        if not (checks.committedState and checks.receiptPersisted) then
            print(prefix..'observe BLOCKED: intact prepared revision0 fixture required'); return
        end
        local committed=TransactionAPI.Transaction({reason='ammo_enrollment_fixture_observe'},function(tx)
            local pools=decode(before.ledger.pools)
            for id in pairs(limits) do if pools[id]==nil then pools[id]=0 end end
            local runtime=CharacterAmmoCutoverPreview.LoadRuntime().New(function() return true end)
            local report=assert(runtime.Open({source=1,characterId=fixtureId,sessionId='fixture'},
                {characterId=fixtureId,revision=0,pools=pools},limits,'fixture-observation'))
            report=assert(runtime.ConfirmRestore(1,report))
            for step=1,2 do
                pools.ammo_pistol_express=3-step
                report.pools=pools
                local request=assert((step==1 and runtime.PrepareObservation or runtime.PrepareFinalObservation)(1,report))
                local saved=CharacterAmmunitionAPI.ApplyObservation(FixtureTx(tx),request.context,request.spec)
                if not saved.ok then return saved end
                report=assert(runtime.Complete(request.context,saved))
            end
            assert(report.phase=='sealed' and report.revision==2,'Final reduction must seal only after accepted persistence')
            return Result.Ok(true)
        end)
        local after=inspect(snapshot(),true)
        print(prefix..'observe '..(committed.ok and after.committedState and after.receiptPersisted and 'PASS' or 'FAIL')..
            '; fixture only: pistol Express3->2->1, revision2; restart Inventory then verifyobserve')
        return
    end
    local before=snapshot()
    local checks=inspect(before,mode=='verifyobserve')
    local duplicate=TransactionAPI.Transaction({reason='ammo_enrollment_fixture_duplicate'},function(tx)
        return CharacterAmmoEnrollment.Apply(FixtureTx(tx),fixtureId,definitions,planner,limits)
    end)
    checks.duplicateRejected=not duplicate.ok and duplicate.error.code==Result.Codes.CONFLICT
        and InventoryMetadata.DocumentsEqual(before,snapshot())
    local names={'committedState','ownershipCleared','identityPreserved','receiptPersisted','duplicateRejected'}
    if mode=='verifyobserve' then
        local stale=TransactionAPI.Transaction({reason='ammo_enrollment_fixture_stale_observe'},function(tx)
            return CharacterAmmunitionAPI.ApplyObservation(FixtureTx(tx),{characterId=fixtureId},
                {expectedRevision=0,pools=decode(before.ledger.pools),limits=limits})
        end)
        checks.observationStaleRejected=not stale.ok and InventoryMetadata.DocumentsEqual(before,snapshot())
        names[#names+1]='observationStaleRejected'
    end
    local passed=0
    for _,name in ipairs(names) do
        if checks[name] then passed=passed+1 end
        print(prefix..name..' '..(checks[name] and 'PASS' or 'FAIL'))
    end
    print(prefix..('done %d/%d; dedicated fixture only, no real character/inventory/native changes'):format(passed,#names))
end,true)
return FixtureTx,inspect -- local tests only, never exported
