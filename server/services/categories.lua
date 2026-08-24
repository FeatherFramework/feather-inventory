CategoriesAPI = {}

CategoriesAPI.GetCategories = function()
  return Result.Ok(CategoryControllers.GetCategories())
end
