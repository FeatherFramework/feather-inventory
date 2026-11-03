local callbacks,calls={},0
RegisterNUICallback=function(name,fn) callbacks[name]=fn end
GetGameTimer=function() return 0 end
GetPedInFront=function() return 7 end;GetPlayerFromPed=function() return 8 end
local response={error=true,code='transaction_outcome_unknown',outcome='unknown',retrySafe=false,message='developer message'}
Feather={RPC={CallAsync=function() calls=calls+1;return response end}}
dofile('client/services/nuicallbacks.lua')
for _,code in ipairs({'transaction_outcome_unknown','move_recovery_pending','move_recovery_unavailable'}) do
 response.code=code
 for _,name in ipairs({'UpdateInventory','GiveItem','MoveItem','SplitStack','TakeAll'}) do
 local got;local before=calls
 callbacks['Feather:Inventory:'..name]({items={229},sourceInventory=2,targetInventory=15,itemId=229},function(v) got=v end)
 assert(calls==before+1 and got.code==code and got.outcome=='unknown' and got.retrySafe==false,name)
 end
end
print('PASS actual NUI adapters retain unknown/no-retry across give/bulk/drag/split/take-all with one RPC each')
