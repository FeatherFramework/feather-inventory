InventoryMetadata = InventoryMetadata or {}

function InventoryMetadata.Decode(value)
    if value == nil or value == '' then return {} end
    if type(value) == 'table' then return value end
    local ok, decoded = pcall(json.decode, value)
    return ok and type(decoded) == 'table' and decoded or nil
end

function InventoryMetadata.DocumentsEqual(left, right)
    if type(left) ~= type(right) then return false end
    if type(left) ~= 'table' then return left == right end
    for key, value in pairs(left) do
        if not InventoryMetadata.DocumentsEqual(value, right[key]) then return false end
    end
    for key in pairs(right) do
        if left[key] == nil then return false end
    end
    return true
end

function InventoryMetadata.RowsCompatible(rows)
    if type(rows) ~= 'table' or #rows < 2 then return true end
    local expected = InventoryMetadata.Decode(rows[1].metadata)
    if not expected then return false end
    for index = 2, #rows do
        local document = InventoryMetadata.Decode(rows[index].metadata)
        if not document or not InventoryMetadata.DocumentsEqual(expected, document) then return false end
    end
    return true
end
