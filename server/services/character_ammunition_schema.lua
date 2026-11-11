-- Startup only: no enrollment, balance/receipt mutation, or automatic repair.
InventoryCharacterAmmoSchema={}
local S=InventoryCharacterAmmoSchema
local ready=false
local names={'feather_character_ammunition','feather_ammunition_operations'}
local expected={
 feather_character_ammunition={character_id={'char',36},revision={'bigint',nil,true},pools={'longtext'},migrated_at={'timestamp'}},
 feather_ammunition_operations={character_id={'char',36},operation_id={'varchar',64},result={'longtext'},created_at={'timestamp'}}}
local function requireSchema(condition,detail)
 assert(condition,'Character ammunition schema unavailable: '..detail..'. Existing data was not repaired.')
end
function S.Start()
 if ready then return true end
 if Config.CharacterAmmunitionEnabled~=true then return true end
 local sql=LoadResourceFile(GetCurrentResourceName(),'database/character_ammunition.sql')
 requireSchema(type(sql)=='string' and #sql>0,'packaged database/character_ammunition.sql is missing')
 local statements={}
 sql=sql:gsub('%-%-[^\r\n]*','')
 for statement in sql:gmatch('([^;]+);') do statements[#statements+1]=statement end
 requireSchema(#statements==2 and sql:gsub('[^;]+;',''):match('^%s*$'),
  'packaged schema must contain exactly two table definitions')
 for index,statement in ipairs(statements) do
  requireSchema(statement:match('^%s*CREATE TABLE IF NOT EXISTS ([%w_]+)')==names[index],
   'packaged table definition is invalid')
 end
 for _,statement in ipairs(statements) do
  requireSchema(DB.exec(statement)~=false,'table creation was refused')
 end
 local tables=DB.query([[SELECT TABLE_NAME AS table_name,ENGINE AS engine FROM information_schema.TABLES
  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME IN (?,?)]],table.unpack(names))
 local engines={}
 for _,row in ipairs(tables or {}) do engines[row.table_name]=row.engine end
 for _,name in ipairs(names) do requireSchema(engines[name]=='InnoDB',name..' requires InnoDB') end
 local columns=DB.query([[SELECT TABLE_NAME AS table_name,COLUMN_NAME AS column_name,DATA_TYPE AS data_type,
  COLUMN_TYPE AS column_type,CHARACTER_MAXIMUM_LENGTH AS maximum_length,IS_NULLABLE AS nullable,
  COLUMN_DEFAULT AS default_value,COLLATION_NAME AS collation_name FROM information_schema.COLUMNS
  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME IN (?,?)]],table.unpack(names))
 local found={}
 for _,row in ipairs(columns or {}) do
  local wanted=expected[row.table_name] and expected[row.table_name][row.column_name]
  if wanted then
   requireSchema(row.data_type==wanted[1] and row.nullable=='NO'
    and (not wanted[2] or tonumber(row.maximum_length)==wanted[2])
    and (not wanted[3] or type(row.column_type)=='string' and row.column_type:find('unsigned',1,true)),
    row.table_name..'.'..row.column_name..' has an incompatible definition')
   if row.data_type=='timestamp' then
    requireSchema(type(row.default_value)=='string' and row.default_value:lower():gsub('%(%d*%)','')=='current_timestamp',
     row.column_name..' requires a current timestamp default')
   end
   if row.column_name=='revision' then requireSchema(tonumber(row.default_value)==0,'revision default must be zero') end
   if row.column_name=='operation_id' then requireSchema(row.collation_name=='ascii_bin','operation_id requires ascii_bin') end
   found[row.table_name..'.'..row.column_name]=true
  end
 end
 for name,fields in pairs(expected) do
  for field in pairs(fields) do requireSchema(found[name..'.'..field],name..'.'..field..' is missing') end
 end
 local indexes=DB.query([[SELECT TABLE_NAME AS table_name,INDEX_NAME AS index_name,NON_UNIQUE AS non_unique,
  SEQ_IN_INDEX AS sequence_number,SUB_PART AS prefix_length,COLUMN_NAME AS column_name FROM information_schema.STATISTICS
  WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME IN (?,?) AND INDEX_NAME='PRIMARY'
  ORDER BY TABLE_NAME,SEQ_IN_INDEX]],table.unpack(names))
 local keys={}
 for _,row in ipairs(indexes or {}) do
  requireSchema(tonumber(row.non_unique)==0 and row.prefix_length==nil,'primary key must be unique and unprefixed')
  keys[row.table_name]=keys[row.table_name] or {}
  keys[row.table_name][tonumber(row.sequence_number)]=row.column_name
 end
 for index,name in ipairs(names) do
  local key=keys[name] or {}
  requireSchema(table.concat(key,',')==(index==1 and 'character_id' or 'character_id,operation_id'),
   name..' primary key is incompatible')
 end
 ready=true
 print('[feather-inventory] Shared ammunition schema ready; existing balances and receipts preserved.')
 return true
end
