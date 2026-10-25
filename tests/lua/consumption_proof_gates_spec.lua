local root=arg[1]
local command,sql,threads= nil,0,0
Config={DevMode=true}
InventoryReadiness={state='ready'}
InventoryIdentity={NormalizeCharacterId=function(v)
    return type(v)=='string' and v:match('^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$') and v:lower() or nil
end}
RegisterCommand=function(name,fn,restricted) assert(name=='InvConsumptionProof' and restricted); command=fn end
DB={exec=function() sql=sql+1; error('fixture schema unavailable') end}
json={encode=function() return '{}' end}
print=function() end
CreateThread=function(fn) threads=threads+1; fn() end
dofile(root..'/server/services/consumption_proof.lua')
command(1,{'run'}); assert(sql==0 and threads==0,'player cannot start proof')
Config.DevMode=false; command(0,{'run'}); assert(sql==0 and threads==0,'development opt-in required')
Config.DevMode=true
for _,args in ipairs({{}, {'run','extra'}, {'verify'}, {'verify','not-uuid'}, {'delete','all'}}) do command(0,args) end
assert(sql==0 and threads==0,'strict syntax before any SQL')
InventoryReadiness.state='starting'; command(0,{'run'}); assert(sql==0 and threads==0,'readiness required')
InventoryReadiness.state='ready'; command(0,{'run'}); assert(sql==1 and threads==1,'schema error is contained')
command(0,{'run'}); assert(sql==2 and threads==2,'ordinary schema failure releases local busy guard')
_G.print=io.write
io.write('PASS consumption proof console/development/readiness/syntax/error gates; SQL scenarios require MariaDB.\n')
