-- Console-only real-row checkpoint gate. Every enrollment/observation write
-- is rolled back; no native observations, grants or reset instructions are sent.
local function RunObservationSmoke(source,args,withRuntime,withCFX)
    if source~=0 or not Config.DevMode then return end
    local withDeath=withRuntime and args and args[2]=='death'
    local prefix=withCFX and '[InvCharacterAmmoRuntimeCFXSmokeTest] '
        or withRuntime and '[InvCharacterAmmoRuntimeSmokeTest] ' or '[InvCharacterAmmoObservationSmokeTest] '
    if GetResourceState('feather-weapons')~='stopped' or GuardsAPI.HasRegisteredGuard('feather-weapons') then
        print(prefix..'BLOCKED: keep Weapons stopped and restart Inventory to clear retained Weapons guards'); return
    end
    local target=tonumber(args and args[1])
    local session=target and InventoryIdentity.GetSession(target)
    if not session or not session.ok then print(prefix..'Connected character required'); return end
    local characterId=session.value.characterId
    local function current() return exports['feather-core']:IsSessionCurrent(target,session.value.sessionId,characterId)==true end
    local loaded,catalog,planner,limits=pcall(CharacterAmmoCutoverPreview.Load)
    if not loaded then print(prefix..'FAIL '..tostring(catalog)); return end
    local runtimeContract
    if withCFX then
        if GetResourceState('feather-weapons-native-proof')~='started' then
            print(prefix..'BLOCKED: running updated native proof resource required'); return
        end
        runtimeContract={New=function(validator)
            return exports['feather-weapons-native-proof']:CreateInventoryRuntimeFixture(validator)
        end}
    elseif withRuntime then
        local ready,value=pcall(CharacterAmmoCutoverPreview.LoadRuntime)
        if not ready then print(prefix..'FAIL '..tostring(value)); return end
        runtimeContract=value
    end
    local before,checks,candidate={}, {},nil
    local function copy(pools) local result={}; for id,amount in pairs(pools) do result[id]=amount end; return result end
    local function snapshot() return DB.raw([[SELECT ii.id, ii.row_revision, ii.metadata FROM inventory_items ii
        INNER JOIN inventory inv ON inv.id=ii.inventory_id WHERE inv.character_id=? ORDER BY ii.id]],characterId) end
    local result=TransactionAPI.Transaction({resource='feather-inventory',reason='character_ammo_observation_rollback_smoke'},function(tx)
        if not current() then return Result.Err(Result.Codes.DENIED,'Session changed.') end
        tx.query('SELECT id FROM inventory WHERE character_id = ? LIMIT 1 FOR UPDATE',{characterId})
        before=tx.query([[SELECT ii.id, ii.row_revision, ii.metadata FROM inventory_items ii
            INNER JOIN inventory inv ON inv.id=ii.inventory_id WHERE inv.character_id=? ORDER BY ii.id FOR UPDATE]],{characterId})
        local enrolled=CharacterAmmoEnrollment.Apply(tx,characterId,catalog,planner,limits)
        if not enrolled.ok then return enrolled end
        local baseline=enrolled.value.pools
        local total,selected=0,nil
        local keys={}
        for id,amount in pairs(baseline) do total=total+amount; keys[#keys+1]=id end
        table.sort(keys)
        for _,id in ipairs(keys) do if baseline[id]>0 then selected=id; break end end
        if total<2 then return Result.Err(Result.Codes.DENIED,'At least two carried rounds required for this rollback gate.') end
        local observationLimits={}; for id in pairs(baseline) do observationLimits[id]=limits[id] end
        local observed=copy(baseline); observed[selected]=observed[selected]-1
        local runtime,request,report
        if withRuntime then
            runtime=runtimeContract.New(function(src,sid,char)
                return src==target and sid==session.value.sessionId and char==characterId and current()
            end)
            if type(runtime)~='table' then return Result.Err(Result.Codes.DENIED,'Cross-resource runtime fixture unavailable.') end
            local epoch='rollback-smoke:'..session.value.sessionId
            local opened=runtime.Open({source=target,characterId=characterId,sessionId=session.value.sessionId},
                {characterId=characterId,revision=0,pools=baseline},observationLimits,epoch)
            if not opened then return Result.Err(Result.Codes.CONFLICT,'Runtime baseline rejected.') end
            report={characterId=characterId,sessionId=session.value.sessionId,epoch=epoch,revision=0,pools=copy(baseline)}
            local reset={}; for id in pairs(baseline) do reset[id]=0 end
            report.pools=reset
            checks.restoreResetRejected=not runtime.ConfirmRestore(target,report)
                and not runtime.PrepareObservation(target,report)
            report.pools=copy(baseline)
            if not runtime.ConfirmRestore(target,report) then return Result.Err(Result.Codes.CONFLICT,'Restore acknowledgement rejected.') end
            report.pools=observed
            request=runtime.PrepareObservation(target,report)
            if not request then return Result.Err(Result.Codes.CONFLICT,'Observation authorization rejected.') end
            local forged=copy(request.context); forged.runtimeTicket='foreign'
            checks.ticketBound=runtime.IsOperationCurrent(request.context,'observe',request.spec)
                and not runtime.IsOperationCurrent(forged,'observe',request.spec)
            checks.inFlightRejected=not runtime.PrepareObservation(target,report)
                and not runtime.Seal(target,session.value.sessionId,epoch)
        end
        local function observe(pools,revision)
            return CharacterAmmunitionAPI.ApplyObservation(tx,{characterId=characterId},
                {pools=pools,expectedRevision=revision,limits=observationLimits})
        end
        local accepted=observe(observed,0)
        checks.decreaseConserved=accepted.ok and accepted.value.revision==1 and accepted.value.changed==true
            and accepted.value.consumed[selected]==1 and InventoryMetadata.DocumentsEqual(accepted.value.pools,observed)
        if not checks.decreaseConserved then return accepted end
        if withRuntime then
            local committed=runtime.Complete(request.context,accepted)
            checks.commitMatched=committed and committed.revision==1
                and InventoryMetadata.DocumentsEqual(committed.pools,observed)
        end
        local unchanged=observe(copy(observed),1)
        checks.unchangedNoRevision=unchanged.ok and unchanged.value.revision==1 and unchanged.value.changed==false
        local increased=observe(copy(baseline),1)
        checks.increaseRejected=not increased.ok and increased.error.code==Result.Codes.CONFLICT
        local partial=copy(observed); partial[keys[1]]=nil
        local incomplete=observe(partial,1)
        checks.incompleteRejected=not incomplete.ok and incomplete.error.code==Result.Codes.INVALID_INPUT
        local stale=observe(copy(observed),0)
        checks.staleRejected=not stale.ok and stale.error.code==Result.Codes.CONFLICT
        local finalBaseline,finalRevision=observed,1
        if withDeath then
            local deathPools=copy(observed)
            local deathType
            for _,id in ipairs(keys) do if deathPools[id]>0 then deathType=id; break end end
            deathPools[deathType]=deathPools[deathType]-1
            report.revision=1; report.pools=deathPools
            local drain=runtime.PrepareFinalObservation(target,report)
            if not drain then return Result.Err(Result.Codes.CONFLICT,'Death final ticket rejected.') end
            checks.deathTicketBound=runtime.IsOperationCurrent(drain.context,'observe',drain.spec)
            local saved=observe(deathPools,1)
            if not saved.ok then return saved end
            local sealed=runtime.Complete(drain.context,saved)
            checks.deathCommitSealed=sealed and sealed.phase=='sealed' and sealed.revision==2
                and saved.value.consumed[deathType]==1 and InventoryMetadata.DocumentsEqual(sealed.pools,deathPools)
            report.revision=2
            checks.deathLateRejected=not runtime.PrepareObservation(target,report)
                and not runtime.PrepareTransfer(target,report,deathType,1,'late-death-transfer')
            local cleanup=copy(sealed)
            cleanup.cleanupComplete=true; cleanup.remainingCopies=1
            local copiesRejected=not runtime.ConfirmCleanup(target,cleanup)
            cleanup.remainingCopies=0; cleanup.revision=1
            checks.deathCleanupRejected=copiesRejected and not runtime.ConfirmCleanup(target,cleanup)
            cleanup.revision=2
            local released=runtime.ConfirmCleanup(target,cleanup)
            checks.deathCleanupReleased=released and released.phase=='released' and released.revision==2
                and InventoryMetadata.DocumentsEqual(released.pools,deathPools)
            local replay=runtime.ConfirmCleanup(target,cleanup)
            checks.deathCleanupReplay=replay and replay.phase=='released'
                and InventoryMetadata.DocumentsEqual(replay.pools,deathPools)
            -- Separate fixture epoch exercises revoked-ticket rollback below;
            -- this is not a respawn/recovery authorization test.
            local epoch=report.epoch..':revocation'
            if not runtime.Open({source=target,characterId=characterId,sessionId=session.value.sessionId},
                {characterId=characterId,revision=2,pools=deathPools},observationLimits,epoch) then
                return Result.Err(Result.Codes.CONFLICT,'Revocation fixture epoch rejected.')
            end
            report.epoch=epoch; report.pools=copy(deathPools)
            if not runtime.ConfirmRestore(target,report) then return Result.Err(Result.Codes.CONFLICT,'Revocation fixture ack rejected.') end
            finalBaseline,finalRevision=deathPools,2
        end
        local zero={}; for id in pairs(finalBaseline) do zero[id]=0 end
        local final=observe(zero,finalRevision)
        if not final.ok or final.value.revision~=finalRevision+1 or not final.value.changed then return Result.Err(Result.Codes.CONFLICT,'Forced rollback update not exercised.') end
        candidate={consumedType=selected,before=baseline,afterOneShot=observed,revision=1}
        if withRuntime then
            report.revision=finalRevision; report.pools=zero
            local last=runtime.PrepareObservation(target,report)
            if not last then return Result.Err(Result.Codes.CONFLICT,'Final runtime ticket rejected.') end
            runtime.Revoke(target)
            checks.revocationRejected=not runtime.IsOperationCurrent(last.context,'observe',last.spec)
                and not runtime.Complete(last.context,final)
        end
        if not current() then return Result.Err(Result.Codes.DENIED,'Session changed before rollback.') end
        return Result.Err(Result.Codes.DENIED,'intentional_observation_rollback')
    end)
    checks.rollback=result.ok==false and candidate~=nil and InventoryMetadata.DocumentsEqual(before,snapshot())
        and not DB.one('SELECT character_id FROM feather_character_ammunition WHERE character_id=?',characterId)
        and not DB.one('SELECT character_id FROM feather_ammunition_operations WHERE character_id=? AND operation_id=?',
            characterId,'alpha-character-ammo-enrollment-v1')
    local passed=0
    local names={'decreaseConserved','unchangedNoRevision','increaseRejected','incompleteRejected','staleRejected','rollback'}
    if withRuntime then
        for _,name in ipairs({'restoreResetRejected','ticketBound','inFlightRejected','commitMatched','revocationRejected'}) do names[#names+1]=name end
    end
    if withDeath then
        for _,name in ipairs({'deathTicketBound','deathCommitSealed','deathLateRejected',
            'deathCleanupRejected','deathCleanupReleased','deathCleanupReplay'}) do names[#names+1]=name end
    end
    for _,name in ipairs(names) do
        if checks[name] then passed=passed+1 end
        print(prefix..name..' '..(checks[name] and 'PASS' or 'FAIL'))
    end
    print(prefix..('done %d/%d; rollback=%s; no native changes'):format(passed,#names,checks.rollback and 'VERIFIED' or 'NOT VERIFIED'))
    print(prefix..(candidate and ('candidate '..json.encode(candidate)) or ('failure '..json.encode(result))))
end
RegisterCommand('InvCharacterAmmoObservationSmokeTest',function(source,args) RunObservationSmoke(source,args,false) end,true)
RegisterCommand('InvCharacterAmmoRuntimeSmokeTest',function(source,args) RunObservationSmoke(source,args,true) end,true)
RegisterCommand('InvCharacterAmmoRuntimeCFXSmokeTest',function(source,args) RunObservationSmoke(source,args,true,true) end,true)
