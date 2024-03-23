function StartAPI()
  InventoryClientApi = {}

  InventoryClientApi.Action = InventoryAction

  exports('initiate', function()
    return InventoryClientApi
  end)
end
