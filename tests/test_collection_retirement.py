"""Real retirement Lua/receipt SQL with SQLite and an exact-item removal adapter."""
import unittest
import test_character_collections as collection_tests

class RetirementTest(unittest.TestCase):
    def setUp(self):
        self.h=collection_tests.CollectionTest();self.h.setUp()
        self.lua=self.h.lua;self.db=self.h.db
        self.db.executescript('CREATE TABLE inventory_collection_retirements(source_resource TEXT,operation_id TEXT,request_json TEXT,result_json TEXT,PRIMARY KEY(source_resource,operation_id));')
        self.h.get()
        for column in ('display_name TEXT','weight REAL','max_quantity INTEGER','max_stack_size INTEGER'):
            self.db.execute('ALTER TABLE items ADD COLUMN '+column)
        self.db.commit()
        # Run the production transaction lookup, not a fabricated adapter method.
        source=(collection_tests.ROOT/'server/services/transactions.lua').read_text(encoding='utf-8')
        body=source[source.index('function Tx:GetItemForUpdate('):source.index('function Tx:GetQuantity(')]
        self.lua.execute('local Tx={}\n'+body+'\nProductionLookup=Tx.GetItemForUpdate')
        self.lua.execute("""
            TransactionAPI.Transaction=function(context,body) return retirementTransaction(context,body) end
        """)
        self.lua.globals().retirementTransaction=self.transaction
        self.fail_remove=None
    def tearDown(self): self.h.tearDown()
    def transaction(self,context,fn):
        self.db.execute('BEGIN')
        tx=self.lua.table_from({'query':self.h.query,'GetItemForUpdate':self.lua.globals().ProductionLookup,'RemoveInstances':self.remove})
        try:
            result=fn(tx)
            if result.ok:self.db.commit();return result
            self.db.rollback();return result
        except Exception:
            self.db.rollback();return self.h.table({'ok':False,'error':{'code':'internal'}})
    def remove(self,tx,inventory,definition,ids):
        for id in ids.values():
            if id==self.fail_remove: raise RuntimeError('injected deletion failure')
            if self.db.execute('SELECT 1 FROM character_equipment WHERE inventory_items_id=?',(id,)).fetchone():
                return self.h.table({'ok':False,'error':{'code':'denied'}})
            self.db.execute('DELETE FROM inventory_items WHERE inventory_id=? AND item_id=? AND id=?',(inventory,definition,id))
        return self.h.table({'ok':True,'value':True})
    def request(self,**changes):
        value=dict(characterId='owner',collectionKey='tack.v1',operationId='sale:1',
            items=[dict(instanceId=101,revision=5),dict(instanceId=102,revision=3)],
            equipment={'horse_a':101,'tack_horn_101':102,'tack_stir_101':0})
        value.update(changes);return self.h.table(value)
    def retire(self,request=None): return self.lua.globals().CharacterCollectionAPI.Retire(request or self.request(),'issuer')
    def test_exact_assembly_retires_once_and_replays_historical_receipt(self):
        r=self.retire();self.assertTrue(r.ok);self.assertEqual(r.value.count,2)
        self.assertFalse(self.db.execute('SELECT id FROM inventory_items WHERE id IN (101,102)').fetchall())
        self.assertFalse(self.db.execute('SELECT * FROM character_equipment').fetchall())
        self.assertTrue(self.retire().ok)
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM inventory_collection_retirements').fetchone()[0],1)
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM inventory_items').fetchone()[0],2)
    def test_changed_revision_refuses_and_rolls_back_receipt(self):
        r=self.retire(self.request(items=[dict(instanceId=101,revision=4)]))
        self.assertFalse(r.ok)
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM inventory_collection_retirements').fetchone()[0],0)
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM character_equipment').fetchone()[0],2)
    def test_partial_delete_failure_restores_all_items_and_equipment(self):
        self.fail_remove=102;self.assertFalse(self.retire().ok)
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM inventory_items').fetchone()[0],4)
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM character_equipment').fetchone()[0],2)
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM inventory_collection_retirements').fetchone()[0],0)
        self.fail_remove=None;self.assertTrue(self.retire().ok)
    def test_new_component_in_expected_empty_anchor_blocks_entire_sale(self):
        self.db.execute("INSERT INTO character_equipment VALUES('owner','tack_stir_101',103)");self.db.commit()
        self.assertFalse(self.retire().ok)
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM inventory_items').fetchone()[0],4)
    def test_same_receipt_with_different_items_refused(self):
        self.assertTrue(self.retire().ok)
        changed=self.request(items=[dict(instanceId=104,revision=0)],equipment={})
        self.assertFalse(self.retire(changed).ok)
        self.assertIsNotNone(self.db.execute('SELECT id FROM inventory_items WHERE id=104').fetchone())
    def test_foreign_item_or_guard_denial_preserves_items(self):
        self.assertFalse(self.retire(self.request(items=[dict(instanceId=104,revision=0)],equipment={})).ok)
        self.lua.globals().blocked=102
        self.assertFalse(self.retire().ok)
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM inventory_items').fetchone()[0],4)

if __name__=='__main__':unittest.main()
