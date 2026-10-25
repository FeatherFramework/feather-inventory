local root=arg[1]
local command,sql,threads=nil,0,0
Config={DevMode=true,TrustedConsumptionCallers={}}
InventoryReadiness={state='ready'}
InventoryIdentity={NormalizeCharacterId=function(v) return v end}
RegisterCommand=function(name,fn,restricted) assert(name=='InvConsumptionItemProof' and restricted); command=fn end
DB={value=function() sql=sql+1; error('database unavailable') end}
json={encode=function() return '{}' end}
print=function() end
CreateThread=function(fn) threads=threads+1; fn() end
dofile(root..'/server/services/consumption_item_proof.lua')
command(1,{'run'}); assert(sql==0 and threads==0)
Config.DevMode=false; command(0,{'run'}); assert(sql==0 and threads==0)
Config.DevMode=true
for _,args in ipairs({{}, {'run','extra'}, {'cleanup'}, {'run','player'}}) do command(0,args) end
assert(sql==0 and threads==0)
InventoryReadiness.state='starting'; command(0,{'run'}); assert(sql==0 and threads==0)
InventoryReadiness.state='ready'; command(0,{'run'}); assert(sql==1 and threads==1)
command(0,{'run'}); assert(sql==2 and threads==2)
assert(next(Config.TrustedConsumptionCallers)==nil,'proof must not alter production allowlist')
io.write('PASS real-item consumption proof console/development/readiness/syntax/error gates; live Inventory path pending.\n')
