-- Console-only rollback gate. No equipment, ammunition or native mutations.
local running=false
local function callable(value)
    return type(value)=='function' or type(value)=='table' and type(rawget(value,'__cfx_functionReference'))=='string'
end
local function Run(source,args,provider)
    if source~=0 or not Config.DevMode or running then return end
    local prefix=provider and '[InvInstanceChangeGuardCFXSmokeTest] ' or '[InvInstanceChangeGuardSmokeTest] '
    if GetResourceState('feather-weapons')~='stopped' or GuardsAPI.HasRegisteredGuard('feather-weapons') then
        print(prefix..'BLOCKED: keep Weapons stopped; restart Inventory to clear retained Weapons guards'); return
    end
    local target=tonumber(args and args[1])
    local session=target and InventoryIdentity.GetSession(target)
    if not session or not session.ok then print(prefix..'BLOCKED: connected character required'); return end
    running=true
    local name='feather-inventory:instance-change-smoke'
    local checks,before={},nil
    local ok,err=pcall(function()
        local result=TransactionAPI.Transaction({resource='feather-inventory',reason='instance_change_guard_rollback_smoke'},function(tx)
            local character=session.value.characterId
            if exports['feather-core']:IsSessionCurrent(target,session.value.sessionId,character)~=true then
                return Result.Err(Result.Codes.DENIED,'Session changed.')
            end
            tx.query('SELECT id FROM inventory WHERE character_id=? LIMIT 1 FOR UPDATE',{character})
            local rows=tx.query([[SELECT ii.id, ii.row_revision, ii.metadata FROM inventory_items ii
                INNER JOIN inventory inv ON inv.id=ii.inventory_id
                INNER JOIN character_equipment ce ON ce.inventory_items_id=ii.id AND ce.character_id=inv.character_id
                WHERE inv.character_id=? ORDER BY ii.id FOR UPDATE]],{character})
            before=rows and rows[1]
            if not before then return Result.Err(Result.Codes.NOT_FOUND,'Equipped fixture item required.') end
            local item=tx:GetItemForUpdate(tonumber(before.id))
            if not item.ok then return item end
            local guard,release
            if provider then
                local binding=provider.Bind(tonumber(before.id))
                assert(type(binding)=='table' and callable(binding.guard) and callable(binding.release),'Invalid guard provider')
                guard,release=binding.guard,binding.release
            else
                local active=true
                guard=function(instance,context)
                if instance.id==tonumber(before.id) then
                    return not active,'smoke native lifetime hold'
                end
                return true
                end
                release=function() active=false; return true end
            end
            local held=GuardsAPI.RegisterInstanceChangeGuard(name,guard)
            local move=GuardsAPI.RegisterMoveGuard(name,guard)
            local destroy=GuardsAPI.RegisterDestroyGuard(name,guard)
            checks.registered=held.ok and move.ok and destroy.ok and GuardsAPI.HasRegisteredGuard(name)
            checks.moveVeto=GuardsAPI.CanMoveInstanceSnapshot(item.value,{operation='move_probe'})==false
            checks.destroyVeto=GuardsAPI.CanDestroyInstanceSnapshot(item.value,{operation='destroy_probe'})==false
            local denied=tx:SetMetadata(item.value.id,item.value.metadata,item.value.revision)
            checks.metadataVeto=not denied.ok and denied.error.code==Result.Codes.DENIED
            assert(release()==true,'Guard release failed')
            checks.releasedMove=GuardsAPI.CanMoveInstanceSnapshot(item.value,{operation='move_probe'})==true
            checks.releasedDestroy=GuardsAPI.CanDestroyInstanceSnapshot(item.value,{operation='destroy_probe'})==true
            local accepted=tx:SetMetadata(item.value.id,item.value.metadata,item.value.revision)
            checks.releasedWrite=accepted.ok and accepted.value.revision==item.value.revision+1
            return Result.Err(Result.Codes.DENIED,'instance-change-smoke-intentional-rollback')
        end)
        if not before or not result.error or result.error.message~='instance-change-smoke-intentional-rollback' then
            error(result.error and result.error.message or 'rollback not reached')
        end
        local after=DB.query('SELECT id, row_revision, metadata FROM inventory_items WHERE id=? LIMIT 1',before.id)[1]
        checks.rollback=after and tonumber(after.row_revision)==tonumber(before.row_revision)
            and InventoryMetadata.DocumentsEqual(InventoryMetadata.Decode(after.metadata),InventoryMetadata.Decode(before.metadata))
    end)
    GuardsAPI.UnregisterInstanceChangeGuard(name)
    GuardsAPI.UnregisterMoveGuard(name); GuardsAPI.UnregisterDestroyGuard(name); running=false
    local passed=0
    for _,label in ipairs({'registered','moveVeto','destroyVeto','metadataVeto',
        'releasedMove','releasedDestroy','releasedWrite','rollback'}) do
        local pass=checks[label]==true; if pass then passed=passed+1 end
        print(prefix..label..' '..(pass and 'PASS' or 'FAIL'))
    end
    print(prefix..('done %s/8; no movement/destruction/equipment/native/ammo changes; metadata write deliberately rolled back'):format(passed))
    if not ok then print(prefix..'failure '..tostring(err)) end
    return {ok=ok and passed==8,value={passed=passed,total=8}}
end
RegisterCommand('InvInstanceChangeGuardSmokeTest',function(source,args) return Run(source,args) end,true)
exports('RunInstanceChangeGuardCFXSmokeTest',function(target,provider)
    if GetInvokingResource()~='feather-weapons-native-proof' or not Config.DevMode
        or type(provider)~='table' or not callable(provider.Bind) then
        return {ok=false,error={code='smoke_caller_denied'}}
    end
    return Run(0,{target},provider) or {ok=false,error={code='smoke_preflight_failed'}}
end)
