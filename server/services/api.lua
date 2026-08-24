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
  inventoryServerAPI.MutateItem = TransactionAPI.MutateItem
  inventoryServerAPI.CreateInstance = TransactionAPI.CreateInstance
  -- (INV-W3) Pre-move/destroy guard registry and structured post-commit
  -- events. This is how feather-weapons forces an authoritative unequip
  -- before an equipped item is allowed to move.
  inventoryServerAPI.Guards = GuardsAPI
  -- (INV-W4) Operational surface: transaction counters for contention
  -- monitoring, and the access-mode decision function.
  inventoryServerAPI.Diagnostics = { GetTransactionMetrics = TransactionAPI.GetMetrics }
  -- (Weapons review #5) Persisted equipment slots -- generic
  -- character/slot/instance storage, survives restarts.
  inventoryServerAPI.Equipment = EquipmentAPI

  -- (Weapons review #10) The provider surface feather-weapons' adapter
  -- expects, exposed at the top level under exactly those names so the
  -- adapter needs no translation layer.
  inventoryServerAPI.GetCapabilities = InstancesAPI.GetCapabilities
  inventoryServerAPI.GetItemForCharacter = InstancesAPI.GetItemForCharacter
  inventoryServerAPI.GetEquippedForCharacter = EquipmentAPI.GetEquippedForCharacter
  inventoryServerAPI.SetEquippedForCharacter = EquipmentAPI.SetEquippedForCharacter

  exports('initiate', function()
    return inventoryServerAPI
  end)

  RegisterCharacterStart(inventoryServerAPI)
  RegisterGroundInventory()
end
