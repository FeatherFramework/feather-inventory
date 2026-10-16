-- Console-only SELECT audit. One private file per character; never overwrites
-- a baseline. Resource replacement must preserve the file to compare restarts.
NativeRepairAudit={}
local function denied(message) return Result.Err('repair_audit_refused',message) end
local function validId(v) return type(v)=='number' and v>=1 and v%1==0 and v<math.huge end
function NativeRepairAudit.New(api)
    local A={}
    function A.Run(target,characterId,itemId,mode)
        if not validId(target) or not validId(itemId) or type(characterId)~='string'
            or #characterId~=36 or not characterId:match('^[a-fA-F0-9%-]+$')
            or (mode~='capture' and mode~='verify' and mode~='inspect' and mode~='diagnose'
                and mode~='capture-wear' and mode~='verify-wear') or api.enabled()~=true then return denied('Invalid scoped audit request.') end
        local context=api.context(target,characterId)
        if not context then return denied('Current character required.') end
        local function current() return api.enabled()==true and api.current(target,context,characterId)==true end
        local wear=mode=='capture-wear' or mode=='verify-wear'
        local name=(wear and '.native-wear-audit-%s.json' or '.native-repair-audit-%s.json'):format(characterId:lower())
        if mode=='capture' or mode=='capture-wear' then
            if api.load(name)~=nil then return denied('Baseline already exists; retain it, do not overwrite.') end
            local spec=wear and api.wearPlan(target,itemId) or api.plan(target,itemId)
            if not current() or not spec or not spec.ok or spec.value.characterId~=characterId then
                return denied('Canonical current repair plan required.')
            end
            local read=api.read(characterId,current)
            if not current() or not read or not read.ok then return denied('Durable snapshot unavailable.') end
            local item=read.value.items[itemId]
            if not item or item.revision~=spec.value.itemRevision
                or not api.equal(item.metadata,spec.value.before) then return denied('Item changed during capture.') end
            local encoded=api.encode({schema=1,characterId=characterId,itemId=itemId,kind=wear and 'wear' or 'repair',spec=spec.value,before=read.value})
            if not current() or api.load(name)~=nil then return denied('Capture context/baseline changed.') end
            local saved=api.save(name,encoded)
            local loaded=api.load(name) -- read even when acknowledgement is false/numeric
            if (saved~=true and saved~=1) or loaded~=encoded then
                return denied(('Baseline persistence failed: save=%s readBytes=%s expectedBytes=%s; inspect before retry.')
                    :format(tostring(saved),type(loaded)=='string' and #loaded or 'missing',#encoded))
            end
            return Result.Ok({mode='capture',file=name,itemId=itemId,revision=item.revision,noEconomicWrites=true})
        end
        local raw=api.load(name)
        local called,stored=pcall(api.decode,raw)
        if not called or type(stored)~='table' or stored.schema~=1 or stored.characterId~=characterId
            or stored.itemId~=itemId or type(stored.before)~='table' or type(stored.spec)~='table'
            or type(stored.before.items)~='table' then return denied('Retained trusted baseline required.') end
        -- JSON object keys are strings; normalize only the item identity map.
        local items={}
        for key,row in pairs(stored.before.items) do
            local id=tonumber(key)
            if not validId(id) or type(row)~='table' or row.id~=id or items[id] then return denied('Invalid retained item map.') end
            items[id]=row
        end
        stored.before.items=items
        if wear and stored.kind~='wear' then return denied('Wear baseline required.') end
        local read=api.read(characterId,current)
        if not current() or not read or not read.ok then return denied('Durable verification snapshot unavailable.') end
        if mode=='diagnose' then return NativeRepairVerify.Diagnose(stored.before,read.value,stored.spec) end
        if mode=='inspect' then
            if not api.equal(stored.before,read.value) then return denied('Retained baseline differs from current pre-repair state; do not overwrite.') end
            return Result.Ok({mode='inspect',file=name,itemId=itemId,baselineMatches=true,noEconomicWrites=true})
        end
        if wear then return NativeRepairVerify.CompareWear(stored.before,read.value,stored.spec) end
        return NativeRepairVerify.Compare(stored.before,read.value,stored.spec)
    end
    return A
end
if type(RegisterCommand)=='function' then
    local function enabled() return Config.DevMode==true end
    local audit=NativeRepairAudit.New({enabled=enabled,
        context=function(target,char)
            local result=InventoryIdentity.GetSession(target)
            return result and result.ok and result.value.characterId==char and result.value.sessionId or nil
        end,
        current=function(target,sid,char) return exports['feather-core']:IsSessionCurrent(target,sid,char)==true end,
        plan=function(target,itemId) return exports['feather-weapons']:ReadNativeRepairAuditSpec(target,itemId) end,
        wearPlan=function(target,itemId) return exports['feather-weapons']:ReadNativeMaintenanceAuditSpec(target,itemId) end,
        read=function(char,current)
            return TransactionAPI.Transaction({resource='feather-inventory',reason='native_repair_audit_read'},function(tx)
                if not current() then return denied('Session changed.') end
                local result=NativeRepairVerify.Read(tx,char)
                if not current() then return denied('Session changed during read.') end
                return result
            end)
        end,
        equal=function(a,b) return InventoryMetadata.DocumentsEqual(a,b) end,
        encode=function(v) return json.encode(v) end,decode=function(v) return json.decode(v) end,
        load=function(name) return LoadResourceFile(GetCurrentResourceName(),name) end,
        save=function(name,value) return SaveResourceFile(GetCurrentResourceName(),name,value,#value) end,
    })
    RegisterCommand('InvNativeRepairAudit',function(source,args)
        if source~=0 then return end
        if not args or #args~=4 then return print('[InvNativeRepairAudit] usage: server-id character-uuid item-id capture|inspect|diagnose|verify|capture-wear|verify-wear') end
        local called,result=pcall(audit.Run,tonumber(args[1]),args[2],tonumber(args[3]),args[4])
        if called and result and result.ok then print('[InvNativeRepairAudit] PASS '..json.encode(result.value))
        else print('[InvNativeRepairAudit] REFUSED '..tostring(called and result and result.error and result.error.message or result)) end
    end,true)
end
