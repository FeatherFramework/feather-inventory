RegisterCommand('AddItems', function(source, args)
    

    -- TODO: Add check to ensure only admit can use this command.
    ItemsAPI.AddItem(source, args[1], tonumber(args[2]), args[3] or nil)
end, false)