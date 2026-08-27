-- Inventory-owned client runtime helpers. These intentionally expose only the
-- small gameplay surface used by this resource instead of importing Core's
-- legacy aggregate API.

Feather.KeyCodes = {
  A = 0x7065027D, B = 0x4CC0E2FE, C = 0x9959A6F0, D = 0xB4E465B4,
  E = 0xCEFD9220, F = 0xB2F377E8, G = 0x760A9C6F, H = 0x24978A28,
  I = 0xC1989F95, J = 0xF3830D8E, L = 0x80F28E95, M = 0xE31C6A41,
  N = 0x4BC9DABB, O = 0xF1301666, P = 0xD82E0BD2, Q = 0xDE794E3E,
  R = 0xE30CD707, S = 0xD27782E3, U = 0xD8F73058, V = 0x7F8D09B8,
  W = 0x8FD015D8, X = 0x8CC9CD42, Z = 0x26E9DC00,
  RIGHTBRACKET = 0xA5BDCD3C, LEFTBRACKET = 0x430593AA,
  MOUSE1 = 0x07CE1E61, MOUSE2 = 0xF84FA74F, MOUSE3 = 0xCEE12B50,
  MWUP = 0x3076E97C, CTRL = 0xDB096B85, TAB = 0xB238FE0B,
  SHIFT = 0x8FFC75D6, SPACEBAR = 0xD9D0E1C0, ENTER = 0xC7B5340A,
  BACKSPACE = 0x156F7119, LALT = 0x8AAA0AD4, DEL = 0x4AF4D473,
  PGUP = 0x446258B6, PGDN = 0x3C3DD371, F1 = 0xA8E3F467,
  F4 = 0x1F6D95E5, F6 = 0x3C0A40F2, ['1'] = 0xE6F612E4,
  ['2'] = 0x1CE6D9EB, ['3'] = 0x4F49CC4C, ['4'] = 0x8F9F9E58,
  ['5'] = 0xAB62E997, ['6'] = 0xA1FDE2A6, ['7'] = 0xB03A913B,
  ['8'] = 0x42385422, DOWN = 0x05CA7C52, UP = 0x6319DB71,
  LEFT = 0xA65EBAB4, RIGHT = 0xDEB34313
}

local keyListeners = {}
local keyThreadStarted = false

Feather.Keys = {}

function Feather.Keys:RegisterListener(keyName, callback)
  local keyHash = Feather.KeyCodes[keyName]
  if keyHash == nil or type(callback) ~= 'function' then return nil end

  keyListeners[keyName] = keyListeners[keyName] or {}
  local listeners = keyListeners[keyName]
  listeners[#listeners + 1] = callback
  local listenerIndex = #listeners

  if not keyThreadStarted then
    keyThreadStarted = true
    CreateThread(function()
      while true do
        Wait(4)
        for registeredName, registeredListeners in pairs(keyListeners) do
          local registeredHash = Feather.KeyCodes[registeredName]
          local pressed = Citizen.InvokeNative(0x580417101DDB492F, 0, registeredHash)
            or Citizen.InvokeNative(0x91AEF906BCA88877, 0, registeredHash)
          if pressed then
            for _, registeredCallback in pairs(registeredListeners) do
              local ok, err = pcall(registeredCallback)
              if not ok then
                print(('[feather-inventory] key listener failed key=%s error=%s'):format(
                  tostring(registeredName), tostring(err)))
              end
            end
          end
        end
      end
    end)
  end

  return {
    RemoveListener = function()
      if listeners[listenerIndex] == nil then return false end
      listeners[listenerIndex] = nil
      return true
    end
  }
end

Feather.Math = {
  GetDistanceBetween = function(first, second)
    return #(first - second)
  end
}

Feather.Object = {}

function Feather.Object:Create(modelName, x, y, z, heading, networked)
  local hash = type(modelName) == 'number' and modelName or GetHashKey(modelName or 'p_package09')
  RequestModel(hash)
  while not HasModelLoaded(hash) do Wait(10) end

  local entity = CreateObject(hash, x, y, z, networked ~= false)
  SetEntityHeading(entity, heading or 0.0)
  PlaceObjectOnGroundProperly(entity, true)
  FreezeEntityPosition(entity, true)

  return {
    GetObj = function() return entity end,
    SetAsMission = function(_, state) SetEntityAsMissionEntity(entity, state ~= false) end,
    Freeze = function(_, state) FreezeEntityPosition(entity, state ~= false) end,
    Remove = function() DeleteObject(entity) end
  }
end

Feather.Prompt = {}

function Feather.Prompt:SetupPromptGroup(groupId)
  local group = { id = groupId or GetRandomIntInRange(0, 0xffffff) }

  function group:ShowGroup(text)
    PromptSetActiveGroupThisFrame(
      self.id,
      CreateVarString(10, 'LITERAL_STRING', text or 'Prompt Info'),
      1,
      0
    )
  end

  function group:RegisterPrompt(title, button, enabled, visible, pulsing, mode, options)
    local handle = PromptRegisterBegin()
    PromptSetControlAction(handle, button or 0x4CC0E2FE)
    PromptSetText(handle, CreateVarString(10, 'LITERAL_STRING', title or 'Title'))
    PromptSetEnabled(handle, enabled ~= false)
    PromptSetVisible(handle, visible ~= false)
    PromptSetGroup(handle, self.id, 0)

    if mode == 'hold' then
      Citizen.InvokeNative(0x74C7D7B72ED0D3CF, handle,
        options and options.timedeventhash or 'MEDIUM_TIMED_EVENT')
    elseif mode == 'click' then
      PromptSetStandardMode(handle, true)
    end

    Citizen.InvokeNative(0xC5F428EE08FA7F2C, handle, pulsing ~= false)
    PromptRegisterEnd(handle)

    return {
      HasCompleted = function()
        if mode == 'click' then
          return Citizen.InvokeNative(0xC92AC953F0A982AE, handle)
        end
        local completed = Citizen.InvokeNative(0xE0F65F0640EF0617, handle)
        if completed then Wait(500) end
        return completed
      end,
      -- Hold and click prompts do not have a failure state. Ground-item
      -- pickup still checks this method each frame, so keep the method in
      -- the local prompt contract instead of letting that thread terminate.
      HasFailed = function()
        return false
      end,
      TogglePrompt = function(_, state)
        Citizen.InvokeNative(0x71215ACCFDE075EE, handle, state == true)
      end,
      EnabledPrompt = function(_, state)
        PromptSetEnabled(handle, state == true)
      end,
      DeletePrompt = function() Citizen.InvokeNative(0x00EDE88D4D13CF59, handle) end
    }
  end

  return group
end
