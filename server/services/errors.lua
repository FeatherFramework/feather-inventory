if Config.hotbarLimit > 10 then
  error('Hotbar limit is beyond acceptable range. Must not be greater than 10')
end

if Config.maxItemSlots < Config.hotbarLimit then
  error('Your inventory slots cannot be less than your hotbar slots')
end

if type(Config.maxWeight) ~= 'number' or Config.maxWeight < 1 then
  error('Your max weight must be a number greater than 1.')
end

if type(Config.groundGroupingRadius) ~= 'number' or Config.groundGroupingRadius < 1 then
  error('groundGroupingRadius must be greater than 1')
end

if type(Config.maxDropViewDistance) ~= 'number' or Config.maxDropViewDistance < 1 then
  error('Your max drop view distance must be a number greater than 1.')
end

if not Config.droppedItemObject then
  Config.droppedItemObject = 'p_dis_strongboxsm01x'
end
