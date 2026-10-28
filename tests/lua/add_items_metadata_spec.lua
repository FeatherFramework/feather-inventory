local root = arg[1]
local command, grants, last = nil, 0, nil
Config = {DevMode = true}
AddEventHandler = function() end
RegisterCommand = function(name, fn, restricted)
    if name == 'AddItems' then assert(restricted); command = fn end
end
Result = {Codes = {INVALID_INPUT = 'invalid_input'},
    Err = function(code) return {ok = false, code = code} end,
    IsOk = function(value) return value.ok end}
ItemsAPI = {AddItem = function(name, quantity, metadata, source)
    grants = grants + 1
    last = {name = name, quantity = quantity, metadata = metadata, source = source}
    return {ok = true}
end}
Feather = {Notify = {RightNotify = function() end}}
Translate = function() return '' end
TranslateResult = function() return '' end
json = {decode = function(value)
    assert(value == '{"condition":1,"display":"Last use"}')
    return {condition = 1, display = 'Last use'}
end}
dofile(root .. '/server/services/commands.lua')
command(3, {'horsebrush', '1'}, 'AddItems horsebrush 1')
assert(grants == 1 and last.metadata == nil)
command(3, {'horsebrush', '1', '{"condition":1,"display":"Last', 'use"}'},
    'AddItems horsebrush 1 {"condition":1,"display":"Last use"}')
assert(grants == 2 and last.metadata.condition == 1 and last.metadata.display == 'Last use')
assert(last.name == 'horsebrush' and last.quantity == 1 and last.source == 3)
for _, value in ipairs({'broken', '[]', '{broken}', '{' .. string.rep('x', 4096)}) do
    command(3, {'horsebrush', '1', value}, 'AddItems horsebrush 1 ' .. value)
end
assert(grants == 2, 'invalid metadata must never grant an item')
Config.DevMode = false
command = nil
dofile(root .. '/server/services/commands.lua')
assert(command == nil)
print('PASS AddItems JSON metadata, spaces, invalid input and development/ACE gates')
