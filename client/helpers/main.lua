function IsTable(var)
  return type(var) == 'table'
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

-- Maps a ped entity back to its owning player index (server-adjacent id),
-- if it's a player ped at all -- returns -1 for an NPC.
function GetPlayerFromPed(ped)
  for a = 0, 64 do
    if GetPlayerPed(a) == ped then
      return a
    end
  end
  return -1
end
