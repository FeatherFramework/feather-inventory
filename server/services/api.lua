function StartAPI()
  local inventoryServerAPI = {}
  inventoryServerAPI.Inventory = InventoryAPI
  inventoryServerAPI.Items = ItemsAPI
  inventoryServerAPI.Categories = CategoriesAPI
  -- (INV-W1) Item-instance contract layer -- instance_mode, versioned
  -- metadata documents, normalized reads, capability query.
  inventoryServerAPI.Instances = InstancesAPI

  exports('initiate', function()
    return inventoryServerAPI
  end)

  RegisterCharacterStart(inventoryServerAPI)
  RegisterGroundInventory()
end
