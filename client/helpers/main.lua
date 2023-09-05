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

function GetPedInFront()
  local player = PlayerId()
  local plyPed = GetPlayerPed(player)
  local plyPos = GetEntityCoords(plyPed, false)
  local plyOffset = GetOffsetFromEntityInWorldCoords(plyPed, 0.0, 1.3, 0.0)
  local rayHandle = StartShapeTestCapsule(plyPos.x, plyPos.y, plyPos.z, plyOffset.x, plyOffset.y, plyOffset.z, 1.0, 12,
    plyPed, 7)
  local _, _, _, _, ped = GetShapeTestResult(rayHandle)
  return ped
end

function GetPlayerFromPed(ped)
  for a = 0, 64 do
    if GetPlayerPed(a) == ped then
      return a
    end
  end
  return -1
end
