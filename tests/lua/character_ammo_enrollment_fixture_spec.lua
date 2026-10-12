local function copy(value)
    if type(value)~='table' then return value end
    local result={}; for k,v in pairs(value) do result[k]=copy(v) end; return result
end
local docs,n={},0
json={encode=function(value) n=n+1; docs[tostring(n)]=copy(value); return tostring(n) end,
    decode=function(value) assert(docs[value],'invalid JSON'); return copy(docs[value]) end}
Result={Codes={CONFLICT='conflict',DENIED='denied'},Ok=function(v) return {ok=true,value=v} end,
    Err=function(c,m) return {ok=false,error={code=c,message=m}} end,IsOk=function(v) return v and v.ok end}
local fixtureId='00000000-0000-4000-8000-000000000002'
InventoryIdentity={NormalizeCharacterId=function(id) return id==fixtureId and id end}
Config={DevMode=true}; GetResourceState=function() return 'stopped' end
local commands,output={},{}
RegisterCommand=function(name,fn) commands[name]=fn end
local originalPrint=print
print=function(s) output[#output+1]=s end
LoadResourceFile=function(resource,path)
    assert(resource=='feather-weapons')
    local f=assert(io.open('../feather-weapons/'..path,'r')); local text=f:read('*a'); f:close(); return text
end
dofile('server/helpers/metadata_compatibility.lua')
dofile('server/services/character_ammunition.lua')
dofile('server/services/character_ammunition_preview.lua')
dofile('server/services/character_ammunition_enrollment.lua')
local database={header={},items={},ledger={},receipts={}}
local queries={}
local function query(sql,p)
    queries[#queries+1]=sql
    -- The real side of the fixture adapter must never see production tables.
    assert(not sql:find('inventory_items',1,true) and not sql:find('feather_character_ammunition',1,true)
        and not sql:find('feather_ammunition_operations',1,true),'production SQL escaped')
    local name=sql:match('fi_ammo_enroll_(%w+)'); assert(database[name],'unrecognized fixture table')
    assert(p[1]==fixtureId or sql:find('UPDATE',1,true),'fixture character scope required')
    if sql:match('^SELECT') then
        local rows={}
        for _,row in pairs(database[name]) do
            if name~='receipts' or #p<2 or row.operation_id==p[2] then rows[#rows+1]=copy(row) end
        end
        table.sort(rows,function(a,b) return (a.id or 0)<(b.id or 0) end)
        if sql:find('COUNT(*)',1,true) then return {{count=#rows}} end
        return rows
    elseif sql:match('^INSERT') then
        if name=='header' then assert(#database.header==0); database.header={{character_id=fixtureId,id=1}}
        elseif name=='items' then database.items[#database.items+1]={character_id=fixtureId,id=p[2],name=p[3],type='item_weapon',row_revision=1,metadata=p[4],original_metadata=p[5]}
        elseif name=='ledger' then assert(#database.ledger==0); database.ledger={{character_id=fixtureId,revision=0,pools=p[2]}}
        elseif name=='receipts' then assert(#database.receipts==0); database.receipts={{character_id=fixtureId,operation_id=p[2],result=p[3]}} end
        return {affectedRows=1}
    elseif sql:match('^UPDATE') then
        if name=='ledger' then
            assert(p[3]==fixtureId)
            local row=database.ledger[1]
            if row and row.revision==p[4] then row.pools=p[1]; row.revision=p[2]; return {affectedRows=1} end
            return {affectedRows=0}
        end
        assert(name=='items' and p[2]==fixtureId)
        for _,row in ipairs(database.items) do
            if row.id==p[3] and row.row_revision==p[4] then row.metadata=p[1]; row.row_revision=row.row_revision+1; return {affectedRows=1} end
        end
        return {affectedRows=0}
    elseif sql:match('^DELETE') then database[name]={}; return {affectedRows=1} end
    error(sql)
end
DB={exec=function(sql) assert(sql:find('CREATE TABLE IF NOT EXISTS fi_ammo_enroll_',1,true)) end,
    raw=function(sql,...) return query(sql,{...}) end,
    one=function(sql,...) return query(sql,{...})[1] end,
    value=function(sql,...) return query(sql,{...})[1].count end}
TransactionAPI={Transaction=function(_,body)
    local before=copy(database)
    local ok,result=pcall(body,{query=query})
    if not ok or not result.ok then database=before end
    return ok and result or Result.Err('exception',tostring(result))
end}
local fixture,inspect=dofile('server/services/character_ammunition_enrollment_test.lua')
local function run(mode,expected)
    output={}; commands.InvCharacterAmmoEnrollmentReplayTest(0,{mode})
    local found=false; for _,line in ipairs(output) do if line:find(expected,1,true) then found=true end end
    assert(found,table.concat(output,'\n'))
end
run('prepare','prepare PASS')
local committed=copy(database)
run('prepare','prepare FAIL')
assert(InventoryMetadata.DocumentsEqual(committed,database),'prepare cannot overwrite evidence')
-- Reload actual modules, retaining only the DB state to simulate resource restart.
dofile('server/services/character_ammunition_preview.lua')
dofile('server/services/character_ammunition_enrollment.lua')
fixture,inspect=dofile('server/services/character_ammunition_enrollment_test.lua')
run('verify','done 5/5')
assert(InventoryMetadata.DocumentsEqual(committed,database),'duplicate refusal must not alter committed fixture')
local ok=pcall(fixture({query=query}).query,'DELETE FROM inventory_items WHERE id=?',{fixtureId})
assert(not ok,'adapter whitelist must refuse unknown production SQL')
local damaged={ledger=copy(database.ledger[1]),receipt=copy(database.receipts[1]),items=copy(database.items),receiptCount=1}
damaged.items[1].original_metadata='bad JSON'
assert(not inspect(damaged).identityPreserved,'corrupt original metadata must fail closed')
run('observe','observe PASS')
local reduced=copy(database)
run('observe','observe BLOCKED')
assert(InventoryMetadata.DocumentsEqual(reduced,database),'repeat observe cannot spend fixture again')
dofile('server/services/character_ammunition.lua')
fixture,inspect=dofile('server/services/character_ammunition_enrollment_test.lua')
run('verifyobserve','done 6/6')
assert(InventoryMetadata.DocumentsEqual(reduced,database),'restart verification cannot change reduced fixture')
run('cleanup','cleanup PASS')
for _,rows in pairs(database) do assert(#rows==0) end
originalPrint('character ammo enrollment fixture PASS (SQL isolation, committed restart, duplicate refusal, cleanup)')
