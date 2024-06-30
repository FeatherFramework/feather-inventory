function StartAPI()
  local inventoryServerAPI = {}
  inventoryServerAPI.Inventory = InventoryAPI
  inventoryServerAPI.Items = ItemsAPI
  inventoryServerAPI.Categories = CategoriesAPI

  exports('initiate', function()
    return inventoryServerAPI
  end)

  RegisterCharacterStart(inventoryServerAPI)
  RegisterGroundInventory()
end
