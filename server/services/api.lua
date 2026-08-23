function StartAPI()
  local inventoryServerAPI = {}
  inventoryServerAPI.Inventory = InventoryAPI
  inventoryServerAPI.Items = ItemsAPI
  inventoryServerAPI.Categories = CategoriesAPI
  -- (INV-W1) Item-instance contract layer -- instance_mode, versioned
  -- metadata documents, normalized reads, capability query.
  inventoryServerAPI.Instances = InstancesAPI
  -- (INV-W2) Transaction runner. Also surfaced as Inventory.Transaction,
  -- the interface name DEPENDENCY_SUPPORT_PLAN §4.4 specifies.
  inventoryServerAPI.Transaction = TransactionAPI.Transaction
  -- (INV-W3) Pre-move/destroy guard registry and structured post-commit
  -- events. This is how feather-weapons forces an authoritative unequip
  -- before an equipped item is allowed to move.
  inventoryServerAPI.Guards = GuardsAPI

  exports('initiate', function()
    return inventoryServerAPI
  end)

  RegisterCharacterStart(inventoryServerAPI)
  RegisterGroundInventory()
end
