"""Keep startup ammunition schema in the runtime-only release package."""
import importlib.util
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('ammo_verify_release', ROOT / 'scripts/verify_release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)

class AmmunitionSchemaPackage(unittest.TestCase):
    def test_packaged_authoritative_schema(self):
        name = 'database/character_ammunition.sql'
        self.assertIn(name, release.runtime_files(ROOT))
        sql = (ROOT / name).read_text(encoding='utf-8')
        sql = re.sub(r'--[^\r\n]*', '', sql)
        statements = [s.strip() for s in sql.split(';') if s.strip()]
        self.assertEqual(len(statements), 2)
        for statement, table in zip(statements, ('feather_character_ammunition', 'feather_ammunition_operations')):
            self.assertRegex(statement, '^CREATE TABLE IF NOT EXISTS ' + table + r'\s*\(')
            self.assertIn('ENGINE=InnoDB', statement)
            self.assertNotRegex(statement, r'\b(?:INSERT|UPDATE|DELETE|ALTER|DROP)\b')

    def test_startup_call_precedes_economic_services_and_ready(self):
        source = (ROOT / 'server/services/api.lua').read_text(encoding='utf-8')
        awaited = source.index('  InventoryAwaitDatabase()')
        schema = source.index('  assert(InventoryCharacterAmmoSchema.Start()')
        grants = source.index('  GrantOnceAPI.Start()')
        ready = source.index("  InventoryReadiness.state = 'ready'")
        self.assertLess(awaited, schema)
        self.assertLess(schema, grants)
        self.assertLess(grants, ready)

if __name__ == '__main__':
    unittest.main()
