RegisterCommand('AddItems', function(source, args)
    

    -- TODO: Add check to ensure only admit can use this command.
    local result = ItemsAPI.AddItem(source, args[1], tonumber(args[2]), args[3] or nil)

    if result.error == true then
        Feather.Notify.RightNotify(source, result.message, 3000)
    else
        Feather.Notify.RightNotify(source, "Item added!", 3000)
    end
end, false)