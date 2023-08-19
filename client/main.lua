Feather = exports['feather-core'].initiate()
ClientReady = false

local function makeReady()
  StartAPI()

  ClientReady = true
end

makeReady()
