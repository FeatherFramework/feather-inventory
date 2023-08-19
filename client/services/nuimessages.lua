function CloseUI()
  SendNUIMessage({
    type = "toggleInventory",
    visible = false,
  })
  SetNuiFocus(true, true)
end

function OpenUI()
  SendNUIMessage({
    type = "toggleInventory",
    visible = true,
    items = GetInventoryItems() -- ServerSide
  })
  SetNuiFocus(false, false)
end

-- function ToggleHotbarDisplay(showHotbar)
--   local playerItems = GetPlayerItems() -- Doesn't currently exist
--   local hotbarItems = {}

--   for i = 1, Config.hotbarLimit do
--     table.insert(hotbarItems, playerItems[i])
--   end

--   local data = {}

--   if showHotbar then
--     data = {
--       type = "toggleHotbar",
--       visible = showHotbar,
--       items = hotbarItems
--     }
--   else
--     data = {
--       type = "toggleHotbar",
--       visible = showHotbar
--     }
--   end

--   SendNUIMessage(data)
-- end
