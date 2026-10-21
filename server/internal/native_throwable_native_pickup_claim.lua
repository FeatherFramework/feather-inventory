-- Inventory transaction primitive; no independent export or net route.
-- Native pickup is already reflected in the ped pool. Credit ONLY the character
-- ledger and claim the server-written spend receipt, never grant a loose item.
-- Caller owns rollback on every refused/exception result and validates the
-- active Weapons reservation. `plan` is not accepted directly from clients.
local C={}
local function copy(v) if type(v)~='table' then return v end; local r={}; for k,x in pairs(v) do r[k]=copy(x) end; return r end
local function equal(a,b)
    if type(a)~=type(b) then return false end; if type(a)~='table' then return a==b end
    for k,v in pairs(a) do if not equal(v,b[k]) then return false end end
    for k in pairs(b) do if a[k]==nil then return false end end; return true
end
local function int(v,min) return type(v)=='number' and v>=min and v<math.huge and v%1==0 end
local function text(v,max) return type(v)=='string' and #v>0 and #v<=max and not v:find('%c') end
local function callable(v) return type(v)=='function' or (type(v)=='table' and type(rawget(v,'__cfx_functionReference'))=='string') end
local function refused() return Result.Err('native_pickup_claim_refused','Unclaimed same-epoch spend and exact ledger/carrier required.') end
local function updated(v) return type(v)=='table' and tonumber(v.affectedRows or v.affected_rows)==1 end
local namespace='native-tomahawk-native-spend-v1'
function C.Apply(tx,context,plan,limits,current)
    if not callable(current) or current()~=true or type(context)~='table' or type(plan)~='table'
        or plan.version~=1 or plan.kind~='native_pickup_ledger_plan'
        or plan.policy~='same_session_native_spend_credit_v1' or plan.units~=1
        or plan.requiresAtomicSpendClaim~=true or plan.requiresLedgerCAS~=true
        or plan.looseInventoryDelta~=0 or plan.nativeAmmoDelta~=0 or plan.pickupCredits~=false
        or plan.originConfirmed~=false or not text(plan.spendReceiptId,64)
        or not int(plan.expectedRevision,0) or plan.revision~=plan.expectedRevision+1
        or type(plan.identity)~='table' or not int(plan.itemId,1) or not int(plan.itemRevision,0)
        or not text(plan.serialNumber,128) or type(limits)~='table' or limits.ammo_tomahawk_regular~=1 then return refused() end
    context,plan,limits=copy(context),copy(plan),copy(limits)
    for _,name in ipairs({'characterId','sessionId','epoch'}) do
        if not text(context[name],128) or context[name]~=plan.identity[name] then return refused() end
    end
    -- Existing common order: inventory header, ledger, receipts, item rows.
    local read=CharacterAmmunitionAPI.ReadSnapshot(tx,context.characterId,limits,false)
    if not read or not read.ok or current()~=true then return refused() end
    local rows=tx.query('SELECT result_json FROM inventory_grant_receipts WHERE source_resource=? AND grant_id=? FOR UPDATE',
        {namespace,plan.spendReceiptId})
    local row=rows and rows[1]
    local ok,credit=pcall(function() return row and json.decode(row.result_json) end)
    if not ok or type(credit)~='table' or credit.policy~=plan.policy or credit.receiptId~=plan.spendReceiptId
        or (credit.phase~='committed_unclaimed' and credit.phase~='claimed') then return refused() end
    local candidate=credit.candidate
    if type(candidate)~='table' or not equal(candidate.identity,plan.identity) or not equal(candidate.key,plan.spendKey)
        or candidate.itemId~=plan.itemId or candidate.itemRevision~=plan.itemRevision
        or candidate.serialNumber~=plan.serialNumber or candidate.units~=1
        or candidate.definitionId~='throwable_tomahawk' or type(candidate.key)~='table'
        or candidate.key.ammunitionId~='ammo_tomahawk_regular'
        or not int(candidate.key.revisionBefore,0) or candidate.key.revisionAfter~=candidate.key.revisionBefore+1
        or plan.expectedRevision<candidate.key.revisionAfter then return refused() end
    for _,name in ipairs({'characterId','sessionId','epoch'}) do
        if candidate.key[name]~=context[name] then return refused() end
    end
    if credit.phase=='claimed' then
        if not equal(credit.claimPlan,plan) or not equal(credit.claimResult,
            {characterId=context.characterId,revision=plan.revision,pools=plan.pools,spendReceiptId=plan.spendReceiptId})
            or current()~=true then return refused() end
        local result=copy(credit.claimResult); result.replayed=true
        return Result.Ok(result) -- never rewrite a ledger that has since changed
    end
    local ledger=read.value
    if not ledger or ledger.characterId~=context.characterId or ledger.revision~=plan.expectedRevision
        or type(ledger.pools)~='table' or type(plan.pools)~='table'
        or ledger.pools.ammo_tomahawk_regular~=0 or plan.pools.ammo_tomahawk_regular~=1 then return refused() end
    for id,limit in pairs(limits) do
        if not int(limit,0) or not int(ledger.pools[id],0) or not int(plan.pools[id],0)
            or ledger.pools[id]>limit or plan.pools[id]>limit
            or (id~='ammo_tomahawk_regular' and ledger.pools[id]~=plan.pools[id]) then return refused() end
    end
    for id in pairs(plan.pools) do if limits[id]==nil then return refused() end end
    for id in pairs(ledger.pools) do if limits[id]==nil then return refused() end end
    local equipment=NativeThrowableEquipment.Read(tx,context.characterId,plan.itemId,current)
    local value=equipment and equipment.ok and equipment.value
    local item=value and value.equipment and value.equipment.throwable
    local expected=value and value.expected and value.expected.weapon_throwable
    if not item or item.id~=plan.itemId or item.revision~=plan.itemRevision or type(item.metadata)~='table'
        or not expected or expected.itemId~=plan.itemId or expected.revision~=plan.itemRevision
        or item.metadata.serialNumber~=plan.serialNumber or current()~=true then return refused() end
    local result={characterId=context.characterId,revision=plan.revision,pools=copy(plan.pools),spendReceiptId=plan.spendReceiptId}
    local wrote=tx.query('UPDATE feather_character_ammunition SET pools = ?, revision = ? WHERE character_id = ? AND revision = ?',
        {json.encode(plan.pools),plan.revision,context.characterId,plan.expectedRevision})
    if not updated(wrote) or current()~=true then return refused() end
    credit.phase='claimed'; credit.claimPlan=copy(plan); credit.claimResult=copy(result)
    wrote=tx.query('UPDATE inventory_grant_receipts SET result_json=? WHERE source_resource=? AND grant_id=?',
        {json.encode(credit),namespace,plan.spendReceiptId})
    if not updated(wrote) or current()~=true then return refused() end
    result.replayed=false
    return Result.Ok(result)
end
NativeThrowableNativePickupClaim=C
return C
