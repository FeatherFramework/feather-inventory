local documents={}
json={decode=function(key) return documents[key] end}
Result={Err=function(code) return {ok=false,code=code} end,Ok=function(value) return {ok=true,value=value} end}
local claim=dofile('server/internal/native_throwable_shared_claim.lua')
local rows={}
for i=1,65 do
 local id=('pickup-%03d'):format(i)
 documents[id]={version=3,kind='paid_tomahawk_pickup',phase=i%2==0 and 'claimed' or 'available',
  pickupId=id,pickupRevision=0,bucket=1,position={x=1,y=2,z=3}}
 rows[i]={grant_id=id,result_json=id}
end
local count=0
local tx={query=function(sql,args)
 count=count+1;assert(sql:find('ORDER BY grant_id LIMIT 65',1,true))
 assert(args[1]=='native-tomahawk-prompt-binding-v3')
 local page={};for _,row in ipairs(rows) do if row.grant_id>args[2] then page[#page+1]=row;if #page==65 then break end end end
 return page
end}
local a=claim.ReadPromptPage(tx,nil)
assert(a.ok and a.value.scanned==64 and #a.value.bindings==32 and a.value.cursor=='pickup-064' and a.value.hasMore)
a.value.bindings[1].position.x=100;assert(documents['pickup-001'].position.x==1,'reader returns no aliases')
local b=claim.ReadPromptPage(tx,a.value.cursor)
assert(b.ok and b.value.scanned==1 and #b.value.bindings==1 and not b.value.hasMore)
assert(claim.ReadPromptPage(tx,b.value.cursor).value.scanned==0)
assert(not claim.ReadPromptPage(tx,{}).ok and count==3,'invalid cursor cannot run SQL')
documents['pickup-001'].networkId=77
assert(not claim.ReadPromptPage(tx,nil).ok,'corrupt or fabricated network bindings cannot become offers')
print('PASS prompt offer pages: bounded keyset reload, claimed-row filtering, stable cursor and malformed binding refusal; modeled SQL')
