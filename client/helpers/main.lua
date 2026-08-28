function IsTable(var)
  return type(var) == 'table'
end

---
-- Translate
--
-- (§10.2 locale migration) Client-side counterpart of the server helper in
-- server/helpers/main.lua -- see that one for why the fallback exists
-- (Feather.Locale.translate returns a literal "does not exist" sentinel
-- string for an unregistered key, not nil, so a missing key would otherwise
-- be rendered to the player verbatim).
--
-- `src` is meaningless client-side; the language comes from the locale
-- service's own client cache, so 0 is passed purely to satisfy the shared
-- signature.
--
-- CONSTRAINT: no value in translations/ may contain a `%` format directive
-- unless every caller of that key passes matching arguments. LocalesAPI.
-- translate unconditionally runs string.format on the result, so a `%s` in
-- a string resolved without arguments raises "bad argument #2 to 'format'".
-- The pcall below keeps that from breaking the caller, but CitizenFX still
-- prints the traceback, so it must be avoided rather than caught -- see the
-- `{n}` convention on ui_how_many/ui_use_all in translations/en_us.lua.
--
-- @param key Locale key (see translations/)
-- @param fallback Text to use if the key isn't registered
-- @return Localized string, or fallback
--
function Translate(key, fallback)
  if not key then
    return fallback
  end

  local ok, translated = pcall(Feather.Locale.translate, 0, key)
  if not ok or type(translated) ~= 'string' or translated:find('does not exist', 1, true) then
    return fallback
  end
  return translated
end

-- Only meaningful for a table with no gaps in its integer keys.
function IsArray(t)
  local i = 0
  for _ in pairs(t) do
    i = i + 1
    if t[i] == nil then return false end
  end
  return true
end

-- Raycasts a capsule shape in front of the player to find whichever ped is
-- standing there -- the "give item to the ped in front of you" targeting
-- used by the GiveItem NUI action (client/services/nuicallbacks.lua).
--
-- GetShapeTestResult isn't ready the same tick StartShapeTestCapsule fires
-- -- calling it immediately returned status 1 ("still pending") on every
-- call, with `ped` always 0, so GiveItem read this as "no one in front of
-- you" no matter what. Poll until the test actually resolves (status 0 or
-- 2) instead of reading it once.
function GetPedInFront()
  local player = PlayerId()
  local plyPed = GetPlayerPed(player)
  local plyPos = GetEntityCoords(plyPed, false)
  local plyOffset = GetOffsetFromEntityInWorldCoords(plyPed, 0.0, 1.3, 0.0)
  local rayHandle = StartShapeTestCapsule(plyPos.x, plyPos.y, plyPos.z, plyOffset.x, plyOffset.y, plyOffset.z, 1.0, 12,
    plyPed, 7)

  local retval, hit, endCoords, surfaceNormal, ped
  repeat
    Wait(0)
    retval, hit, endCoords, surfaceNormal, ped = GetShapeTestResult(rayHandle)
  until retval ~= 1

  return ped
end

-- Maps a ped entity back to its server id (the `source` every server-side
-- RPC/callback actually expects), if it's a player ped at all -- returns
-- -1 for an NPC.
--
-- `a` here is a client-side player INDEX (what GetPlayerPed/PlayerId deal
-- in), not a server id -- those are two different numbering spaces. This
-- used to return the raw index straight to the server, which then called
-- Feather.Character.GetCharacter({ src = <that index> }) expecting a
-- server id, resolving nobody and rejecting every give with "That player
-- is not available." regardless of who was actually standing there.
-- GetPlayerServerId converts the index into the server id.
function GetPlayerFromPed(ped)
  for a = 0, 64 do
    if GetPlayerPed(a) == ped then
      return GetPlayerServerId(a)
    end
  end
  return -1
end
