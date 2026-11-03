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
    ui_equipment_title = 'Equipment',
    ui_equipment_help = 'Choose where to carry this weapon. Ammunition stays in your shared carried pools.',
    ui_equipment_slots = 'Equipment slot occupancy',
    ui_equipment_selected = 'This item',
    ui_equipment_occupied = 'Occupied',
    ui_equipment_open = 'Open',
    ui_equipment_item = 'Item #{n}',
    ui_equipment_hint = 'Open means empty, not necessarily compatible. Only permitted actions appear below. Only one lasso can be equipped.',
    ui_equipment_attachment_hint = 'Installing an attachment uses one matching item. Removal returns it to your inventory.',
    ui_equipment_repair_hint = 'Cleaning uses the listed material. Permanent wear cannot be repaired away.',
    ui_equipment_equip = 'Equip',
    ui_equipment_unequip = 'Unequip',
    ui_equipment_install = 'Install',
    ui_equipment_remove = 'Remove',
    ui_equipment_repair = 'Clean / repair',
    ui_equipment_close = 'Close',
    ui_equipment_primary = 'Primary',
    ui_equipment_offhand = 'Offhand',
    ui_equipment_shoulder = 'Shoulder',
    ui_equipment_back = 'Back',
    ui_equipment_melee = 'Melee',
    ui_equipment_melee_number = 'Melee {n}',
    ui_equipment_throwable = 'Throwable',
    ui_equipment_utility = 'Utility',
    ui_equipment_utility_number = 'Utility {n}',
    ui_equipment_checking = 'Checking equipment…',
    ui_equipment_none = 'No supported equipment action for this weapon.',
    ui_equipment_unavailable = 'Equipment controls unavailable.',
    ui_equipment_updated = 'Equipment updated. Reopen Equipment for another action.',
    ui_equipment_uncertain = 'Equipment result uncertain. Do not retry; check Weapons status.',
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
    err_unique_requires_issuer = 'That item has to be issued, not granted.',
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
    err_native_recovery_audit_pending = 'This item is held for recovery verification. Ask an administrator to inspect it.',
    err_transaction_outcome_unknown = 'Transfer outcome is unknown. Do not retry until it has been independently verified.',
    err_move_recovery_pending = 'Inventory is checking this transfer automatically. Please wait before trying again.',
    err_move_recovery_unavailable = 'Inventory is reconnecting. Please wait a moment.',
    msg_move_partial = 'Moved %d; skipped %d. %s',
    err_move_restrictions = 'Some items could not be moved because of inventory restrictions or capacity.',
    err_drop_failed = 'Those items could not be dropped.',
    err_split_whole_stack = 'Choose fewer than the whole stack.',
    err_no_free_compartment = 'There is no free compartment to split into.',

    ----------------------------------------------------------------
    -- Confirmations
    ----------------------------------------------------------------
    msg_item_added = 'Item added.',
    msg_took_what_fit = 'Took what would fit.',

    ----------------------------------------------------------------
    -- Ledger UI
    ----------------------------------------------------------------
    ui_personal_effects = 'PERSONAL EFFECTS',
    ui_storage = 'STORAGE',
    ui_carrying = 'CARRYING',
    ui_stored = 'STORED',
    ui_all = 'ALL',
    ui_search = 'SEARCH',
    ui_hotbar_visibility = 'Hotbar Visibility',
    ui_hotbar_temporary = 'Temporary',
    ui_hotbar_always = 'Always',
    ui_hotbar_opacity = 'Hotbar Opacity',

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

    -- Condition wear stages (see Config.Condition.Stages) and the detail label.
    ui_take_all = 'Take All',
    ui_taking_all = 'Taking items...',
    ui_using_item = 'Using item...',
    ui_dropping_items = 'Dropping items...',
    ui_giving_items = 'Giving items...',
    ui_working = 'Working...',
    ui_condition = 'Condition',
    ui_condition_pristine = 'Pristine',
    ui_condition_worn = 'Worn',
    ui_condition_damaged = 'Damaged',
    ui_condition_ruined = 'Ruined',

    ui_paired_hint = 'Drag an entry between books to move it \u{2022} Shift-click to send it across \u{2022} ESC closes both',
})
