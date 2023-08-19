function FirstToUpper(str)
  return (str:gsub("^%l", string.upper))
end

Boolean = {
  ["1"] = true,
  ["0"] = false,
  [1] = true,
  [0] = false,
  ["true"] = true,
  ["false"] = false,
  ["True"] = true,
  ["False"] = false
}

function TableContains(haystack, needle)
  return haystack[needle] ~= nil
end
