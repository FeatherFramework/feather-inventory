local clone
clone=function(v) if type(v)~='table' then return v end;local t={};for k,x in pairs(v) do t[k]=clone(x) end;return t end
local documents,serial,files,convars={},0,{}, {feather_restart_process_token='host1',feather_native_restart_suite=1}
json={encode=function(v) serial=serial+1;local key='doc'..serial;documents[key]=clone(v);return key end,decode=function(v) return clone(assert(documents[v])) end}
Config={DevMode=true};GetCurrentResourceName=function() return 'feather-inventory' end
GetConvar=function(n,d) return convars[n] or d end;GetConvarInt=function(n,d) return convars[n] or d end;SetConvar=function(n,v) convars[n]=v end
GetGameTimer=function() return 100 end
LoadResourceFile=function(_,p) return files[p] end;SaveResourceFile=function(_,p,v) files[p]=v;return true end
local api,caller={},'feather-weapons'
exports=setmetatable({['feather-weapons']={AuditInventoryMoveDelivery=function() return {ok=true,events=1,eventIds={9}} end}},{__call=function(_,n,fn) api[n]=fn end})
GetInvokingResource=function() return caller end
CreateThread=function() end;Wait=function() end
InventoryMoveMaintenance={Health=function() return {state='healthy'} end}
local uptime,offline,seq=9000,false,0
local deliveryId='00000000-0000-0000-0000-000000000099'
local payload=json.encode({moves={{instanceId=229,serialNumber='FW-LASS-6AE6BCBA-26771B-0001'}}})
local state={receipts={},scopes={},delivery={operation_id=deliveryId,payload=payload,delivered=1}}
local function query(sql,...)
 local p={...};assert(not sql:find('inventory_items',1,true),'restart probe cannot touch gameplay items')
 if offline then error('database offline') end
 if sql:find('SHOW GLOBAL STATUS',1,true) then return {{Value=tostring(uptime)}} end
 if sql:match('SELECT id FROM inventory') then return {} end
 if sql:match('SELECT operation_id,payload FROM inventory_move_outbox') then return {clone(state.delivery)} end
 if sql:match('INSERT INTO inventory_move_scopes') then for _,id in ipairs(p) do state.scopes[id]=state.scopes[id] or {inventory_id=id} end;return {} end
 if sql:match('SELECT inventory_id,operation_id') then local rows={};for _,r in pairs(state.scopes) do rows[#rows+1]=clone(r) end;return rows end
 if sql:match('INSERT INTO inventory_move_outcomes') then state.receipts[p[1]]={state='pending',refresh_pending=1};return {affectedRows=1} end
 if sql:match('UPDATE inventory_move_scopes') then for _,r in pairs(state.scopes) do r.operation_id=p[1] end;return {affectedRows=2} end
 if sql:match('SELECT payload,delivered') then return {clone(state.delivery)} end
 if sql:match('UPDATE inventory_move_outbox') then state.delivery.delivered=0;return {affectedRows=1} end
 if sql:match('SELECT state,refresh_pending') then return state.receipts[p[1]] and {clone(state.receipts[p[1]])} or {} end
 if sql:match('SELECT inventory_id FROM inventory_move_scopes') then local rows={};for _,r in pairs(state.scopes) do if r.operation_id==p[1] then rows[#rows+1]=clone(r) end end;return rows end
 error(sql)
end
DB={query=query,value=function() seq=seq+1;return ('00000000-0000-0000-0000-%012d'):format(seq) end}
DB.transaction=function(body) local before=clone(state);local ok,v=pcall(body,{raw=query});if not ok or v==false then state=before end;if not ok then error(v) end;return v~=false end
local function settle(id)
 assert(not InventoryRestartAudit.Paused(id),'normal worker cannot settle before boundary')
 state.receipts[id]={state='rolled_back',refresh_pending=0};for _,r in pairs(state.scopes) do r.operation_id=nil end;state.delivery.delivered=1
end
dofile('server/services/restart_audit.lua')
caller='untrusted';assert(not api.PrepareRestartRecovery('server').ok);caller='feather-weapons'
local prepared=api.PrepareRestartRecovery('server');assert(prepared.ok and seq==1 and InventoryRestartAudit.Paused(prepared.probeId) and InventoryRestartAudit.Paused(deliveryId))
assert(not api.PrepareRestartRecovery('server').ok and seq==1,'no dispatch replay')
dofile('server/services/restart_audit.lua')
assert(not api.ReadRestartRecovery(true).ok and InventoryRestartAudit.Paused(prepared.probeId),'resource restart alone is insufficient')
convars.feather_restart_process_token='host2';dofile('server/services/restart_audit.lua')
assert(not api.ReadRestartRecovery(true).ok and not InventoryRestartAudit.Paused(prepared.probeId),'boundary alone cannot certify pending work')
settle(prepared.probeId);assert(api.ReadRestartRecovery(true).ok)
uptime=10000
local database=api.PrepareRestartRecovery('database');assert(database.ok and seq==2)
uptime=11000;assert(not api.ReadRestartRecovery(false).released)
offline=true;assert(api.ReadRestartRecovery(false).offlineObserved)
offline=false;uptime=12000;assert(not api.ReadRestartRecovery(false).released,'network outage without uptime reset is insufficient')
uptime=5;assert(api.ReadRestartRecovery(false).released)
settle(database.probeId)
exports['feather-weapons'].AuditInventoryMoveDelivery=function() return {ok=true,events=1,eventIds={10}} end
assert(not api.ReadRestartRecovery(true).ok,'changed provenance event cannot pass')
exports['feather-weapons'].AuditInventoryMoveDelivery=function() return {ok=true,events=1,eventIds={9}} end
assert(api.ReadRestartRecovery(true).ok and seq==2)
local journal=documents[files['native-restart-probe.json']];assert(#journal.history==2)
print('PASS restart audit: persistent pauses, actual reservation/redelivery SQL model, resource-only restart refusal, full process token proof, offline+uptime DB proof, pending work and duplicate-ledger conservation')
