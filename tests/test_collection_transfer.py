"""Real collection transfer SQL and production transaction item lookup."""
import unittest
import test_collection_retirement as retirement


class TransferTest(unittest.TestCase):
    def setUp(self):
        retirement.RetirementTest.setUp(self)
        self.db.execute('CREATE TABLE inventory_collection_transfers(source_resource TEXT,operation_id TEXT,request_json TEXT,result_json TEXT,PRIMARY KEY(source_resource,operation_id))')
        self.db.execute("UPDATE character_equipment SET slot='tack_saddle_101' WHERE inventory_items_id=101")
        self.db.commit()
        self.lua.execute("GuardsAPI.CanMoveInstanceSnapshot=function(i,c) return i.id~=moveBlocked and c.reason=='collection_transfer','Held' end")

    transaction=retirement.RetirementTest.transaction
    remove=retirement.RetirementTest.remove
    tearDown=retirement.RetirementTest.tearDown

    def request(self,**changes):
        value=dict(characterId='owner',recipientCharacterId='other',collectionKey='tack.v1',operationId='trade:1',
            items=[dict(instanceId=101,revision=5),dict(instanceId=102,revision=3)],
            equipment={'tack_saddle_101':101,'tack_horn_101':102,'tack_stir_101':0})
        value.update(changes)
        return self.h.table(value)

    def transfer(self,request=None):
        return self.lua.globals().CharacterCollectionAPI.Transfer(request or self.request(),'issuer')

    def test_assembly_moves_same_ids_metadata_and_condition_once(self):
        before=self.db.execute('SELECT id,metadata FROM inventory_items ORDER BY id').fetchall()
        result=self.transfer();self.assertTrue(result.ok)
        self.assertTrue(result.value.transferred);self.assertEqual(result.value.count,2)
        self.assertEqual(self.db.execute('SELECT id,metadata FROM inventory_items ORDER BY id').fetchall(),before)
        self.assertEqual(self.db.execute('SELECT row_revision FROM inventory_items WHERE id IN (101,102) ORDER BY id').fetchall(),[(6,),(4,)])
        self.assertEqual(self.db.execute('SELECT DISTINCT character_id FROM character_equipment').fetchall(),[('other',)])
        self.assertTrue(self.transfer().value.replayed)
        self.assertEqual(self.db.execute('SELECT row_revision FROM inventory_items WHERE id=101').fetchone()[0],6)
        self.assertFalse(self.lua.globals().CharacterCollectionAPI.Item(self.h.request(instanceId=101),'issuer').ok)
        target=self.h.table(dict(characterId='other',collectionKey='tack.v1',instanceId=101))
        self.assertTrue(self.lua.globals().CharacterCollectionAPI.Item(target,'issuer').ok)

    def test_target_capacity_refusal_leaves_everything_owned_by_sender(self):
        self.lua.execute("Config.TrustedCharacterCollections.issuer['tack.v1'].maxItems=1")
        self.assertFalse(self.transfer().ok)
        self.assertEqual(self.db.execute('SELECT DISTINCT character_id FROM character_equipment').fetchall(),[('owner',)])
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM inventory_collection_transfers').fetchone()[0],0)

    def test_new_attachment_or_stale_revision_blocks_whole_transfer(self):
        self.assertFalse(self.transfer(self.request(items=[dict(instanceId=101,revision=4)])).ok)
        self.db.execute("INSERT INTO character_equipment VALUES('owner','tack_stir_101',103)");self.db.commit()
        self.assertFalse(self.transfer().ok)
        self.assertEqual(self.db.execute('SELECT row_revision FROM inventory_items WHERE id=101').fetchone()[0],5)

    def test_move_guard_and_sql_failure_roll_back_both_custodies(self):
        self.lua.globals().moveBlocked=102
        self.assertFalse(self.transfer().ok)
        self.assertEqual(self.db.execute('SELECT row_revision FROM inventory_items WHERE id=101').fetchone()[0],5)
        self.lua.globals().moveBlocked=None;self.h.fail_update=True
        self.assertFalse(self.transfer().ok)
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM inventory_collection_transfers').fetchone()[0],0)
        self.h.fail_update=False;self.assertTrue(self.transfer().ok)

    def test_receipt_terms_cannot_change_recipient_or_items(self):
        self.assertTrue(self.transfer().ok)
        changed=self.request(items=[dict(instanceId=101,revision=6)],equipment={})
        self.assertFalse(self.transfer(changed).ok)
        self.assertFalse(self.transfer(self.request(recipientCharacterId='owner')).ok)

    def test_foreign_equipment_corruption_fails_closed(self):
        self.db.execute("UPDATE character_equipment SET character_id='other' WHERE inventory_items_id=102");self.db.commit()
        self.assertFalse(self.transfer().ok)

    def test_untrusted_scope_is_denied(self):
        self.assertFalse(self.lua.globals().CharacterCollectionAPI.Transfer(self.request(),'foreign').ok)


if __name__=='__main__':unittest.main()
