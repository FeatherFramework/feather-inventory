local function loadAnimDict(dict)
  if HasAnimDictLoaded(dict) then return end

  RequestAnimDict(dict)
  while not HasAnimDictLoaded(dict) do
    Wait(10)
  end
end

function PlayOpenAnimation()
  loadAnimDict('pickup_object')
  TaskPlayAnim(PlayerPedId(), 'pickup_object', 'putdown_low', 5.0, 1.5, 1.0, 48, 0.0, false, false, false)
end
