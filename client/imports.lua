Feather = {}
Feather.RPC = {
  CallAsync = function(name, params, source, timeoutMs)
    return exports['feather-core']:CallRPCAsync(name, params, source, timeoutMs)
  end
}
Feather.Locale = {
  register = function(locale, translations)
    return exports['feather-core']:RegisterLocale(locale, translations)
  end,
  translate = function(source, key, ...)
    local result = exports['feather-core']:TranslateLocale(source, key, ...)
    return type(result) == 'table' and result.ok == true and result.value
      or ('Translation [%s] is unavailable'):format(tostring(key))
  end
}

Feather.Notify = {}
Feather.Notify.RightNotify = function(message, duration)
  local result = exports['feather-core']:ShowNotification({
    style = 'right',
    message = message,
    duration = duration
  })
  if type(result) ~= 'table' or result.ok ~= true then
    print(('[feather-inventory] client notification failed code=%s'):format(
      tostring(type(result) == 'table' and result.code or 'invalid_result')))
  end
  return result
end
