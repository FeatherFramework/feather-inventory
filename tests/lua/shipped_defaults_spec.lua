local root=arg and arg[1] or '.'
dofile(root..'/config.lua')
assert(Config.CharacterAmmunitionEnabled==true)
assert(Config.DevMode==false)
assert(Config.Debug==false)
print('Shipped Inventory defaults PASS (native integration enabled, development/debug disabled)')
