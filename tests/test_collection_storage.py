"""Item-attached storage: real provider Lua and SQLite transaction bodies."""
import unittest
import test_collection_retirement as retirement
from test_character_collections import ROOT

class StorageTest(unittest.TestCase):
    def setUp(self):
        self.base=retirement.RetirementTest();self.base.setUp()
        self.h=self.base.h;self.lua=self.h.lua;self.db=self.h.db
        self.db.executescript("UPDATE items SET display_name='Apple' WHERE name='apple';")
        self.db.executescript("CREATE TABLE inventory_collection_storage(instance_id INTEGER PRIMARY KEY,source_resource TEXT,collection_key TEXT,inventory_id INTEGER UNIQUE);")
        self.lua.execute("""
            AddEventHandler=function(name,fn) stopHandler=fn end
            Config.TrustedCharacterCollections.issuer['tack.v1'].storageItems={horse_saddle=true}
            live=true;resourceStarted=true;sessionCharacter='owner'
            InventoryIdentity.GetSession=function(src) return {ok=true,value={characterId=sessionCharacter}} end
            GetResourceState=function() return resourceStarted and 'started' or 'stopped' end
            InventoryAPI={OpenInventory=function(src,uuid) openedUuid=uuid;return Result.Ok(true) end}
        """)
        self.lua.execute((ROOT/'server/services/collection_storage.lua').read_text(encoding='utf-8'))
        self.api=self.lua.globals().CollectionStorageAPI
        self.lua.execute("registered=CollectionStorageAPI.Register({collectionKey='tack.v1',itemName='horse_saddle',slots=50,maxWeight=250,validate=function(src,id) return live and src==3 and id==101 end},'issuer')")
        self.assertTrue(self.lua.globals().registered.ok)
    def tearDown(self): self.base.tearDown()
    def request(self,**kw):
        value=dict(characterId='owner',collectionKey='tack.v1',instanceId=101,source=3)
        value.update(kw);return self.h.table(value)
    def get(self,create=True):return self.api.Get(self.request(create=create),'issuer')
    def fill(self,id):
        self.db.execute("INSERT INTO inventory_items VALUES(201,?,8,0,'{}',0)",(id,));self.db.commit()
    def test_lazy_creation_replay_and_capacity(self):
        self.assertEqual(self.get(False).value.itemCount,0)
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM inventory_collection_storage').fetchone()[0],0)
        a=self.get();self.assertTrue(a.ok);b=self.get();self.assertTrue(b.ok)
        self.assertEqual(a.value.id,b.value.id)
        self.assertEqual(self.db.execute('SELECT max_slots,max_weight,is_public,owner_character_id FROM inventory WHERE id=?',(a.value.id,)).fetchone(),(50,250,0,None))
        self.fill(a.value.id);self.assertEqual(self.get(False).value.itemCount,1)
    def test_summary_counts_stacked_rows_as_one_occupied_slot(self):
        id=self.get().value.id;self.fill(id)
        self.db.execute("INSERT INTO inventory_items VALUES(202,?,8,0,'{}',0)",(id,));self.db.commit()
        self.assertEqual(self.get(False).value.itemCount,1)

    def test_snapshot_lists_quantities_and_detects_same_count_content_changes(self):
        id=self.get().value.id;self.fill(id)
        request=self.request(create=False,snapshot=True)
        first=self.api.Get(request,'issuer').value
        self.assertEqual(first.contentsVersion,1)
        self.assertEqual(first.contents[1].itemName,'apple')
        self.assertEqual(first.contents[1].itemLabel,'Apple')
        self.assertEqual(first.contents[1].quantity,1)
        self.db.execute("UPDATE inventory_items SET metadata='{\"display\":\"Changed\"}',row_revision=row_revision+1 WHERE id=201");self.db.commit()
        second=self.api.Get(request,'issuer').value
        self.assertEqual(first.itemCount,second.itemCount)
        self.assertNotEqual(first.contentsRevision,second.contentsRevision)
        self.assertEqual(second.contentsRevision,self.api.Get(request,'issuer').value.contentsRevision)

    def test_access_is_live_and_session_custody_bound(self):
        id=self.get().value.id
        self.assertTrue(self.api.Access(3,id,'read'))
        self.assertTrue(self.api.Access(3,id,'insert',self.h.query))
        self.assertFalse(self.api.Access(3,id,'manage'))
        self.lua.execute('live=false');self.assertFalse(self.api.Access(3,id,'remove'))
        self.lua.execute("live=true;sessionCharacter='other'");self.assertFalse(self.api.Access(3,id,'read'))
        self.lua.execute("sessionCharacter='owner';resourceStarted=false");self.assertFalse(self.api.Access(3,id,'read'))
        self.lua.execute("resourceStarted=true;stopHandler('issuer')");self.assertFalse(self.api.Access(3,id,'read'))
    def test_open_refuses_remote_or_foreign_and_only_discloses_on_success(self):
        self.lua.execute('live=false');self.assertFalse(self.api.Open(self.request(),'issuer').ok)
        self.assertIsNone(self.lua.globals().openedUuid)
        self.lua.execute('live=true');self.assertTrue(self.api.Open(self.request(),'issuer').ok)
        self.assertFalse(self.api.Open(self.request(characterId='other'),'issuer').ok)
        self.assertFalse(self.api.Get(self.request(),'foreign').ok)
    def test_filled_container_blocks_retirement_atomically(self):
        id=self.get().value.id;self.fill(id)
        r=self.base.retire();self.assertFalse(r.ok);self.assertEqual(r.error.code,'storage_not_empty')
        self.assertIsNotNone(self.db.execute('SELECT id FROM inventory_items WHERE id=101').fetchone())
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM inventory_collection_retirements').fetchone()[0],0)
        self.db.execute('DELETE FROM inventory_items WHERE id=201');self.db.commit()
        self.assertTrue(self.base.retire().ok)
    def test_storage_stays_with_instance_when_custody_changes(self):
        id=self.get().value.id;self.fill(id)
        collection=self.db.execute('SELECT inventory_id FROM inventory_character_collections').fetchone()[0]
        self.db.execute("UPDATE inventory_character_collections SET character_id='other' WHERE inventory_id=?",(collection,));self.db.commit()
        self.assertFalse(self.api.Access(3,id,'read'))
        self.lua.execute("sessionCharacter='other'")
        self.assertTrue(self.api.Access(3,id,'read'))
        self.assertEqual(self.api.Get(self.request(characterId='other',create=False),'issuer').value.id,id)
        self.assertEqual(self.db.execute('SELECT inventory_id FROM inventory_items WHERE id=201').fetchone()[0],id)
    def test_policy_requires_exact_item_and_bounded_capacity(self):
        self.lua.execute("invalid=CollectionStorageAPI.Register({collectionKey='tack.v1',itemName='apple',slots=50,maxWeight=250,validate=function() return true end},'issuer')")
        self.assertFalse(self.lua.globals().invalid.ok)
        self.lua.execute("invalid=CollectionStorageAPI.Register({collectionKey='tack.v1',itemName='horse_saddle',slots=0,maxWeight=250,validate=function() return true end},'issuer')")
        self.assertFalse(self.lua.globals().invalid.ok)

if __name__=='__main__':unittest.main()
