CategoryControllers = {}

function CategoryControllers.GetCategories()
  local result = DB.query(
    'SELECT * FROM `categories`;')
  return result
end
