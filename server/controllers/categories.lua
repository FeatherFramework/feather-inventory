CategoryControllers = {}

function CategoryControllers.GetCategories()
  local result = MySQL.query.await(
    'SELECT * FROM `categories`;')
  return result
end
