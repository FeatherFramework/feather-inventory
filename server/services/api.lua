function StartAPI()
  local InventoryServerAPI = {}
  InventoryServerAPI.Inventory = InventoryAPI
  InventoryServerAPI.Items = ItemsAPI
  InventoryServerAPI.Weapons = WeaponsAPI

  exports('initiate', function()
    return InventoryServerAPI
  end)
end
