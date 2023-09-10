function GetCategories()
  local result = MySQL.query.await(
    'SELECT * FROM `categories`;')
  return result
end
