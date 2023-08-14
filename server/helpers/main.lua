function FirstToUpper(str)
  return (str:gsub("^%l", string.upper))
end

function GetItemByName(itemName)
  local result = MySQL.query.await('SELECT id FROM `items` WHERE `name` = ? LIMIT 1;', { itemName })
  if not result[1] then
    return false
  end
  return result[1].id
end

function GetInventory(inventoryId)
  local result = MySQL.query.await('SELECT id FROM `inventory` WHERE `uuid` = ? LIMIT 1;', { inventoryId })
  if not result[1] then
    return false
  end
  return result[1].id
end
