InventoryIdentity = {}

local function IsUuid(value)
  return type(value) == 'string' and value:match(
    '^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$'
  ) ~= nil
end

function InventoryIdentity.NormalizeCharacterId(value)
  if IsUuid(value) then return value:lower() end
  return nil
end

function InventoryIdentity.IsUuid(value)
  return IsUuid(value)
end

function InventoryIdentity.GetSession(src)
  local result = exports['feather-core']:GetSessionContext(tonumber(src))
  if type(result) ~= 'table' or result.ok ~= true or type(result.value) ~= 'table' then
    return Result.Err(Result.Codes.NOT_FOUND, 'A current character session is required.')
  end
  local characterId = InventoryIdentity.NormalizeCharacterId(result.value.characterId)
  if not characterId then
    return Result.Err(Result.Codes.INVALID_INPUT, 'The current character identity is unsupported.')
  end
  local session = result.value
  session.characterId = characterId
  return Result.Ok(session)
end

function InventoryIdentity.GetCharacter(src)
  local session = InventoryIdentity.GetSession(src)
  if not Result.IsOk(session) then return nil end
  local value = session.value
  local provider = exports['feather-core']:GetProvider('character-profile', nil, 1)
  if type(provider) ~= 'table' or provider.ok ~= true then return nil end
  local profile = provider.value.implementation.GetProfile(value.characterId)
  if type(profile) ~= 'table' or profile.ok ~= true then return nil end
  local character = profile.value
  character.id = character.characterId
  character.first_name = character.firstName
  character.last_name = character.lastName
  character.dob = character.dateOfBirth
  return { char = character, session = value }
end

function InventoryIdentity.GetPosition(src)
  local ped = GetPlayerPed(tonumber(src))
  if not ped or ped <= 0 then return nil end
  local coords = GetEntityCoords(ped)
  if not coords then return nil end
  return tonumber(coords.x), tonumber(coords.y), tonumber(coords.z)
end
