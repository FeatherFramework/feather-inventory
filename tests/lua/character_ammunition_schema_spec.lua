local root=arg and arg[1] or '.'
local f=assert(io.open(root..'/database/character_ammunition.sql','r'));local source=f:read('*a');f:close()
local ledger,receipts='feather_character_ammunition','feather_ammunition_operations'
local function fixture(mode)
 Config={CharacterAmmunitionEnabled=true}
 local state={tables={},creates=0,reads=0,existingBalances={character={revision=57,pools='saved-pools'}},existingReceipts={operation='saved-result'}}
 local balances,receipt=state.existingBalances.character,state.existingReceipts.operation
 if mode~='fresh' then state.tables[ledger]=true;state.tables[receipts]=true end
 if mode=='partial' then state.tables[receipts]=nil end
 GetCurrentResourceName=function() return 'feather-inventory' end
 LoadResourceFile=function(resource,path)
  assert(resource=='feather-inventory' and path=='database/character_ammunition.sql')
  if mode=='missing-file' then return nil end
  if mode=='invalid-file' then return source..'DELETE FROM items' end
  return source
 end
 DB={exec=function(sql)
  assert(not sql:find('INSERT',1,true) and not sql:find('UPDATE',1,true) and not sql:find('DELETE',1,true) and not sql:find('ALTER',1,true))
  local name=assert(sql:match('^%s*CREATE TABLE IF NOT EXISTS ([%w_]+)'))
  assert(name==ledger or name==receipts)
  if mode=='denied' then error('database_permission_denied') end
  if mode=='false-ddl' then return false end
  state.creates=state.creates+1;state.tables[name]=true
  return 0
 end,query=function(sql,a,b)
  assert(a==ledger and b==receipts and state.tables[ledger] and state.tables[receipts])
  state.reads=state.reads+1
  if mode=='read-failure' then error('schema_read_failed') end
  if sql:find('information_schema.TABLES',1,true) then
   return {{table_name=ledger,engine=mode=='engine' and 'MyISAM' or 'InnoDB'},{table_name=receipts,engine='InnoDB'}}
  end
  if sql:find('information_schema.COLUMNS',1,true) then
   local result={}
   local function column(tableName,name,dataType,length,ctype,default,collation)
    result[#result+1]={table_name=tableName,column_name=name,data_type=dataType,maximum_length=length,
     column_type=ctype or dataType,nullable='NO',default_value=default,collation_name=collation}
   end
   column(ledger,'character_id','char',36);column(ledger,'revision','bigint',nil,'bigint(20) unsigned','0')
   column(ledger,'pools','longtext');column(ledger,'migrated_at','timestamp',nil,nil,'current_timestamp()')
   column(receipts,'character_id','char',36);column(receipts,'operation_id','varchar',64,nil,nil,'ascii_bin')
   column(receipts,'result','longtext');column(receipts,'created_at','timestamp',nil,nil,'CURRENT_TIMESTAMP')
   if mode=='missing-column' then table.remove(result,3) end
   if mode=='signed-revision' then result[2].column_type='bigint(20)' end
   if mode=='revision-default' then result[2].default_value='1' end
   if mode=='nullable' then result[3].nullable='YES' end
   if mode=='short-id' then result[1].maximum_length=32 end
   if mode=='operation-collation' then result[6].collation_name='ascii_general_ci' end
   if mode=='timestamp-default' then result[4].default_value=nil end
   return result
  end
  assert(sql:find('information_schema.STATISTICS',1,true))
  local result={{table_name=ledger,index_name='PRIMARY',non_unique=0,sequence_number=1,column_name='character_id'},
   {table_name=receipts,index_name='PRIMARY',non_unique=0,sequence_number=1,column_name='character_id'},
   {table_name=receipts,index_name='PRIMARY',non_unique=0,sequence_number=2,column_name='operation_id'}}
  if mode=='prefix-key' then result[3].prefix_length=10 end
  if mode=='wrong-key' then result[3].column_name='result' end
  if mode=='missing-key' then table.remove(result,1) end
  return result
 end}
 dofile(root..'/server/services/character_ammunition_schema.lua')
 return state,function()
  assert(state.existingBalances.character==balances and balances.revision==57 and balances.pools=='saved-pools')
  assert(state.existingReceipts.operation==receipt)
 end
end
for _,mode in ipairs({'fresh','existing','partial'}) do
 local state,preserved=fixture(mode)
 assert(InventoryCharacterAmmoSchema.Start());assert(state.creates==2 and state.reads==3);preserved()
 assert(InventoryCharacterAmmoSchema.Start() and state.creates==2,'no repeated schema work in a ready resource')
 dofile(root..'/server/services/character_ammunition_schema.lua')
 assert(InventoryCharacterAmmoSchema.Start() and state.creates==4,'restart safely verifies existing tables');preserved()
end
for _,mode in ipairs({'engine','missing-column','signed-revision','revision-default','nullable','short-id',
 'operation-collation','timestamp-default','prefix-key','wrong-key','missing-key','denied','false-ddl','read-failure','missing-file','invalid-file'}) do
 local state,preserved=fixture(mode)
 local ok,reason=pcall(InventoryCharacterAmmoSchema.Start)
 assert(not ok and type(reason)=='string',mode);preserved()
 if mode=='missing-file' or mode=='invalid-file' then assert(state.creates==0,'validate source before any DDL') end
end
local state=fixture('missing-file');Config.CharacterAmmunitionEnabled=false
assert(InventoryCharacterAmmoSchema.Start() and state.creates==0 and state.reads==0)
print('PASS ammunition startup schema: fresh/partial/existing/restart, preservation, no gameplay writes, packaged source, strict schema refusal and disabled gate (mocked DB)')
