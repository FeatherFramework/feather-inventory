arg=arg or {};arg[2]='knives';arg[3]='fixture'
local f=dofile('tests/lua/regular_arrow_recovery_spec.lua')
arg[2]=nil;arg[3]=nil
local poison='ammo_throwing_knives_poison'
local regular='ammo_throwing_knives_regular'
f.flags.feather_poison_knives='1';f.limits[poison]=8
local function reset()
 f.reset()
 for _,l in pairs(f.db().ledgers) do l.pools[poison]=0 end
 f.db().ledgers.jane.pools[poison]=8
end
local function spend(p,r)
 local l=f.db().ledgers.jane;local observed=f.copy(l.pools)
 observed[poison]=observed[poison]-p;observed[regular]=observed[regular]-(r or 0)
 return f.atomic(function() return CharacterAmmunitionAPI.ApplyObservation(f.tx,{characterId='jane'},
  {expectedRevision=l.revision,pools=observed,limits=f.limits,quantityRecovery=f.where()},f.current) end)
end
reset();assert(spend(2,1).ok)
local a=f.db().allowances
assert(a['regular-knife-quantity-allowance-v1/jane:0'].remaining==1)
assert(a['regular-knife-quantity-allowance-v1/jane:0:poison'].remaining==2,'distinct same-revision source receipts')
local r=f.claim(regular,4);assert(r.ok and r.value.recovered==3 and r.value.quantityDeclined)
assert(f.db().ledgers.john.pools[regular]==3 and f.db().ledgers.john.pools[poison]==0)
assert(f.claim(regular,1).value.recovered==0,'converted allowance is single use')
reset();assert(spend(1).ok)
assert(f.claim(poison,1).value.recovered==0,'Poison native increase cannot consume Regular conversion allowance')
assert(f.claim(regular,1).value.recovered==1)
reset();f.fail(true);assert(not spend(1).ok)
assert(next(f.db().allowances)==nil and f.db().ledgers.jane.pools[poison]==8,'debit and conversion receipt roll back together')
f.flags.feather_special_arrows='1'
for _,id in ipairs({'ammo_arrow_small_game','ammo_arrow_poison','ammo_arrow_fire','ammo_arrow_dynamite'}) do
 f.limits[id]=id=='ammo_arrow_small_game' and 40 or 8
 for _,l in pairs(f.db().ledgers) do l.pools[id]=0 end
 f.fail(false)
 r=f.claim(id,1);assert(r.ok and r.value.recovered==0 and r.value.quantityDeclined)
 assert(f.db().ledgers.john.pools[id]==0,'unconfirmed specialty recovery cannot be saved')
end
print('PASS special SQL recovery: Poison-to-Regular once-only conversion, same-revision independent sources, no Poison mint, atomic rollback and all unconfirmed arrow increases declined')
