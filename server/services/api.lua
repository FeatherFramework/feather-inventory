function StartAPI()
  local InventoryServerAPI = {}
  InventoryServerAPI.Inventory = InventoryAPI
  InventoryServerAPI.Items = ItemsAPI
  InventoryServerAPI.Categories = CategoriesAPI

  RegisterCharacterStart(InventoryServerAPI)
  RegisterGroundInventory()

  exports('initiate', function()
    return InventoryServerAPI
  end)
end
