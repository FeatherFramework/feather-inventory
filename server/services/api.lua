function StartAPI()
  ItemsAPI.RegisterInternalUseGuard()
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
  inventoryServerAPI.MutateItems = TransactionAPI.MutateItems
  inventoryServerAPI.DestroyInstances = TransactionAPI.DestroyInstances
  inventoryServerAPI.UseItemAction = TransactionAPI.UseItemAction
  inventoryServerAPI.CreateInstance = TransactionAPI.CreateInstance
  -- (INV-W3) Pre-move/destroy guard registry and structured post-commit
  -- events. This is how feather-weapons forces an authoritative unequip
  -- before an equipped item is allowed to move.
  inventoryServerAPI.Guards = GuardsAPI
  -- (INV-W4) Operational surface: transaction counters for contention
  -- monitoring, and the access-mode decision function.
  inventoryServerAPI.Diagnostics = {
    GetTransactionMetrics = TransactionAPI.GetMetrics,
    RunIntegrityDiagnostics = DiagnosticsAPI.RunIntegrityDiagnostics,
  }
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
  inventoryServerAPI.PromoteEquippedSlot = EquipmentAPI.PromoteEquippedSlot
  -- Consumer-safe UUID Character inventory lookup. Keep a top-level alias
  -- because Cfx resource boundaries do not reliably preserve newly-added
  -- nested function members on an API table returned by an export.
  inventoryServerAPI.GetCharacterInventory = function(characterId)
    if type(InventoryAPI) ~= 'table' or type(InventoryAPI.GetCharacterInventory) ~= 'function' then
      return Result.Err(Result.Codes.INTERNAL, 'Character inventory lookup is unavailable.')
    end
    return InventoryAPI.GetCharacterInventory(characterId)
  end

  exports('initiate', function()
    return inventoryServerAPI
  end)

  exports('GetCharacterInventory', function(characterId)
    if type(InventoryAPI) ~= 'table' or type(InventoryAPI.GetCharacterInventory) ~= 'function' then
      return Result.Err(Result.Codes.INTERNAL, 'Character inventory lookup is unavailable.')
    end
    return InventoryAPI.GetCharacterInventory(characterId)
  end)

  exports('RemoveCharacterInventoryInstance', function(characterId, instanceId, reason)
    local normalized = InventoryIdentity.NormalizeCharacterId(characterId)
    local numericInstance = tonumber(instanceId)
    if not normalized or not numericInstance then
      return Result.Err(Result.Codes.INVALID_INPUT, 'UUID Character id and item instance id are required.')
    end
    local inventoryId = InventoryControllers.GetInventoryByCharacter(normalized)
    if not inventoryId then
      return Result.Err(Result.Codes.NOT_FOUND, 'The Character inventory does not exist.')
    end
    return TransactionAPI.Transaction({
      reason = type(reason) == 'string' and reason:sub(1, 100) or 'admin_remove',
      resource = GetInvokingResource() or 'unknown'
    }, function(tx)
      local locked = tx:GetItemForUpdate(numericInstance)
      if not Result.IsOk(locked) then return locked end
      if locked.value.inventoryId ~= tonumber(inventoryId) then
        return Result.Err(Result.Codes.NOT_FOUND, 'That Character does not hold this item.',
          { characterId = normalized, instanceId = numericInstance })
      end
      local removed = tx:RemoveInstances(inventoryId, locked.value.definition.id, { numericInstance })
      if not Result.IsOk(removed) then return removed end
      return Result.Ok({ instanceId = numericInstance, inventoryId = inventoryId,
        definitionId = locked.value.definition.id, itemName = locked.value.definition.name,
        displayName = locked.value.definition.displayName })
    end)
  end)

  exports('GrantCharacterItem', function(characterId, itemName, quantity, reason)
    local normalized = InventoryIdentity.NormalizeCharacterId(characterId)
    local wanted = math.floor(tonumber(quantity) or 0)
    if not normalized or type(itemName) ~= 'string' or itemName == '' or wanted < 1 or wanted > 10000 then
      return Result.Err(Result.Codes.INVALID_INPUT, 'UUID Character id, item name, and quantity are required.')
    end
    local definition = ItemControllers.GetItemDefinitionByName(itemName)
    if not definition then return Result.Err(Result.Codes.NOT_FOUND, 'Item definition does not exist.') end
    if definition.instance_mode == 'unique' then
      return Result.Err('unique_requires_issuer', 'Unique items must be issued by their owning resource.')
    end
    local inventoryId = InventoryControllers.GetInventoryByCharacter(normalized)
    if not inventoryId then
      return Result.Err(Result.Codes.NOT_FOUND, 'The Character inventory does not exist.')
    end
    return TransactionAPI.Transaction({
      reason = type(reason) == 'string' and reason:sub(1, 100) or 'trusted_character_grant',
      resource = GetInvokingResource() or 'unknown'
    }, function(tx)
      local granted = tx:AddQuantity(inventoryId, definition.id, wanted)
      if not Result.IsOk(granted) then return granted end
      return Result.Ok({ characterId = normalized, inventoryId = inventoryId,
        definitionId = definition.id, itemName = definition.name, quantity = wanted })
    end)
  end)

  RegisterCharacterStart(inventoryServerAPI)
  RegisterGroundInventory()
end
