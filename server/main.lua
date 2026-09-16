local function runInventory()
  local called, failure = xpcall(StartAPI, debug.traceback)
  if not called then
    InventoryReadiness.state, InventoryReadiness.failure = 'failed', tostring(failure)
    print('[feather-inventory] startup failed: ' .. tostring(failure))
  end
end

runInventory()
