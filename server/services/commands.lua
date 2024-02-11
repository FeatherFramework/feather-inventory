RegisterCommand('AddItems', function(source, args)
    -- TODO: Add check to ensure only admit can use this command.
    local result = ItemsAPI.AddItem(args[1], tonumber(args[2]), args[3] or nil, source)

    if result.error == true then
        Feather.Notify.RightNotify(source, result.message, 3000)
    else
        Feather.Notify.RightNotify(source, "Item added!", 3000)
    end
end, false)

RegisterCommand('AddApples', function(source, args)
    -- TODO: Add check to ensure only admit can use this command.
    local result = ItemsAPI.AddItem('consumable_apple', 5, {
        display = '4 bites left',
        current = 4,
        left = 10
    }, source)

    if result.error == true then
        Feather.Notify.RightNotify(source, result.message, 3000)
    else
        Feather.Notify.RightNotify(source, "Item added!", 3000)
    end
end, false)


RegisterCommand('CreateStorage', function(source, args)
    InventoryAPI.RegisterForeignKey('storage', 'BIGINT UNSIGNED', 'id')
    InventoryAPI.RegisterInventory('storage', 1)
end, false)


RegisterCommand('AddStorageItems', function(source, args)
    -- TODO: Add check to ensure only admit can use this command.
    local result = ItemsAPI.AddItem(args[1], tonumber(args[2]), args[3] or nil, '5ab95e93-c590-11ee-a5cf-40b07640984b')

    if result.error == true then
        Feather.Notify.RightNotify(source, result.message, 3000)
    else
        Feather.Notify.RightNotify(source, "Item added!", 3000)
    end
end, false)
