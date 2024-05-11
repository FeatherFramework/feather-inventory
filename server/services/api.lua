function StartAPI()
  local inventoryServerAPI = {}
  inventoryServerAPI.Inventory = InventoryAPI
  inventoryServerAPI.Items = ItemsAPI
  inventoryServerAPI.Categories = CategoriesAPI

  RegisterCharacterStart(inventoryServerAPI)
  RegisterGroundInventory()

  exports('initiate', function()
    return inventoryServerAPI
  end)
end
