arg=arg or {}
arg[2]='knives'
dofile('tests/lua/regular_arrow_recovery_spec.lua')
arg[2]=nil
