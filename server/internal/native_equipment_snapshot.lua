-- Internal read-only scope, not a cache. Capability expires before the owning
-- transaction callback returns. Never use across a write, epoch or transaction.
NativeEquipmentSnapshot={}
local function copy(v) if type(v)~='table' then return v end; local r={}; for k,x in pairs(v) do r[k]=copy(x) end; return r end
local function int(v,min) return type(v)=='number' and v>=min and v<math.huge and v%1==0 end
local function current(fn)
    local ok,v=pcall(fn); return ok and v==true
end
local function denied() return Result.Err('native_snapshot_refused','Current locked equipment snapshot required.') end
function NativeEquipmentSnapshot.With(tx,characterId,authority,headerLocked,body)
    if not InventoryIdentity.NormalizeCharacterId(characterId) or not current(authority) or type(body)~='function' then return denied() end
    if not headerLocked then
        local rows=tx.query('SELECT id FROM inventory WHERE character_id=? LIMIT 1 FOR UPDATE',{characterId})
        if type(rows)~='table' or #rows~=1 or not current(authority) then return denied() end
    end
    local rows=tx.query([[SELECT ce.slot, ce.slot AS equipped_slot, ce.inventory_items_id,
        ii.id, ii.row_revision, ii.metadata, i.name AS itemName, inv.character_id AS owner_character
        FROM character_equipment ce LEFT JOIN inventory_items ii ON ii.id=ce.inventory_items_id
        LEFT JOIN items i ON i.id=ii.item_id LEFT JOIN inventory inv ON inv.id=ii.inventory_id
        WHERE ce.character_id=? ORDER BY ce.slot FOR UPDATE]],{characterId})
    if type(rows)~='table' or not current(authority) then return denied() end
    local slots,items={},{}
    for _,r in ipairs(rows) do
        local id,revision=tonumber(r.inventory_items_id),tonumber(r.row_revision)
        if type(r.slot)~='string' or slots[r.slot] or not int(id,1) or tonumber(r.id)~=id
            or not int(revision,0) or items[id] or r.owner_character~=characterId then return denied() end
        slots[r.slot]=true; items[id]=copy(r)
    end
    rows=copy(rows)
    local active=true
    local function valid(checkTx,cid) return active and checkTx==tx and cid==characterId and current(authority) end
    local capability={ReadEquipment=function(checkTx,cid)
        if not valid(checkTx,cid) then return nil end
        return copy(rows)
    end,ReadItem=function(checkTx,cid,id)
        if not valid(checkTx,cid) then return nil end
        return items[id] and {copy(items[id])} or false -- false: unassigned candidate needs its own locked read
    end}
    local ok,result=pcall(body,capability)
    active=false
    if not ok then error(result,0) end
    if not current(authority) then return denied() end
    return result
end
