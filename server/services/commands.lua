-- (INV-05) Gated on Config.DevMode (default false) AND registered as
-- ACE-restricted ("true" below, was "false") -- so a server that flips
-- DevMode back on for testing doesn't hand free-item commands to every
-- player, only to principals explicitly granted `command.<name>`.
if Config.DevMode then
    RegisterCommand('AddItems', function(source, args)
        local result = ItemsAPI.AddItem(args[1], tonumber(args[2]), args[3] or nil, source)

        if result.error == true then
            Feather.Notify.RightNotify(source, TranslateResult(source, result, 'err_move_failed'), 3000)
        else
            Feather.Notify.RightNotify(source, Translate(source, 'msg_item_added', 'Item added.'), 3000)
        end
    end, true)

    RegisterCommand('AddApples', function(source, args)
        local result = ItemsAPI.AddItem('consumable_apple', 5, {
            display = '4 bites left',
            current = 4,
            left = 10
        }, source)

        if result.error == true then
            Feather.Notify.RightNotify(source, TranslateResult(source, result, 'err_move_failed'), 3000)
        else
            Feather.Notify.RightNotify(source, Translate(source, 'msg_item_added', 'Item added.'), 3000)
        end
    end, true)

    RegisterCommand('CreateStorageKey', function(source, args)
        InventoryAPI.RegisterForeignKey('storage', 'BIGINT UNSIGNED', 'id')
    end, true)

    RegisterCommand('CreateStorage', function(source, args)
        -- (INV-11) Dev/test-only storage; marked public since this ACE-gated
        -- debug tool has no owner-assignment flow of its own.
        InventoryAPI.RegisterInventory('storage', 1, 'Big Box', nil, nil, nil, nil, true)
    end, true)

    RegisterCommand('AddStorageItems', function(source, args)
        local result = ItemsAPI.AddItem(args[1], tonumber(args[2]), args[3] or nil,
            'dde04bd6-34cc-11ef-a92d-107c61489014')

        if result.error == true then
            Feather.Notify.RightNotify(source, TranslateResult(source, result, 'err_move_failed'), 3000)
        else
            Feather.Notify.RightNotify(source, Translate(source, 'msg_item_added', 'Item added.'), 3000)
        end
    end, true)
end
