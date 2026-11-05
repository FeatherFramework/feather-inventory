-- Inventory owns the physical checkout transaction. Public admission is kept
-- in the narrow Shops-only exports; no caller may supply arbitrary participants.
ShopCheckoutAPI = {}

local function Callable(value)
    return type(value) == 'function' or (type(value) == 'table'
        and type(rawget(value, '__cfx_functionReference')) == 'string')
end
local function Refuse(message)
    return Result.Err('shop_checkout_refused', message)
end
local fields = { 'order_id', 'source_resource', 'quote_id', 'buyer_account_id',
    'buyer_character_id', 'buyer_session_id', 'shop_id', 'offer_id', 'item_name',
    'definition_id', 'quantity', 'currency_code', 'unit_price', 'total_amount', 'catalog_revision' }
local function Fingerprint(order)
    local values = {}
    for _, field in ipairs(fields) do
        local input = order[field]
        if field=='definition_id' or field=='quantity' or field=='unit_price' or field=='total_amount' then
            input=tonumber(input)
            if input and input%1==0 then input=math.floor(input) end
        end
        local value = tostring(input)
        values[#values + 1] = #value .. ':' .. value
    end
    return table.concat(values, '|')
end

local function Settled(receipt, order, fingerprint)
    if not receipt or receipt.request_fingerprint ~= fingerprint then return Refuse('Checkout receipt conflict.') end
    if not receipt.result_json then return nil end
    local decoded, value = pcall(json.decode, receipt.result_json)
    if not decoded or type(value) ~= 'table' or value.orderId ~= order.order_id
        or value.characterId ~= order.buyer_character_id then
        return Refuse('Checkout receipt is corrupt; no replacement issued.')
    end
    if value.state == 'rejected' and value.code == 'checkout_not_committed' then
        return Result.Err('checkout_not_committed', 'Checkout did not commit. No payment was taken.',
            {orderId=order.order_id,safeToClear=true})
    end
    if value.state ~= 'fulfilled' or type(value.itemInstanceIds) ~= 'table'
        or #value.itemInstanceIds ~= order.quantity or type(value.transactionId) ~= 'string'
        or not value.transactionId:match('^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$')
        or value.quantity~=order.quantity or value.currency~=order.currency_code or value.total~=order.total_amount
        or type(value.inventoryId)~='number' or value.inventoryId<1 or value.inventoryId%1~=0 then
        return Refuse('Checkout receipt is corrupt; no replacement issued.')
    end
    local seen = {}
    for index=1,order.quantity do
        local id=value.itemInstanceIds[index]
        if type(id) ~= 'number' or id < 1 or id % 1 ~= 0 or seen[id] then
            return Refuse('Checkout item identities are corrupt; no replacement issued.')
        end
        seen[id] = true
    end
    value.replayed = true
    return Result.Ok(value)
end

-- Resolves an uncertain attempt without rerunning payment or delivery. Both
-- execution and recovery lock the immutable order first. Recovery therefore
-- waits for any original transaction, or fences a late original with a terminal
-- receipt. Missing receipts alone are never treated as proof of rollback.
function ShopCheckoutAPI.Resolve(order)
    if type(order) ~= 'table' or order.source_resource ~= 'feather-shops'
        or type(order.order_id) ~= 'string' or #order.order_id ~= 36
        or not InventoryIdentity.NormalizeCharacterId(order.buyer_character_id) then
        return Refuse('Canonical checkout order required for readback.')
    end
    local fingerprint = Fingerprint(order)
    local fenced
    local result = TransactionAPI.Transaction({resource='feather-shops',reason='shop_checkout_readback',
        correlationId=order.order_id}, function(tx)
        local rows = tx.query('SELECT * FROM shop_orders WHERE order_id=? FOR UPDATE', {order.order_id})
        if not rows or not rows[1] or Fingerprint(rows[1]) ~= fingerprint then
            return Refuse('Prepared order changed during readback.')
        end
        rows = tx.query([[SELECT request_fingerprint,result_json FROM inventory_shop_checkout_receipts
            WHERE order_id=? FOR UPDATE]], {order.order_id})
        local receipt = rows and rows[1]
        if receipt then
            local settled = Settled(receipt, order, fingerprint)
            if settled then
                if settled.ok then return settled end
                if settled.error.code ~= 'checkout_not_committed' then return settled end
                fenced = true
                return Result.Ok(true)
            end
        end
        local terminal = json.encode({orderId=order.order_id,characterId=order.buyer_character_id,
            state='rejected',code='checkout_not_committed'})
        local updated
        if receipt then
            updated = tx.query('UPDATE inventory_shop_checkout_receipts SET result_json=? WHERE order_id=?',
                {terminal,order.order_id})
        else
            updated = tx.query([[INSERT INTO inventory_shop_checkout_receipts
                (order_id,request_fingerprint,result_json) VALUES (?,?,?)]], {order.order_id,fingerprint,terminal})
        end
        if not updated or tonumber(updated.affectedRows or updated.affected_rows) ~= 1 then
            return Refuse('Checkout readback could not fence the original attempt.')
        end
        fenced = true
        return Result.Ok(true) -- commit the fence before announcing a rejection
    end)
    if not result.ok or not fenced then return result end
    return Result.Err('checkout_not_committed', 'Checkout did not commit. No payment was taken.',
        {orderId=order.order_id,safeToClear=true})
end

function ShopCheckoutAPI.Start()
    -- Separate receipt namespace from development issuance and ordinary grants.
    DB.exec([[CREATE TABLE IF NOT EXISTS inventory_shop_checkout_receipts (
        order_id CHAR(36) NOT NULL,
        request_fingerprint TEXT NOT NULL,
        result_json LONGTEXT NULL,
        created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        PRIMARY KEY (order_id)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci]])
end

function ShopCheckoutAPI.Execute(context, order, participants)
    if type(context) ~= 'table' or context.resource ~= 'feather-shops'
        or type(order) ~= 'table' or order.source_resource ~= 'feather-shops'
        or not InventoryIdentity.NormalizeCharacterId(order.buyer_character_id)
        or type(order.order_id) ~= 'string' or #order.order_id ~= 36
        or type(order.quantity) ~= 'number' or order.quantity % 1 ~= 0
        or order.quantity < 1 or order.quantity > 100
        or type(order.definition_id) ~= 'number' or order.definition_id % 1 ~= 0 or order.definition_id < 1
        or type(order.unit_price) ~= 'number' or order.unit_price < 1 or order.unit_price % 1 ~= 0
        or type(order.total_amount) ~= 'number' or order.total_amount > 1000000000000
        or order.total_amount ~= order.quantity * order.unit_price
        or type(participants) ~= 'table' or not Callable(participants.current)
        or not Callable(participants.payment) then
        return Refuse('Immutable order and owning transaction participants required.')
    end
    local weapon = participants.weapon
    if weapon and (order.quantity ~= 1 or type(weapon) ~= 'table'
        or weapon.itemName ~= order.item_name or weapon.requestId ~= order.order_id
        or type(weapon.metadata) ~= 'table' or type(weapon.metadata.serialNumber) ~= 'string'
        or not Callable(participants.provenance)) then
        return Refuse('Canonical single-weapon issuance and provenance authority required.')
    end
    if participants.current() ~= true then return Refuse('Buyer or quote authority changed.') end
    local fingerprint = Fingerprint(order)
    return TransactionAPI.Transaction({resource='feather-shops', reason='shop_checkout',
        correlationId=order.order_id}, function(tx)
        -- The prepared order is immutable; lock and compare it before granting.
        local rows = tx.query('SELECT * FROM shop_orders WHERE order_id=? FOR UPDATE', {order.order_id})
        if not rows or not rows[1] or Fingerprint(rows[1]) ~= fingerprint then
            return Refuse('Prepared order changed.')
        end
        tx.query([[INSERT IGNORE INTO inventory_shop_checkout_receipts
            (order_id,request_fingerprint) VALUES (?,?)]], {order.order_id,fingerprint})
        rows = tx.query([[SELECT request_fingerprint,result_json FROM inventory_shop_checkout_receipts
            WHERE order_id=? FOR UPDATE]], {order.order_id})
        local receipt = rows and rows[1]
        if not receipt or receipt.request_fingerprint ~= fingerprint then return Refuse('Checkout receipt conflict.') end
        if participants.current() ~= true then return Refuse('Buyer or quote authority changed.') end
        local settled = Settled(receipt, order, fingerprint)
        if settled then return settled end
        rows = tx.query('SELECT id FROM inventory WHERE character_id=? LIMIT 1 FOR UPDATE', {order.buyer_character_id})
        local inventoryId = rows and rows[1] and tonumber(rows[1].id)
        if not inventoryId then return Refuse('Buyer inventory unavailable.') end
        if weapon then
            rows = tx.query('SELECT revision FROM feather_character_ammunition WHERE character_id=? FOR UPDATE',
                {order.buyer_character_id})
            if not rows or not rows[1] then return Refuse('Native buyer enrollment required.') end
        end
        -- Normal Tx capacity, weight, blacklist, stack placement and item guards.
        -- Complete these before taking the business's shared payment-account locks.
        local delivered = tx:AddQuantity(inventoryId, order.definition_id, order.quantity,
            weapon and weapon.metadata or {}, {name=order.item_name,weapon=weapon~=nil})
        if not delivered or delivered.ok ~= true then return delivered or Refuse('Delivery failed.') end
        if weapon then
            local provenance = participants.provenance(tx.query, order, weapon, inventoryId, delivered.value[1])
            if not provenance or provenance.ok ~= true then return provenance or Refuse('Weapon provenance failed.') end
        end
        if participants.current() ~= true then return Refuse('Buyer or quote authority changed.') end
        local payment = participants.payment(tx.query, order)
        if not payment or payment.ok ~= true then return payment or Refuse('Payment failed.') end
        if type(payment.value) ~= 'table' or type(payment.value.transactionId) ~= 'string'
            or payment.value.amount~=order.total_amount or payment.value.currency~=order.currency_code
            or type(payment.meta) ~= 'table' or payment.meta.pendingCommit ~= true then
            return Refuse('Invalid staged payment result.')
        end
        local value = {orderId=order.order_id,characterId=order.buyer_character_id,state='fulfilled',
            transactionId=payment.value.transactionId,inventoryId=inventoryId,
            itemInstanceIds=delivered.value,quantity=order.quantity,currency=order.currency_code,
            total=order.total_amount,replayed=false}
        local updated = tx.query('UPDATE inventory_shop_checkout_receipts SET result_json=? WHERE order_id=?',
            {json.encode(value),order.order_id})
        if not updated or tonumber(updated.affectedRows or updated.affected_rows) ~= 1
            or participants.current() ~= true then return Refuse('Checkout completion lost authority.') end
        return Result.Ok(value)
    end)
end
