function StartAPI()
  local InventoryClientApi = {}

  -- Checks if a player has a specific item or items.
  -- @params items table<string, number>
  -- @return boolean success Retruns true if the player has the item
  InventoryClientApi.playerHasItems = function(items)
    local numberOfItems = #items
    local count = 0
    local playerItems = GetPlayerItems()

    -- Error Checks
    if not IsTable(items) then
      error('items must be a table! e.g. {{name = "apple", quantity = 2}, {name = "lemon", quantity = 1}}')
      return false
    end

    for _, v in pairs(items) do
      if not IsTable(v) then
        error('items must be a table! e.g. {{name = "apple", quantity = 2}, {name = "lemon", quantity = 1}}')
        return false
      end

      if v.name == nil or tonumber(v.quantity) == nil then
        error('items must be a table! e.g. {{name = "apple", quantity = 2}, {name = "lemon", quantity = 1}}')
        return false
      end
    end

    for _, playerItem in pairs(playerItems) do
      for _, requestedItem in pairs(items) do
        if playerItem and requestedItem.name == playerItem.name and playerItem.quantity >= tonumber(requestedItem.quantity) then
          count = count + 1
        end
      end
    end

    if count < numberOfItems then return false end

    return true
  end

  exports('initiate', function()
    return InventoryClientApi
  end)
end

local table = {
  {
    name = "test",
    quantity = 5
  }
}
