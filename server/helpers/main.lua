function FirstToUpper(str)
  return (str:gsub("^%l", string.upper))
end

-- Normalizes MySQL's various truthy/falsy representations (tinyint 0/1,
-- string "0"/"1"/"true"/"false", or a real Lua boolean if the driver's
-- typecasting returns one for TINYINT(1) columns) into real Lua booleans --
-- used wherever a DB-sourced flag like `is_public`/`ignore_item_limit`
-- needs a plain boolean comparison. Missing the `[true]`/`[false]` entries
-- meant a real boolean fell through to `nil`, and `nil == true` is `false`
-- -- e.g. a genuinely public inventory (`is_public` stored as `1`, read
-- back as boolean `true`) silently read as not public.
Boolean = {
  ["1"] = true,
  ["0"] = false,
  [1] = true,
  [0] = false,
  ["true"] = true,
  ["false"] = false,
  ["True"] = true,
  ["False"] = false,
  [true] = true,
  [false] = false
}

function TableContains(haystack, needle)
  return haystack[needle] ~= nil
end

-- (§10.1 debug cleanup) Replaces the scattered raw print("[DEBUG-GROUND] ...")
-- calls that were left in inventory_access.lua/inventory.lua/ground.lua from
-- building the robbery/ACL rewrite -- same idea as those, but gated behind
-- Config.Debug (default false) instead of always printing to the server
-- console, and using a consistent tag rather than a hardcoded one.
function DebugPrint(tag, fmt, ...)
  if not Config.Debug then
    return
  end
  print(('[%s] %s'):format(tag, fmt:format(...)))
end
