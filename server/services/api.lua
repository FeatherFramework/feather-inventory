function StartAPI()
  local InventoryServerAPI = {}
  InventoryServerAPI.Inventory = InventoryAPI
  InventoryServerAPI.Items = ItemsAPI
  InventoryServerAPI.Categories = CategoriesAPI

  exports('initiate', function()
    return InventoryServerAPI
  end)
end
