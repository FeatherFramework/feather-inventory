-- Raw DB access for the `items` catalog table (item definitions, not owned
-- instances -- see inventory.lua controller for the `inventory_items` table
-- that tracks who actually has what).
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

function ItemControllers.GetItemDefinitionByName(itemName)
  return MySQL.single.await([[
    SELECT i.id, i.name, i.display_name, i.description, i.max_quantity,
           i.max_stack_size, i.weight, i.usable, i.type,
           i.category_id, COALESCE(c.name, 'other') AS category
    FROM items i
    LEFT JOIN categories c ON c.id = i.category_id
    WHERE i.name = ?
    LIMIT 1
  ]], { itemName })
end

function ItemControllers.GetItemDefinitions()
  return MySQL.query.await([[
    SELECT i.id, i.name, i.display_name, i.description, i.max_quantity,
           i.max_stack_size, i.weight, i.usable, i.type,
           i.category_id, COALESCE(c.name, 'other') AS category
    FROM items i
    LEFT JOIN categories c ON c.id = i.category_id
    ORDER BY category ASC, i.display_name ASC, i.name ASC
  ]]) or {}
end
