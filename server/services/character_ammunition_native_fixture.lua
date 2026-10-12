-- Development-only short-transaction ledger. Never maps production rows/items.
-- Losing this resource's local binding revokes authority; SQL evidence remains.
local fixtureId='00000000-0000-4000-8000-000000000003'
local bound
local function denied(code) return Result.Err(Result.Codes.DENIED,code) end
local function callable(v) return type(v)=='function' or type(v)=='table'
    and type(rawget(v,'__cfx_functionReference'))=='string' end
local function trusted()
    return Config.DevMode==true and GetInvokingResource()=='feather-weapons-native-proof'
        and GetResourceState('feather-weapons')=='stopped'
end
local function current(binding)
    if Config.DevMode~=true or GetResourceState('feather-weapons')~='stopped' or not binding or bound~=binding then return false end
    local ok,value=pcall(function()
        return exports['feather-core']:IsSessionCurrent(binding.source,binding.sessionId,binding.characterId)
    end)
    return ok and value==true
end
local function copy(value)
    if type(value)~='table' then return value end
    local out={}; for k,v in pairs(value) do out[k]=copy(v) end; return out
end
local function fixtureTx(tx)
    return {query=function(sql,params)
        if sql=='SELECT id FROM inventory WHERE character_id = ? LIMIT 1 FOR UPDATE' then
            assert(params[1]==fixtureId); return {{id=1}}
        end
        if sql=='SELECT revision, pools FROM feather_character_ammunition WHERE character_id = ? FOR UPDATE' then
            assert(params[1]==fixtureId)
            return tx.query('SELECT revision, pools FROM fi_ammo_native_ledger WHERE character_id=? FOR UPDATE',params)
        end
        if sql=='UPDATE feather_character_ammunition SET pools = ?, revision = ? WHERE character_id = ? AND revision = ?' then
            assert(params[3]==fixtureId)
            return tx.query('UPDATE fi_ammo_native_ledger SET pools=?, revision=? WHERE character_id=? AND revision=?',params)
        end
        error('Native fixture production SQL refused')
    end}
