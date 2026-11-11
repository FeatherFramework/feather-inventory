local function Ready()
    return InventoryReadiness and InventoryReadiness.state=='ready'
end
local function Allowed()
    return GetInvokingResource()=='feather-shops' and Ready()
end
local function Refuse()
    return Result.Err('shop_checkout_refused','Ready Shops checkout authority required.')
end
local function Uuid(v)
    return type(v)=='string' and v:match('^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$')~=nil
end
local function Order(id)
    if not Uuid(id) then return nil end
    local order=DB.one("SELECT * FROM shop_orders WHERE order_id=? AND source_resource='feather-shops'",id)
    if order then
        for _,key in ipairs({'definition_id','quantity','unit_price','total_amount','pack_size'}) do order[key]=tonumber(order[key]) end
    end
    return order
end
exports('GetShopCheckoutContract',function()
    return {contractVersion=1,ready=Ready()==true,atomicPaymentDelivery=true,recoveryFence=true,
        packageDelivery=1,maximumDeliveredItems=100}
end)
exports('GetShopCheckoutDefinition',function(itemName)
    if not Allowed() or type(itemName)~='string' or #itemName<1 or #itemName>100 then return Refuse() end
    local row=DB.one([[SELECT id,name,type,instance_mode FROM items
        WHERE name=? AND archived_at IS NULL LIMIT 1]],itemName)
    if not row then return Result.Err('item_unavailable','Active item definition required.') end
    return Result.Ok({id=tonumber(row.id),name=row.name,type=row.type,instanceMode=row.instance_mode})
end)
exports('ResolveShopCheckout',function(orderId)
    if not Allowed() then return Refuse() end
    local order=Order(orderId)
    if not order then return Refuse() end
    return ShopCheckoutAPI.Resolve(order)
end)
exports('CheckoutShopOrder',function(orderId,source,permitId)
    if not Allowed() or type(source)~='number' or source<1 or source%1~=0
        or type(permitId)~='string' or #permitId>128 then return Refuse() end
    local order=Order(orderId)
    if not order then return Refuse() end
    local ticket
    local function Current()
        local valid=exports['feather-shops']:ValidateCheckoutPermit(permitId,order)
        if valid~=true then return false end
        if ticket then return exports['feather-weapons']:IsShopCheckoutWeaponCurrent(ticket,order)==true end
        return true
    end
    if not Current() then return Refuse() end
    local definition=DB.one('SELECT name,type,instance_mode FROM items WHERE id=? AND archived_at IS NULL',order.definition_id)
    if not definition or definition.name~=order.item_name then return Refuse() end
    local weapon
    if definition.type=='item_weapon' or definition.type=='weapon' then
        local prepared=exports['feather-weapons']:PrepareShopCheckoutWeapon(source,order)
        if not prepared or not prepared.ok then return prepared or Refuse() end
        ticket,weapon=prepared.value.ticket,prepared.value.weapon
    elseif definition.instance_mode~='stack' then return Refuse() end
    local called,result=pcall(ShopCheckoutAPI.Execute,{resource='feather-shops'},order,{
        weapon=weapon,current=Current,
        payment=function(query,lockedOrder)
            return exports['feather-economy']:StageShopCheckoutPayment(query,lockedOrder.order_id)
        end,
        provenance=function(query,lockedOrder,_,inventoryId,itemId)
            return exports['feather-weapons']:StageShopCheckoutProvenance(query,ticket,lockedOrder,inventoryId,itemId)
        end
    })
    if ticket then pcall(function() exports['feather-weapons']:ReleaseShopCheckoutWeapon(ticket) end) end
    if not called then return Result.Err('transaction_outcome_unknown','Checkout result needs independent readback.') end
    return result
end)
