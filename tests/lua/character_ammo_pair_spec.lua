local threads, now, consumed, revision, receipt = {}, 0, 0, 0, false
function RegisterCommand() end
function CreateThread(fn) threads[#threads+1]=coroutine.create(fn) end
function Wait() coroutine.yield() end
function GetGameTimer() return now end
Result={Codes={INTERNAL='internal',CONFLICT='conflict'},
    Ok=function(value) return {ok=true,value=value} end,
    Err=function(code,message) return {ok=false,error={code=code,message=message}} end}
local lock
TransactionAPI={Transaction=function(_,body)
    local owner=coroutine.running()
    while lock do Wait(0) end
    lock=owner
    local ok,result=pcall(body,{query=function() return {{id=1}} end})
    lock=nil
    if not ok then error(result) end
    return result
end}
CharacterAmmunitionAPI={Apply=function(tx,_,spec)
    tx.query('SELECT id FROM inventory WHERE character_id = ? LIMIT 1 FOR UPDATE',{'fixture'})
    if receipt and spec.operationId=='duplicate' then return Result.Ok({revision=1}) end
    if spec.expectedRevision ~= revision then return Result.Err('conflict','stale') end
    consumed=consumed+spec.amount; revision=revision+1; receipt=true
    return Result.Ok({revision=revision})
end}
local _,pair=assert(loadfile('server/services/character_ammunition_replay_test.lua'))()
local result
CreateThread(function() result=pair({{operationId='duplicate',amount=3,expectedRevision=0},
    {operationId='duplicate',amount=3,expectedRevision=0}}) end)
local function drain()
    for step=1,100 do
        local active=false
        for _,thread in ipairs(threads) do
            if coroutine.status(thread)~='dead' then active=true; assert(coroutine.resume(thread)) end
        end
        now=now+10
        if not active then return end
    end
    error('scheduler did not finish')
end
drain()
assert(result[1].ok and result[2].ok and consumed==3 and revision==1)
CreateThread(function() result=pair({{operationId='left',amount=1,expectedRevision=1},
    {operationId='right',amount=1,expectedRevision=1}}) end)
drain()
assert(result[1].ok ~= result[2].ok and consumed==4 and revision==2)
print('character ammo pair scheduler PASS (mock lock, real DB contention pending)')
