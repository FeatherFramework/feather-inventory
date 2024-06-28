if Config.DevMode then
    RegisterCommand('AddItems', function(source, args)
        local result = ItemsAPI.AddItem(args[1], tonumber(args[2]), args[3] or nil, source)

        if result.error == true then
            Feather.Notify.RightNotify(source, result.message, 3000)
        else
            Feather.Notify.RightNotify(source, "Item added!", 3000)
        end
    end, false)

    RegisterCommand('AddApples', function(source, args)
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

    RegisterCommand('CreateStorageKey', function(source, args)
        InventoryAPI.RegisterForeignKey('storage', 'BIGINT UNSIGNED', 'id')
    end, false)

    RegisterCommand('CreateStorage', function(source, args)
        InventoryAPI.RegisterInventory('storage', 1, 'Big Box')
    end, false)

    RegisterCommand('AddStorageItems', function(source, args)
        local result = ItemsAPI.AddItem(args[1], tonumber(args[2]), args[3] or nil,
            'dde04bd6-34cc-11ef-a92d-107c61489014')

        if result.error == true then
            Feather.Notify.RightNotify(source, result.message, 3000)
        else
            Feather.Notify.RightNotify(source, "Item added!", 3000)
        end
    end, false)
end
