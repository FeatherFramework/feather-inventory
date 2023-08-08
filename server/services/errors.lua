if Config.hotbarLimit > 10 then
  error('Hotbar limit is beyond acceptable range. Must not be greater than 10')
end

if Config.maxItemSlots < Config.hotbarLimit then
  error('Your inventory slots cannot be less than your hotbar slots')
end