end
exports('BeginNativeAmmoFixture',function(identity,baseline,limits,validator,economy)
    if not trusted() or bound or type(identity)~='table' or type(baseline)~='table'
        or not callable(validator) then return denied('fixture_begin_denied') end
    identity,baseline,limits,economy=copy(identity),copy(baseline),copy(limits),copy(economy)
    if economy and (type(economy)~='table' or type(economy.ammunitionId)~='string'
        or type(limits)~='table' or not limits[economy.ammunitionId] or economy.loose~=1) then
        return denied('fixture_economy_invalid')
    end
    local candidate=copy(identity)
    if type(candidate.source)~='number' or candidate.source<1 or candidate.source%1~=0 or candidate.source==math.huge
        or type(candidate.characterId)~='string'
        or type(candidate.sessionId)~='string' or type(candidate.epoch)~='string'
        or candidate.epoch=='' or baseline.characterId~=candidate.characterId
        or type(baseline.revision)~='number' or baseline.revision<0 or baseline.revision%1~=0
        or baseline.revision==math.huge then return denied('fixture_identity_invalid') end
    local _,_,approved=CharacterAmmoCutoverPreview.Load()
    if not InventoryMetadata.DocumentsEqual(limits,approved) then return denied('fixture_policy_mismatch') end
    local pools=baseline.pools
    if type(pools)~='table' then return denied('fixture_pools_invalid') end
    for id,cap in pairs(approved) do
        local n=pools[id]
        if type(n)~='number' or n<0 or n>cap or n%1~=0 then return denied('fixture_pools_invalid') end
    end
    for id in pairs(pools) do if approved[id]==nil then return denied('fixture_pools_invalid') end end
    candidate.validator=validator; candidate.limits=copy(approved); candidate.economy=economy; bound=candidate
    if not current(candidate) then bound=nil; return denied('fixture_context_changed') end
    DB.exec([[CREATE TABLE IF NOT EXISTS fi_ammo_native_ledger (
        character_id CHAR(36) NOT NULL PRIMARY KEY, revision BIGINT UNSIGNED NOT NULL,
        pools LONGTEXT NOT NULL) ENGINE=InnoDB]])
    if economy then
        DB.exec([[CREATE TABLE IF NOT EXISTS fi_ammo_native_economy (
            character_id CHAR(36) NOT NULL PRIMARY KEY, ammunition_id VARCHAR(64) NOT NULL,
            loose INT UNSIGNED NOT NULL, receipts LONGTEXT NOT NULL) ENGINE=InnoDB]])
    end
    local result=TransactionAPI.Transaction({reason='native_ammo_fixture_begin'},function(tx)
        if not current(candidate) then return denied('fixture_context_changed') end
        local rows=tx.query('SELECT revision, pools FROM fi_ammo_native_ledger WHERE character_id=? FOR UPDATE',{fixtureId})
        if #rows>0 then return denied('fixture_evidence_exists_cleanup_required') end
        if economy then
            local old=tx.query('SELECT ammunition_id, loose, receipts FROM fi_ammo_native_economy WHERE character_id=? FOR UPDATE',{fixtureId})
            if #old>0 then return denied('fixture_evidence_exists_cleanup_required') end
            tx.query('INSERT INTO fi_ammo_native_economy (character_id,ammunition_id,loose,receipts) VALUES (?,?,?,?)',
                {fixtureId,economy.ammunitionId,1,json.encode({})})
        end
        tx.query('INSERT INTO fi_ammo_native_ledger (character_id,revision,pools) VALUES (?,?,?)',
            {fixtureId,baseline.revision,json.encode(pools)})
        if not current(candidate) then return denied('fixture_context_changed') end
        return Result.Ok(true)
    end)
    if not result.ok then bound=nil end
    return result
end)
exports('TransferNativeAmmoFixture',function(context,spec)
    if not trusted() then return denied('fixture_transfer_denied') end
    context,spec=copy(context),copy(spec)
    local binding=bound
    local function authorized()
        if not (current(binding) and binding.economy and type(context)=='table'
            and context.actorSource==binding.source and context.characterId==binding.characterId
            and context.sessionId==binding.sessionId and context.runtimeEpoch==binding.epoch
            and type(spec)=='table' and spec.ammunitionId==binding.economy.ammunitionId
            and (spec.amount==1 or spec.amount==-1)
            and InventoryMetadata.DocumentsEqual(spec.limits,binding.limits)) then return false end
        local ok,value=pcall(binding.validator,context,'transfer',spec)
        return ok and value==true
    end
    if not authorized() then return denied('fixture_transfer_denied') end
    return TransactionAPI.Transaction({reason='native_ammo_fixture_transfer'},function(tx)
        if not authorized() then return denied('fixture_context_changed') end
        local rows=tx.query('SELECT ammunition_id, loose, receipts FROM fi_ammo_native_economy WHERE character_id=? FOR UPDATE',{fixtureId})
        local row=rows[1]
        if not row or row.ammunition_id~=spec.ammunitionId then return denied('fixture_economy_missing') end
        local ok,receipts=pcall(json.decode,row.receipts)
        local loose=tonumber(row.loose)
        if not ok or type(receipts)~='table' or (loose~=0 and loose~=1) then return denied('fixture_economy_corrupt') end
        local adapter=fixtureTx(tx)
        local ledgerQuery=adapter.query
        adapter.query=function(sql,p)
            if sql=='SELECT id, type, instance_mode, archived_at FROM items WHERE name = ? LIMIT 1' then
                assert(p[1]==spec.ammunitionId); return {{id=1,type='item_ammo',instance_mode='stack'}}
            end
            if sql=='SELECT result FROM feather_ammunition_operations WHERE character_id = ? AND operation_id = ? FOR UPDATE' then
                assert(p[1]==fixtureId); return receipts[p[2]] and {{result=receipts[p[2]]}} or {}
            end
            if sql=='INSERT INTO feather_ammunition_operations (character_id, operation_id, result) VALUES (?, ?, ?)' then
                assert(p[1]==fixtureId and not receipts[p[2]]); receipts[p[2]]=p[3]; return {affectedRows=1}
            end
            return ledgerQuery(sql,p)
        end
        adapter.RequireAccess=function(_,id) assert(id==1); return nil end
        adapter.RemoveQuantity=function(_,inventory,item,amount)
            assert(inventory==1 and item==1 and amount==1)
            if loose<amount then return denied('fixture_loose_exhausted') end
            loose=loose-amount; return Result.Ok(true)
        end
        adapter.AddQuantity=function(_,inventory,item,amount)
            assert(inventory==1 and item==1 and amount==1)
            if loose+amount>1 then return denied('fixture_loose_capacity') end
            loose=loose+amount; return Result.Ok(true)
        end
        local result=CharacterAmmunitionAPI.Apply(adapter,{characterId=fixtureId},spec)
        if not result.ok then return result end
        local written=tx.query('UPDATE fi_ammo_native_economy SET loose=?, receipts=? WHERE character_id=?',
            {loose,json.encode(receipts),fixtureId})
        if not written or tonumber(written.affectedRows)~=1 then return denied('fixture_economy_write_failed') end
        if not authorized() then return denied('fixture_context_changed') end
        result.value.characterId=binding.characterId
        return result
    end)
end)
exports('ObserveNativeAmmoFixture',function(context,spec)
    if not trusted() then return denied('fixture_observation_denied') end
    context,spec=copy(context),copy(spec)
    local binding=bound
    local function authorized()
        if not (current(binding) and type(context)=='table' and context.actorSource==binding.source
            and context.characterId==binding.characterId and context.sessionId==binding.sessionId
            and context.runtimeEpoch==binding.epoch and type(spec)=='table'
            and type(spec.limits)=='table' and InventoryMetadata.DocumentsEqual(spec.limits,binding.limits)) then return false end
        local ok,value=pcall(binding.validator,context,'observe',spec)
        return ok and value==true
    end
    if not authorized() then return denied('fixture_observation_denied') end
    local safeSpec=copy(spec)
    return TransactionAPI.Transaction({reason='native_ammo_fixture_observe'},function(tx)
        if not authorized() then return denied('fixture_context_changed') end
        local result=CharacterAmmunitionAPI.ApplyObservation(fixtureTx(tx),{characterId=fixtureId},safeSpec)
        if not authorized() then return denied('fixture_context_changed') end
        if result.ok then result.value.characterId=binding.characterId end
        return result
    end)
end)
exports('ReleaseNativeAmmoFixture',function()
    if not trusted() then return denied('fixture_release_denied') end
    bound=nil; return Result.Ok(true) -- evidence is deliberately NOT deleted
end)
RegisterCommand('InvNativeAmmoFixture',function(source,args)
    if source~=0 or Config.DevMode~=true then return end
    if bound then print('[InvNativeAmmoFixture] BLOCKED: active binding; release proof first'); return end
    local mode=args and args[1]
    if mode=='cleanup' then
        local result=TransactionAPI.Transaction({reason='native_ammo_fixture_cleanup'},function(tx)
            tx.query('DELETE FROM fi_ammo_native_ledger WHERE character_id=?',{fixtureId})
            -- Older observation fixtures may predate the optional economy table.
            local exists=tx.query("SHOW TABLES LIKE 'fi_ammo_native_economy'",{})
            if #exists>0 then tx.query('DELETE FROM fi_ammo_native_economy WHERE character_id=?',{fixtureId}) end
            return Result.Ok(true)
        end)
        print('[InvNativeAmmoFixture] cleanup '..(result.ok and 'PASS' or 'FAIL')..'; fixture rows only')
    elseif mode=='status' then
        local row=DB.one('SELECT revision, pools FROM fi_ammo_native_ledger WHERE character_id=?',fixtureId)
        if row then
            local ok,pools=pcall(json.decode,row.pools)
            row={revision=tonumber(row.revision),pools=ok and pools or 'invalid_fixture_document'}
        end
        local exists=DB.one("SHOW TABLES LIKE 'fi_ammo_native_economy'")
        local ok,economy=true,nil
        if exists then ok,economy=pcall(DB.one,'SELECT ammunition_id, loose, receipts FROM fi_ammo_native_economy WHERE character_id=?',fixtureId) end
        if ok and economy and row then
            local decoded,receipts=pcall(json.decode,economy.receipts)
            row.economy={ammunitionId=economy.ammunition_id,loose=tonumber(economy.loose),receipts=decoded and receipts or 'invalid'}
        end
        print('[InvNativeAmmoFixture] evidence '..json.encode(row or {}))
    else print('[InvNativeAmmoFixture] Usage: status | cleanup') end
end,true)
AddEventHandler('onResourceStop',function(resource)
    if resource=='feather-weapons-native-proof' then bound=nil end -- revoke, preserve evidence
end)
