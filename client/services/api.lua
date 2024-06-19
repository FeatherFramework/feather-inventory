function StartAPI()
  local inventoryClientApi = {}

  inventoryClientApi.Action = InventoryAction

  exports('initiate', function()
    return inventoryClientApi
  end)
end
