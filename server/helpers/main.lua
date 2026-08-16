function FirstToUpper(str)
  return (str:gsub("^%l", string.upper))
end

-- Normalizes MySQL's various truthy/falsy representations (tinyint 0/1,
-- string "0"/"1"/"true"/"false") into real Lua booleans -- used wherever a
-- DB-sourced flag like `ignore_item_limit` needs a plain boolean comparison.
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
