local clone
clone=function(v) if type(v)~='table' then return v end;local t={};for k,x in pairs(v) do t[k]=clone(x) end;return t end
local state={outcomes={},deliveries={},scopes={}}
local commands,threads,ddl={}, {},0
local lastReport,serial,unavailable,loseAck=nil,0,false,false
Config={DevMode=true}
CountPlaceholders=function(sql) local _,n=sql:gsub('%?','');return n end
json={encode=function(v) lastReport=v;return 'report' end}
RegisterCommand=function(n,f,restricted) assert(restricted);commands[n]=f end
CreateThread=function(f) threads[#threads+1]=f end
Wait=function() error('test must not run background thread') end
local function query(sql,...)
 local p={...}
 assert(not sql:find('inventory_items',1,true) and not sql:find('feather_weapon',1,true),'maintenance cannot mutate gameplay or provenance/receiver receipts')
 if unavailable then error('database unavailable') end
 if sql:match('SHOW COLUMNS') then return {} end
 if sql:match('SHOW INDEX') then return {} end
 if sql:match('ALTER TABLE') then ddl=ddl+1;return {} end
 if sql:find('LIMIT 0',1,true) or sql:match('SELECT id FROM inventory') then return {} end
 if sql:match('INSERT INTO inventory_move_scopes') then for _,id in ipairs(p) do state.scopes[id]=state.scopes[id] or {inventory_id=id} end;return {} end
 if sql:match('SELECT inventory_id,operation_id') then local rows={};for _,row in pairs(state.scopes) do if row.inventory_id==p[1] or row.inventory_id==p[2] then rows[#rows+1]=clone(row) end end;return rows end
 if sql:match('INSERT INTO inventory_move_outcomes') then state.outcomes[p[1]]={operation_id=p[1],source_inventory=p[2],target_inventory=p[3],state=p[4],refresh_pending=p[5],expired=p[6]==0 and 1 or 0};return {affectedRows=1} end
 if sql:match('INSERT INTO inventory_move_outbox') then state.deliveries[p[1]]={delivered=p[3],expired=p[4]==0 and 1 or 0};return {affectedRows=1} end
 if sql:match('UPDATE inventory_move_scopes SET operation_id') then state.scopes[p[2]].operation_id=p[1];state.scopes[p[3]].operation_id=p[1];return {} end
 if sql:match('SELECT operation_id,state,refresh_pending') then return state.outcomes[p[1]] and {clone(state.outcomes[p[1]])} or {} end
 if sql:match('SELECT delivered,') then return state.deliveries[p[1]] and {clone(state.deliveries[p[1]])} or {} end
 if sql:match('DELETE FROM inventory_move_outbox') then state.deliveries[p[1]]=nil;return {affectedRows=1} end
 if sql:match('DELETE FROM inventory_move_outcomes') then assert(state.outcomes[p[1]]);state.outcomes[p[1]]=nil;return {affectedRows=1} end
 if sql:match('SELECT operation_id FROM inventory_move_outcomes') then return state.outcomes[p[1]] and {{operation_id=p[1]}} or {} end
 if sql:match('SELECT operation_id FROM inventory_move_outbox') then return state.deliveries[p[1]] and {{operation_id=p[1]}} or {} end
 if sql:match('SELECT inventory_id FROM inventory_move_scopes WHERE operation_id') then local rows={};for _,r in pairs(state.scopes) do if r.operation_id==p[1] then rows[#rows+1]=clone(r) end end;return rows end
 if sql:match('UPDATE inventory_move_outcomes SET completed_at') then for _,r in pairs(state.outcomes) do if r.expired==nil and r.state~='pending' then r.expired=0 end end;return {} end
 if sql:match('UPDATE inventory_move_outbox SET delivered_at') then for _,r in pairs(state.deliveries) do if r.delivered==1 and r.expired==nil then r.expired=0 end end;return {} end
 if sql:match('SELECT o.operation_id') then
  assert(sql:find('d.delivered_at<=DATE_SUB',1,true) and sql:find('NOT EXISTS',1,true) and sql:find('LIMIT 25',1,true),'candidate scan must skip protected rows, not starve later settled operations')
  local rows={};for id,r in pairs(state.outcomes) do
   local d=state.deliveries[id];local active=false;for _,scope in pairs(state.scopes) do if (scope.inventory_id==r.source_inventory or scope.inventory_id==r.target_inventory) and scope.operation_id then active=true end end
   if not active and r.expired==1 and r.refresh_pending==0 and ((r.state=='committed' and d and d.delivered==1 and d.expired==1) or (r.state=='rolled_back' and not d)) then rows[#rows+1]=clone(r) end
  end;return rows
 end
 if sql:find('COUNT(*) AS pending',1,true) then local count,oldest=0,0;local from=sql:find('FROM inventory_move_outbox',1,true) and state.deliveries or state.outcomes
  local refresh=sql:find('WHERE refresh_pending=1',1,true)
  for _,r in pairs(from) do if (refresh and r.refresh_pending==1 and r.state~='pending') or (not refresh and (r.state=='pending' or r.delivered==0)) then count=count+1;oldest=math.max(oldest,r.age or 0) end end;return {{pending=count,oldest=oldest}}
 end
 if sql:find('COUNT(*) AS active',1,true) then local n=0;for _,r in pairs(state.scopes) do if r.operation_id then n=n+1 end end;return {{active=n}} end
 error('unexpected SQL '..sql)
end
DB={query=query,exec=query,value=function() serial=serial+1;return ('00000000-0000-0000-0000-%012d'):format(serial) end}
DB.transaction=function(body)
 local before=clone(state);local ok,v=pcall(body,{raw=query})
 if not ok or v==false then state=before end
 if not ok then error(v) end
 if loseAck then loseAck=false;error('lost cleanup acknowledgement after commit') end
 return v~=false
end
dofile('server/services/move_maintenance.lua')
assert(InventoryMoveMaintenance.Health().state=='unavailable')
InventoryMoveMaintenance.Start();assert(ddl==2 and #threads==1)
commands.InvMoveMaintenanceAcceptance(3,{});assert(serial==0)
commands.InvMoveMaintenanceAcceptance(0,{})
assert(lastReport.phase=='passed' and lastReport.checks==9 and lastReport.fixtureRollbackConfirmed and serial==8)
assert(next(state.outcomes)==nil and next(state.deliveries)==nil and next(state.scopes)==nil,'all diagnostic writes roll back')
state.outcomes.old={operation_id='old',source_inventory=2,target_inventory=15,state='committed',refresh_pending=0,expired=1}
state.deliveries.old={delivered=1,expired=1}
state.outcomes.pending={operation_id='pending',source_inventory=3,target_inventory=16,state='pending',refresh_pending=0,expired=1,age=120}
state.outcomes.upgrade={operation_id='upgrade',source_inventory=4,target_inventory=17,state='committed',refresh_pending=0}
state.deliveries.upgrade={delivered=1}
loseAck=true;assert(InventoryMoveMaintenance.Cleanup().phase=='waiting_for_database')
assert(not state.outcomes.old and not state.deliveries.old and state.outcomes.pending and state.outcomes.upgrade.expired==0 and state.deliveries.upgrade.expired==0,'lost cleanup reply and upgrade grace retain safety')
assert(InventoryMoveMaintenance.Cleanup().phase=='complete')
assert(InventoryMoveMaintenance.Health().state=='attention')
state.outcomes.pending.age=1;assert(InventoryMoveMaintenance.Health().state=='waiting')
state.outcomes.pending=nil;assert(InventoryMoveMaintenance.Health().state=='healthy')
state.outcomes.refresh={state='rolled_back',refresh_pending=1,age=120};assert(InventoryMoveMaintenance.Health().state=='attention','stuck harmless refresh is visible too');state.outcomes.refresh=nil
unavailable=true;assert(InventoryMoveMaintenance.Health().state=='unavailable')
print('PASS move maintenance: rollback-only nine-check acceptance, old settled cleanup, unresolved/recent delivery/refresh/scope retention, upgrade grace, lost cleanup reply and health states; no gameplay/provenance SQL')
