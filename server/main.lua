Feather = exports['feather-core'].initiate()

ServerReady = false

local function makeReady()
  StartAPI()

  ServerReady = true
end

makeReady()
