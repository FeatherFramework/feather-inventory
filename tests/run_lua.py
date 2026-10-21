"""Run with Lua 5.4 via optional lupa; not a resource/runtime dependency."""
import argparse
import sys
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--lupa-dir', type=Path)
args = parser.parse_args()
if args.lupa_dir:
    sys.path.insert(0, str(args.lupa_dir.resolve()))
from lupa.lua54 import LuaRuntime

root = Path(__file__).resolve().parents[1]
lua = LuaRuntime(unpack_returned_tuples=True)
files = [root / 'config.lua', root / 'fxmanifest.lua']
for folder in ('client', 'server', 'translations'):
    files.extend((root / folder).rglob('*.lua'))
for file in files:
    lua.execute('assert(load(...))', file.read_text(encoding='utf-8-sig'), '@' + str(file))
print(f'PASS Lua 5.4 syntax ({len(files)} files)', flush=True)
guard_lua = LuaRuntime(unpack_returned_tuples=True)
guard_lua.globals().arg = guard_lua.table_from({1: root.as_posix()})
guard_lua.execute((root / 'tests/lua/instance_change_guard_spec.lua').read_text(encoding='utf-8'))
lua.globals().arg = lua.table_from({1: root.as_posix()})
lua.execute((root / 'tests/lua/slot_updates_spec.lua').read_text(encoding='utf-8'))
lua = LuaRuntime(unpack_returned_tuples=True)
lua.globals().arg = lua.table_from({1: root.as_posix()})
lua.execute((root / 'tests/lua/guard_equipment_spec.lua').read_text(encoding='utf-8'))
lua = LuaRuntime(unpack_returned_tuples=True)
lua.globals().arg = lua.table_from({1: root.as_posix()})
lua.execute((root / 'tests/lua/access_reads_spec.lua').read_text(encoding='utf-8'))

lua = LuaRuntime(unpack_returned_tuples=True)
lua.globals().arg = lua.table_from({1: root.as_posix()})
lua.execute((root / 'tests/lua/startup_readiness_spec.lua').read_text(encoding='utf-8'))

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute((root / 'tests/lua/character_ammo_spec.lua').read_text(encoding='utf-8'))

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute((root / 'tests/lua/character_ammo_fixture_spec.lua').read_text(encoding='utf-8'))

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute((root / 'tests/lua/character_ammo_pair_spec.lua').read_text(encoding='utf-8'))

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute((root / 'tests/lua/character_ammo_enrollment_spec.lua').read_text(encoding='utf-8'))
lua.execute((root / 'tests/lua/native_empty_enrollment_spec.lua').read_text(encoding='utf-8'))

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute((root / 'tests/lua/character_ammo_enrollment_fixture_spec.lua').read_text(encoding='utf-8'))

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute((root / 'tests/lua/character_ammo_observation_spec.lua').read_text(encoding='utf-8'))

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute((root / 'tests/lua/character_ammo_native_preview_spec.lua').read_text(encoding='utf-8'))

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute((root / 'tests/lua/character_ammo_runtime_snapshot_spec.lua').read_text(encoding='utf-8'))

# New native UI/equipment and dedicated-alpha regressions run in isolated VMs.
for name in (
    'character_ammo_jane_readscope_spec.lua', 'character_ammo_jane_spec.lua',
    'character_ammo_native_fixture_spec.lua', 'conditional_equipment_spec.lua',
    'inventory_client_lifecycle_spec.lua', 'jane_ammo_budget_spec.lua',
    'jane_economic_verify_spec.lua', 'native_ammo_nui_spec.lua',
    'native_ammo_preflight_spec.lua', 'native_ammo_preview_spec.lua',
    'native_equipment_commit_spec.lua', 'native_equipment_nui_spec.lua',
    'native_equipment_preflight_spec.lua',
    'native_knife_equipment_spec.lua',
    'native_utility_equipment_spec.lua',
    'native_equipment_snapshot_spec.lua',
    'native_reinforced_lasso_equipment_spec.lua',
    'native_utility_equipment_commit_spec.lua',
    'native_utility_export_spec.lua',
    'native_utility_projection_composition_spec.lua',
    'native_melee_equipment_spec.lua',
    'native_throwable_equipment_spec.lua',
    'native_throwable_funding_spec.lua',
    'native_throwable_funding_atomic_spec.lua',
    'native_throwable_budget_spec.lua',
    'native_throwable_recovery_claim_spec.lua',
    'native_throwable_native_pickup_claim_spec.lua',
    'native_throwable_native_pickup_spend_spec.lua',
    'native_throwable_native_pickup_export_spec.lua',
    'native_knife_export_spec.lua',
    'native_melee_export_spec.lua',
    'native_throwable_export_spec.lua',
    'native_repair_commit_spec.lua',
    'native_evidence_commit_spec.lua',
    'native_evidence_export_spec.lua',
    'native_repair_material_spec.lua',
    'native_attachment_commit_spec.lua',
    'native_attachment_export_spec.lua',
    'native_attachment_composition_spec.lua',
    'native_attachment_material_spec.lua',
    'native_death_wear_atomic_spec.lua',
    'native_repair_verify_spec.lua',
    'native_repair_audit_spec.lua',
    'native_repair_fixture_spec.lua',
    'native_john_fixture_spec.lua',
    'native_issuance_spec.lua',
    'native_saved_attachment_fixture_spec.lua',
    'native_saved_attachment_fixture_gates_spec.lua',
    'native_lifecycle_wear_spec.lua',
    'native_broken_equipment_spec.lua',
):
    isolated = LuaRuntime(unpack_returned_tuples=True)
    isolated.globals().arg = isolated.table_from({1: root.as_posix()})
    isolated.execute((root / 'tests/lua' / name).read_text(encoding='utf-8-sig'))
