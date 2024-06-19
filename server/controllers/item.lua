ItemControllers = {}

function ItemControllers.GetItemByName(itemName)
  local result = MySQL.query.await(
    'SELECT `id`, `display_name`, `max_quantity`, `weight`, `max_stack_size`, `type`, `usable` FROM `items` WHERE `name` = ? LIMIT 1;',
    { itemName })
  if not result[1] then
    return false, false
  end
  return result[1].id, tonumber(result[1].max_quantity), tonumber(result[1].weight), tonumber(result[1].max_stack_size)
end
