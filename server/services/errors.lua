-- This file allows us to run validations against the config.

-- if Config.hotbarLimit > 10 then
--   error('Hotbar limit is beyond acceptable range. Must not be greater than 10')
-- end

-- if Config.maxItemSlots < Config.hotbarLimit then
--   error('Your inventory slots cannot be less than your hotbar slots')
-- end

if type(Config.maxWeight) ~= 'number' or Config.maxWeight < 1 then
  error('Your max weight must be a number greater than 1.')
end

if type(Config.Dropped.GroupingRadius) ~= 'number' or Config.Dropped.GroupingRadius < 1 then
  error('groundGroupingRadius must be greater than 1')
end

if type(Config.Dropped.PromptViewDistance) ~= 'number' or Config.Dropped.PromptViewDistance < 1 then
  error('Your max drop view distance must be a number greater than 1.')
end

if not Config.Dropped.Item then
  Config.Dropped.Item = 'p_dis_strongboxsm01x'
end
