function IsTable(var)
  return type(var) == 'table'
end

function IsArray(t)
  local i = 0
  for _ in pairs(t) do
    i = i + 1
    if t[i] == nil then return false end
  end
  return true
end
