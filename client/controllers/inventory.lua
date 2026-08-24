local isInvOpen = false
-- local isHBOpen = false

InventoryAction = {}

-- (§10.2 locale migration) Every label the ledger UI renders, resolved in the
-- player's language here and handed to the NUI as a plain key->string bundle.
--
-- Deliberately resolved Lua-side rather than shipping a second locale system
-- into JavaScript: translations/ stays the single source of truth for every
-- user-facing string in this resource, and the Vue layer just renders what
-- it's given. Templates containing %s (ui_how_many, ui_use_all) are passed
-- through unformatted -- the UI substitutes them, since only it knows the
-- runtime value.
local UI_STRING_KEYS = {
  'ui_personal_effects', 'ui_storage', 'ui_carrying', 'ui_stored', 'ui_all',
  'ui_use', 'ui_give', 'ui_drop', 'ui_split', 'ui_cancel', 'ui_confirm',
  'ui_quantity', 'ui_weight', 'ui_how_many', 'ui_use_all', 'ui_invalid_amount',
  'ui_no_entry',
  'ui_take_all',
  'ui_condition', 'ui_condition_pristine', 'ui_condition_worn',
  'ui_condition_damaged', 'ui_condition_ruined',
  'ui_paired_hint',
}

-- (§10.3) Condition wear stages, thresholds from Config and labels resolved
-- through the locale like every other UI string. Sent once per open rather
-- than per item -- the UI picks the matching stage from an item's condition
-- value itself, so this doesn't grow with inventory size.
local function BuildConditionStages()
  local stages = {}
  for _, stage in ipairs((Config.Condition and Config.Condition.Stages) or {}) do
    stages[#stages + 1] = {
      at = tonumber(stage.at) or 0,
      label = Translate(stage.label, nil)
    }
  end
  return stages
end

local function BuildUIStrings()
  local strings = {}
  for _, key in ipairs(UI_STRING_KEYS) do
    -- No fallback text here on purpose: the Vue side carries its own English
    -- defaults, so a key missing from translations/ degrades to the UI's
    -- literal rather than to an empty label.
    strings[key] = Translate(key, nil)
  end
  return strings
end

function CanOpenInventory()
  if IsEntityDead(PlayerPedId()) then return false end
  if IsPauseMenuActive() then return false end
  -- TODO: Add check for different states where inventory can't open like Handcuffed/HogTied/KnockedOut
  return true
end

-- Opens the inventory NUI: fetches the player's own items plus, if
-- `otherInventoryId` is given, a second inventory (ground pile, storage
-- box, another player) side-by-side -- both come back from a single
-- GetInventoryItems RPC round-trip (server/services/callbacks.lua), which
-- is also where the "other" inventory gets locked to this player via
-- OpenInventories so nobody else can open it concurrently.
InventoryAction.Open = function(otherInventoryId, target)
  if target == nil then
    target = "storage"
  end

  print('Opening Inventory', otherInventoryId or 'character')
  -- OpenInventory is also the post-use refresh signal. Refetch while the UI
  -- is already open so consumed items and changed quantities repaint.
  if CanOpenInventory() then
    local results = Feather.RPC.CallAsync('Feather:Inventory:GetInventoryItems', { otherInventoryId = otherInventoryId })
    if results.error ~= nil then
      -- Localized off the server's stable errorCode, falling back to the
      -- English `error` string it has always sent (§10.2).
      Feather.Notify.RightNotify(Translate('err_' .. tostring(results.errorCode or ''), results.error), 3000)
      return
    end

    isInvOpen = true

    local player_display = Feather.RPC.CallAsync('Feather:Inventory:GetCharacterInfoForDisplay')
    
    SendNUIMessage({
      type = "toggleInventory",
      target = target,
      visible = true,
      playerInventory = results.inventory,
      playerItems = results.inventoryItems,
      playerIgnoreLimits = results.inventoryIgnoreLimits or 0,
      otherInventory = results.otherInventory,
      otherItems = results.otherInventoryItems,
      otherIgnoreLimits = results.otherInventoryIgnoreLimits,
      otherName = results.otherName,
      maxWeight = Config.maxWeight,
      -- (§10.4) Per-book capacity, resolved server-side from each inventory's
      -- own max_slots (falling back to Config.maxItemSlots when unset). This
      -- was one global Config value for both books, which meant a large
      -- storage container rendered at the player book's size. `maxSlots` is
      -- kept as a fallback for the player book so an older server that
      -- doesn't send the new field still renders something sane.
      maxSlots = Config.maxItemSlots,
      playerMaxSlots = results.inventoryMaxSlots,
      otherMaxSlots = results.otherInventoryMaxSlots,
      playerMaxWeight = results.inventoryMaxWeight,
      otherMaxWeight = results.otherInventoryMaxWeight,
      strings = BuildUIStrings(),
      -- (§10.3) Wear stages resolved here rather than duplicated in JS --
      -- thresholds come from Config, labels through the same locale path as
      -- every other UI string.
      conditionStages = BuildConditionStages(),
      conditionMax = (Config.Condition and Config.Condition.Max) or 100,
      categories = Feather.RPC.CallAsync('Feather:Inventory:GetCategories', {}),
      player = {
        dollars = player_display.dollars,
        gold = player_display.gold,
        tokens = player_display.tokens,
        id = player_display.id,
        characterName = ((player_display.firstName or '') .. ' ' .. (player_display.lastName or '')):gsub('^%s+', ''):gsub('%s+$', '')
      }
    })
    SetNuiFocus(true, true)
  end
end

InventoryAction.Close = function()
  if isInvOpen then
    SetNuiFocus(false, false)
    isInvOpen = false

    Feather.RPC.CallAsync('Feather:Inventory:Server:CloseInventory', {})
  end
end

RegisterNetEvent('Feather:Inventory:OpenInventory', function(otherInventoryId, target)
  InventoryAction.Open(otherInventoryId, target)
end)

RegisterNetEvent('Feather:Inventory:CloseInventory', function()
  InventoryAction.Close()
end)

-- function IsHotbarOpen()
--   return isHBOpen
-- end

-- function ToggleHotbar()
--   isHBOpen = not isHBOpen
--   ToggleHotbarDisplay(isHBOpen)
-- end
