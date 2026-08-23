-- (§10.2 locale migration) Every user-facing string this resource shows a
-- player lives here, per the framework convention that no user-facing text is
-- hardcoded inline -- even a one-off.
--
-- Loaded into BOTH the server and client contexts (see fxmanifest), because
-- both display text: the server sends notifications via Feather.Notify, and
-- the client resolves the ledger UI's own labels before handing them to the
-- NUI. Each context registers into its own Lua state, and
-- Feather.Locale.register is first-writer-wins per key, so registering twice
-- is harmless.
--
-- Two naming groups:
--   err_*  -- keyed to the stable `code` on a result envelope, so the
--            displayed text is decoupled from the developer-facing English
--            `message` those envelopes still carry for logs/API consumers.
--   ui_*   -- ledger UI labels, sent to the NUI as a resolved string bundle
--            (see client/controllers/inventory.lua) rather than duplicating a
--            second locale system in JavaScript.
Feather.Locale.register('en_us', {
    ----------------------------------------------------------------
    -- Access / proximity
    ----------------------------------------------------------------
    err_no_access = 'You do not have access to that inventory.',
    err_too_far = 'You are too far away.',
    err_target_unavailable = 'That player is not available.',
    err_cannot_search = 'This player cannot be searched right now.',
    err_already_open = 'This inventory is already opened. Try again later.',
    err_not_owner = 'You do not own this inventory.',
    err_no_owner = 'This inventory has no owner and cannot have its access list managed.',

    ----------------------------------------------------------------
    -- Capacity / limits -- keyed to EvaluateInventoryAcceptance's codes.
    -- Deliberately friendlier than the internal messages ("Max Weight
    -- Exceeded.") those codes travel with, which stay developer-facing.
    ----------------------------------------------------------------
    err_invalid_item = 'That item does not exist.',
    err_item_restricted = 'That item cannot be stored there.',
    err_item_limit = 'You cannot carry any more of those.',
    err_inventory_full = 'There is no room for that.',
    err_weight_limit = 'That is too heavy to carry.',
    err_invalid_inventory = 'That inventory is unavailable.',
    err_no_character = 'No character is loaded.',
    err_invalid_quantity = 'That amount is not valid.',
    err_database_error = 'That could not be saved.',

    ----------------------------------------------------------------
    -- Action failures
    ----------------------------------------------------------------
    err_move_failed = 'Those items could not be moved.',
    err_give_failed = 'That item could not be given.',
    err_drop_failed = 'Those items could not be dropped.',
    err_split_whole_stack = 'Choose fewer than the whole stack.',
    err_no_free_compartment = 'There is no free compartment to split into.',

    ----------------------------------------------------------------
    -- Confirmations
    ----------------------------------------------------------------
    msg_item_added = 'Item added.',

    ----------------------------------------------------------------
    -- Ledger UI
    ----------------------------------------------------------------
    ui_personal_effects = 'PERSONAL EFFECTS',
    ui_storage = 'STORAGE',
    ui_carrying = 'CARRYING',
    ui_stored = 'STORED',
    ui_all = 'ALL',

    ui_use = 'Use',
    ui_give = 'Give',
    ui_drop = 'Drop',
    ui_split = 'Split',
    ui_cancel = 'Cancel',
    ui_confirm = 'Confirm',

    ui_quantity = 'Quantity',
    ui_weight = 'Weight',
    -- `{n}` is the maximum selectable amount, substituted by the UI.
    --
    -- Deliberately NOT `%s`. Feather.Locale.translate always runs the result
    -- through string.format, and these two are the only strings resolved
    -- without arguments (the client hands them to the NUI as templates,
    -- because only the UI knows the runtime value). A `%s` here therefore
    -- raised "bad argument #2 to 'format' (no value)" on every inventory
    -- open. `{n}` carries no meaning to string.format, so it passes through
    -- untouched. Any future placeholder rendered UI-side must use this
    -- convention too.
    ui_how_many = 'How many? (1-{n})',
    ui_use_all = 'Use all ({n})',
    ui_invalid_amount = 'Invalid amount.',
    ui_no_entry = 'No entry selected.',

    ui_paired_hint = 'Drag an entry between books to move it \u{2022} Shift-click to send it across \u{2022} ESC closes both',
})
