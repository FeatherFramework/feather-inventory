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
