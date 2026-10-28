"""Real equipment Lua and SQL against SQLite; no player data or native copies."""
import sqlite3
import unittest
from pathlib import Path
from lupa.lua54 import LuaRuntime
ROOT=Path(__file__).resolve().parents[1]

class EquipmentBatchTest(unittest.TestCase):
    def setUp(self):
        self.db=sqlite3.connect(':memory:')
        self.db.executescript("""CREATE TABLE inventory(id INTEGER PRIMARY KEY,character_id TEXT);
        CREATE TABLE inventory_items(id INTEGER PRIMARY KEY,inventory_id INTEGER);
        CREATE TABLE character_equipment(character_id TEXT,slot TEXT,inventory_items_id INTEGER UNIQUE,PRIMARY KEY(character_id,slot));
        INSERT INTO inventory VALUES(1,'owner'),(2,'other');
        INSERT INTO inventory_items VALUES(1,1),(2,1),(3,1),(4,1),(5,2);
        INSERT INTO character_equipment VALUES('owner','horse_a',1),('owner','horn_a',2),('owner','horse_b',3);
        """)
        self.lua=LuaRuntime(unpack_returned_tuples=True)
        self.lua.globals().query=self.query
        self.lua.globals().transaction=self.transaction
        self.lua.execute("""
            Config={};CreateThread=function() end
            InventoryIdentity={NormalizeCharacterId=function(id) return id=='owner' and id or nil end}
            Result={Codes={INVALID_INPUT='invalid',DENIED='denied',CONFLICT='conflict',INTERNAL='internal'},
                Ok=function(v) return {ok=true,value=v} end,Err=function(c,m) return {ok=false,error={code=c,message=m}} end}
            GuardsAPI={CanChangeInstance=function(id) return id~=blocked,'Held' end}
            RunLegacyStyleTransaction=transaction
        """)
        self.lua.execute((ROOT/'server/services/equipment.lua').read_text(encoding='utf-8'))
    def tearDown(self): self.db.close()
    def query(self,sql,params):
        args=[params[i] for i in range(1,len(params)+1)]
        if self.fail_insert and sql.startswith('INSERT'): raise RuntimeError('injected failure')
        cur=self.db.execute(sql.replace(' FOR UPDATE',''),args)
        if cur.description:
            names=[d[0] for d in cur.description]
            return self.lua.table_from([self.lua.table_from(dict(zip(names,r))) for r in cur.fetchall()])
        return self.lua.table_from({'affectedRows':cur.rowcount})
    def transaction(self,fn):
        self.db.execute('BEGIN')
        try:
            accepted=fn(self.lua.globals().query)
            if accepted is True: self.db.commit();return True,True
            self.db.rollback();return True,False
        except Exception:
            self.db.rollback();return False,False
    def apply(self,changes):
        self.fail_insert=getattr(self,'fail_insert',False)
        return self.lua.globals().EquipmentAPI.SetEquipmentBatchForCharacter('owner',self.lua.table_from([self.lua.table_from(c) for c in changes]))
    def snapshot(self): return self.db.execute('SELECT * FROM character_equipment ORDER BY slot').fetchall()
    def changes(self): return [dict(slot='horse_a',expected=1,instanceId=0),dict(slot='horse_b',expected=3,instanceId=1),dict(slot='rack_3',expected=0,instanceId=3)]
    def test_batch_replaces_and_parks_same_instances(self):
        self.assertTrue(self.apply(self.changes()).ok)
        self.assertEqual(self.snapshot(),[('owner','horn_a',2),('owner','horse_b',1),('owner','rack_3',3)])
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM inventory_items').fetchone()[0],5)
    def test_stale_expected_guard_failure_and_foreign_item_are_atomic(self):
        before=self.snapshot()
        cases=[self.changes()+[dict(slot='extra',expected=9,instanceId=0)],
            [dict(slot='new',expected=0,instanceId=5)],
            [dict(slot='new',expected=0,instanceId=1)]]
        for changes in cases:
            self.assertFalse(self.apply(changes).ok);self.assertEqual(self.snapshot(),before)
        self.lua.globals().blocked=3
        self.assertFalse(self.apply(self.changes()).ok);self.assertEqual(self.snapshot(),before)
    def test_failure_after_deletes_rolls_back_entire_batch(self):
        before=self.snapshot();self.fail_insert=True
        self.assertFalse(self.apply(self.changes()).ok);self.assertEqual(self.snapshot(),before)
    def test_duplicate_destination_rejected_and_old_contract_unchanged(self):
        before=self.snapshot()
        self.assertFalse(self.apply([dict(slot='a',expected=0,instanceId=4),dict(slot='b',expected=0,instanceId=4)]).ok)
        self.assertEqual(self.snapshot(),before)
        self.assertIsNotNone(self.lua.globals().EquipmentAPI.SetEquippedForCharacter)

if __name__=='__main__':unittest.main()
