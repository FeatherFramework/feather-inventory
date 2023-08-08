function CloseUI()
  SendNUIMessage({
    type = "toggleInventory",
    visible = false,
  })
end

function OpenUI()
  SendNUIMessage({
    type = "toggleInventory",
    visible = true
  })
end

-- Toggles the hotbar of the inventory
-- @param showHotbar boolean If true show hotbar
function ToggleHotbarDisplay(showHotbar)
  local playerItems = GetPlayerItems() -- Doesn't currently exist
  local hotbarItems = {}

  for i = 1, Config.hotbarLimit do
    table.insert(hotbarItems, playerItems[i])
  end

  local data = {}

  if showHotbar then
    data = {
      type = "toggleHotbar",
      visible = showHotbar,
      items = hotbarItems
    }
  else
    data = {
      type = "toggleHotbar",
      visible = showHotbar
    }
  end

  SendNUIMessage(data)
end
