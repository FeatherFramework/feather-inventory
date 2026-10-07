-- Local elapsed clocks only: never subtract browser/client/server timestamps.
InventoryMutationMetrics = {}
local sequence = 0

function InventoryMutationMetrics.Elapsed(started)
  return (GetGameTimer() - started) % 4294967296
end

function InventoryMutationMetrics.Begin(operation, traceId)
  if Config.MutationTiming ~= true then
    return nil
  end
  sequence = sequence + 1
  return {
    id = ('%s-%s-%s'):format(operation, GetGameTimer(), sequence),
    traceId = type(traceId) == 'string' and #traceId <= 64 and traceId:match('^[%w_-]+$') and traceId or nil,
    operation = operation,
    started = GetGameTimer(),
    transactionMs = 0, sqlMs = 0, sqlStatements = 0, updateStatements = 0,
    plannedRows = 0, eventEmissionMs = 0,
  }
end

function InventoryMutationMetrics.Measure(metrics, key, callback, ...)
  if not metrics then return callback(...) end
  local started = GetGameTimer()
  local values = table.pack(pcall(callback, ...))
  metrics[key] = (metrics[key] or 0) + InventoryMutationMetrics.Elapsed(started)
  if not values[1] then error(values[2], 0) end
  return table.unpack(values, 2, values.n)
end

function InventoryMutationMetrics.Finish(metrics, response)
  if not metrics then return response end
  metrics.serverMs = InventoryMutationMetrics.Elapsed(metrics.started)
  metrics.started = nil
  metrics.outcome = response and response.error and 'rejected' or 'completed'
  response.mutationTiming = metrics
  print('[inventory:mutation] ' .. json.encode(metrics))
  return response
end
