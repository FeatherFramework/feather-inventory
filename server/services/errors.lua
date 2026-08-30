-- This file allows us to run validations against the config.

local hotbarVisibility = Config.Hotbar and Config.Hotbar.Visibility
if hotbarVisibility ~= 'Temporary' and hotbarVisibility ~= 'Always'
    and hotbarVisibility ~= 'UserDefined' then
  error('Config.Hotbar.Visibility must be Temporary, Always, or UserDefined.')
end

if Config.Hotbar.Visibility == 'UserDefined'
    and Config.Hotbar.DefaultVisibility ~= 'Temporary'
    and Config.Hotbar.DefaultVisibility ~= 'Always' then
  error('Config.Hotbar.DefaultVisibility must be Temporary or Always.')
end

if type(Config.Hotbar.Slots) ~= 'number' or Config.Hotbar.Slots < 1 or Config.Hotbar.Slots > 8 then
  error('Config.Hotbar.Slots must be a number from 1 through 8.')
end

if type(Config.Hotbar.TemporaryDuration) ~= 'number' or Config.Hotbar.TemporaryDuration < 250 then
  error('Config.Hotbar.TemporaryDuration must be at least 250 milliseconds.')
end

if type(Config.maxWeight) ~= 'number' or Config.maxWeight < 1 then
  error('Your max weight must be a number greater than 1.')
end

if type(Config.Dropped.GroupingRadius) ~= 'number' or Config.Dropped.GroupingRadius < 1 then
  error('groundGroupingRadius must be greater than 1')
end

if type(Config.Dropped.PromptViewDistance) ~= 'number' or Config.Dropped.PromptViewDistance < 1 then
  error('Your max drop view distance must be a number greater than 1.')
end

if type(Config.Dropped.LoadDistance) ~= 'number' or Config.Dropped.LoadDistance < Config.Dropped.PromptViewDistance then
  error('Config.Dropped.LoadDistance must be a number greater than or equal to PromptViewDistance.')
end

if not Config.Dropped.Item then
  Config.Dropped.Item = 'p_dis_strongboxsm01x'
end
