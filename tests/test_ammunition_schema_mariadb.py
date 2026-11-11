"""Actual Lua startup against a disposable local CI MariaDB; never the game DB."""
import os
import unittest
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def execute_cursor(cursor, sql, parameters=()):
    cursor.execute(sql, parameters)
    # PyMySQL uses tuples for rows, including an empty tuple for an empty table.
    return list(cursor.fetchall()) if cursor.description else cursor.rowcount


def runtime_query(execute, lua, sql, parameters):
    # Only the resource's fixed schema queries enter here. feather-mysql uses
    # question-mark parameters; administrative test SQL already uses PyMySQL %s.
    if sql.count('?') != len(parameters):
        raise ValueError('Unexpected schema query parameter count')
    rows = execute(sql.replace('?', '%s'), parameters)
    return lua.table_from([lua.table_from(row) for row in rows])


class SchemaTestAdapter(unittest.TestCase):
    def test_runtime_parameters_use_driver_placeholders(self):
        from types import SimpleNamespace
        lua = SimpleNamespace(table_from=lambda value: value)
        calls = []
        def execute(sql, parameters):
            # Exercise the same formatting boundary that failed in PyMySQL.
            self.assertNotIn('?', sql)
            formatted = sql % tuple(repr(value) for value in parameters)
            calls.append((sql, parameters, formatted))
            return [{'table_name': 'feather_character_ammunition'}]
        result = runtime_query(execute, lua,
                               'SELECT * FROM metadata WHERE table_name IN (?,?)',
                               ('feather_character_ammunition', 'feather_ammunition_operations'))
        self.assertEqual(result[0]['table_name'], 'feather_character_ammunition')
        self.assertEqual(calls[0][0].count('%s'), 2)
        self.assertEqual(calls[0][1], ('feather_character_ammunition', 'feather_ammunition_operations'))
        with self.assertRaises(ValueError):
            runtime_query(execute, lua, 'SELECT * WHERE name=?', ())
        self.assertEqual(len(calls), 1)

    def test_empty_driver_rows_are_normalized(self):
        from types import SimpleNamespace
        cursor = SimpleNamespace(execute=lambda sql, params: None, description=('column',),
                                 fetchall=lambda: (), rowcount=0)
        self.assertEqual(execute_cursor(cursor, 'SELECT * FROM empty_table'), [])
        cursor.description = None
        self.assertEqual(execute_cursor(cursor, 'CREATE TABLE example(id INT)'), 0)

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
                return execute_cursor(cursor, sql, parameters)
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
                'query': lambda sql, *params: runtime_query(execute, lua, sql, params)})
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
