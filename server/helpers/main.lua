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

---
-- Translate
--
-- (§10.2 locale migration) Resolves a locale key in the caller's own
-- language, falling back to `fallback` when the key isn't registered.
--
-- The fallback matters more than it looks: Feather.Locale.translate returns a
-- literal sentinel STRING for a missing key or locale ("Translation [en_us]
-- [foo] does not exist"), not nil -- so without this check a typo'd or
-- unregistered key would be shown to the player verbatim, which is strictly
-- worse than showing untranslated English.
--
-- CONSTRAINT: no value in translations/ may contain a `%` format directive
-- unless every caller of that key passes matching arguments -- LocalesAPI.
-- translate unconditionally string.formats the result, and a `%s` resolved
-- without arguments raises "bad argument #2 to 'format'". The pcall below
-- stops that breaking the caller, but CitizenFX prints the traceback
-- regardless, so it has to be avoided rather than caught. See the `{n}`
-- convention documented in translations/en_us.lua.
--
-- @param src Player source, used to resolve their language
-- @param key Locale key (see translations/)
-- @param fallback Text to use if the key isn't registered
-- @return Localized string, or fallback
--
function Translate(src, key, fallback)
  if not key then
    return fallback
  end

  local ok, translated = pcall(Feather.Locale.translate, src, key)
  if not ok or type(translated) ~= 'string' or translated:find('does not exist', 1, true) then
    return fallback
  end
  return translated
end

---
-- Translate Result
--
-- Localizes a result envelope for display: prefers the stable `code`
-- (err_<code> in translations/) and falls back to the envelope's own
-- developer-facing English `message`. That indirection is the point -- the
-- text a player sees is decoupled from the message string services return for
-- logs and scripting consumers, so neither has to compromise for the other.
--
-- @param src Player source
-- @param result A { code = ..., message = ... } envelope
-- @param fallbackKey Locale key to use when the envelope carries no code
-- @return Localized string suitable for Feather.Notify
--
-- Resolves a player-facing string from either a result envelope or one of the
-- older `{ code, message }` tables the RPC layer still builds for the NUI.
--
-- Accepting both is deliberate and is NOT a compatibility shim: the envelope
-- is the API contract, while the NUI payloads are an internal protocol that
-- deliberately keeps its own shape. This helper sits exactly on that seam.
--
-- A refusal envelope (`Ok{ accepted = false, code }`) carries its code in
-- `value`, while a failure envelope carries it in `error` -- both mean "tell
-- the player why", so both resolve here.
function TranslateResult(src, result, fallbackKey)
  if type(result) == 'table' and result.ok ~= nil then
    result = (result.ok and result.value) or result.error or {}
  end

  local message = result and result.message
  local code = result and result.code

  if code then
    return Translate(src, 'err_' .. code, message or Translate(src, fallbackKey, message))
  end

  return Translate(src, fallbackKey, message or '')
end
