"""Actual Lua startup against a disposable local CI MariaDB; never the game DB."""
import os
import unittest
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

@unittest.skipUnless(os.environ.get('FEATHER_SCHEMA_TEST_PORT'), 'isolated CI MariaDB not configured')
class AmmunitionSchemaMariaDB(unittest.TestCase):
    def test_actual_startup_fresh_existing_partial_and_incompatible(self):
        import pymysql
        from lupa.lua54 import LuaRuntime
        connection = pymysql.connect(host='127.0.0.1', port=int(os.environ['FEATHER_SCHEMA_TEST_PORT']),
                                     user='root', password=os.environ['FEATHER_SCHEMA_TEST_PASSWORD'],
                                     autocommit=True, cursorclass=pymysql.cursors.DictCursor)
        created = []
        def execute(sql, parameters=()):
            with connection.cursor() as cursor:
                cursor.execute(sql, parameters)
                return cursor.fetchall() if cursor.description else cursor.rowcount
        def database():
            name = 'fi_ammo_schema_ci_' + uuid.uuid4().hex
            execute('CREATE DATABASE `' + name + '` CHARACTER SET utf8mb4')
            created.append(name)
            execute('USE `' + name + '`')
        def startup():
            lua = LuaRuntime(unpack_returned_tuples=True)
            lua.globals().Config = lua.table_from({'CharacterAmmunitionEnabled': True})
            lua.globals().GetCurrentResourceName = lambda: 'feather-inventory'
            def load(resource, name):
                self.assertEqual((resource, name), ('feather-inventory', 'database/character_ammunition.sql'))
                return (ROOT / name).read_text(encoding='utf-8')
            lua.globals().LoadResourceFile = load
            lua.globals().DB = lua.table_from({
                'exec': lambda sql: execute(sql),
                'query': lambda sql, *params: lua.table_from([lua.table_from(row) for row in execute(sql, params)])})
            lua.execute((ROOT / 'server/services/character_ammunition_schema.lua').read_text(encoding='utf-8'))
            return lua.globals().InventoryCharacterAmmoSchema.Start()
        def snapshot():
            return (execute('SELECT * FROM feather_character_ammunition ORDER BY character_id'),
                    execute('SELECT * FROM feather_ammunition_operations ORDER BY character_id,operation_id'))
        try:
            database()
            self.assertTrue(startup())
            self.assertEqual(snapshot(), ([], []))
            character = '00000000-0000-0000-0000-000000000001'
            execute('INSERT INTO feather_character_ammunition(character_id,revision,pools) VALUES (%s,57,%s)',
                    (character, '{"ammo_revolver_regular":1}'))
            execute('INSERT INTO feather_ammunition_operations(character_id,operation_id,result) VALUES (%s,%s,%s)',
                    (character, 'preserve-receipt', '{"saved":true}'))
            before = snapshot()
            self.assertTrue(startup())
            self.assertEqual(snapshot(), before)
            database()
            execute('CREATE TABLE feather_character_ammunition LIKE `' + created[0] + '`.feather_character_ammunition')
            self.assertTrue(startup())
            self.assertEqual(snapshot(), ([], []))
            execute('ALTER TABLE feather_character_ammunition ENGINE=MyISAM')
            before = snapshot()
            with self.assertRaisesRegex(Exception, 'requires InnoDB'):
                startup()
            self.assertEqual(snapshot(), before)
            engine = execute("SELECT ENGINE FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE() AND TABLE_NAME='feather_character_ammunition'")
            self.assertEqual(engine[0]['ENGINE'], 'MyISAM', 'startup must not repair incompatible storage')
        finally:
            for name in created:
                self.assertRegex(name, r'^fi_ammo_schema_ci_[0-9a-f]{32}$')
                execute('DROP DATABASE `' + name + '`')
            connection.close()

if __name__ == '__main__':
    unittest.main()
