"""Collection custody: real Lua and SQLite SQL, no live player inventory."""
import json
import sqlite3
import unittest
from pathlib import Path
from lupa.lua54 import LuaRuntime
ROOT=Path(__file__).resolve().parents[1]

class CollectionTest(unittest.TestCase):
    def setUp(self):
        self.db=sqlite3.connect(':memory:')
        self.db.create_function('UUID',0,lambda:'collection-uuid')
        self.db.executescript("""
            CREATE TABLE inventory(id INTEGER PRIMARY KEY,uuid TEXT,character_id TEXT,owner_character_id TEXT,
                location TEXT,name TEXT,max_weight INTEGER,ignore_item_limit INTEGER,max_slots INTEGER,is_public INTEGER DEFAULT 0);
            CREATE TABLE items(id INTEGER PRIMARY KEY,name TEXT,type TEXT,instance_mode TEXT,archived_at TEXT);
            CREATE TABLE inventory_items(id INTEGER PRIMARY KEY,inventory_id INTEGER,item_id INTEGER,slot_index INTEGER,metadata TEXT,row_revision INTEGER DEFAULT 0);
            CREATE TABLE character_equipment(character_id TEXT,slot TEXT,inventory_items_id INTEGER UNIQUE,PRIMARY KEY(character_id,slot));
            CREATE TABLE inventory_character_collections(source_resource TEXT,collection_key TEXT,character_id TEXT,inventory_id INTEGER UNIQUE,
                PRIMARY KEY(source_resource,collection_key,character_id));
            CREATE TABLE inventory_unique_grant_receipts(source_resource TEXT,grant_id TEXT,request_fingerprint TEXT,result_json TEXT,PRIMARY KEY(source_resource,grant_id));
            INSERT INTO inventory(id,uuid,character_id,location,max_slots) VALUES(1,'carried','owner','character',2),(2,'foreign','other','character',2);
            INSERT INTO items VALUES(7,'horse_saddle','item_item','unique',NULL),(8,'apple','item_item','stack',NULL),(9,'horse_saddle_horn','item_item','unique',NULL);
            INSERT INTO inventory_items VALUES(101,1,7,1,'{"stablesTackOrder":"order-a","condition":67}',4),
                (102,1,9,2,'{"stablesTackOrder":"order-b","condition":42}',2),
                (103,1,8,3,'{}',0),(104,2,7,1,'{"stablesTackOrder":"foreign","condition":88}',0);
            INSERT INTO character_equipment VALUES('owner','horse_a',101),('owner','tack_horn_101',102);
        """)
        self.lua=LuaRuntime(unpack_returned_tuples=True)
        g=self.lua.globals();g.query=self.query;g.run=self.run_transaction;g.decode=self.decode;g.encode=self.encode
        self.lua.execute("""
            Config={TrustedCharacterCollections={issuer={['tack.v1']={maxItems=500,marker='stablesTackOrder',items={horse_saddle=true,horse_saddle_horn=true}}}},TrustedUniqueGrantCallers={issuer=true}}
            CreateThread=function() end;RegisterCommand=function() end
            InventoryIdentity={NormalizeCharacterId=function(id) return (id=='owner' or id=='other') and id or nil end}
            Result={Codes={INVALID_INPUT='invalid_input',DENIED='denied',CONFLICT='conflict',INTERNAL='internal'},
                Ok=function(v) return {ok=true,value=v} end,Err=function(c,m) return {ok=false,error={code=c,message=m}} end}
            GuardsAPI={CanChangeInstance=function(id) return id~=blocked,'Held' end}
            InventoryMetadata={Decode=decode};json={decode=decode,encode=encode}
            DB={query=function(sql,...) return query(sql,{...}) end}
            TransactionAPI={Transaction=run}
            RunLegacyStyleTransaction=function(fn)
                local r=run({},function() return fn(query) and Result.Ok(true) or Result.Err('rollback','Refused') end)
                return true,r.ok
            end
            InstancesAPI={GetInstance=function(id)
                local row=query('SELECT * FROM inventory_items WHERE id=?',{id})[1]
                if not row then return Result.Err('not_found') end
                local def=query('SELECT * FROM items WHERE id=?',{row.item_id})[1]
                return Result.Ok({id=id,inventoryId=row.inventory_id,revision=row.row_revision,metadata=decode(row.metadata),
                    definition={id=def.id,name=def.name,type=def.type,instanceMode=def.instance_mode}})
            end}
        """)
        for f in ('character_collections.lua','equipment.lua','grants_once.lua'):
            self.lua.execute((ROOT/'server/services'/f).read_text(encoding='utf-8'))
        self.api=g.CharacterCollectionAPI
        self.failed=False;self.fail_update=False;self.fail_equipment=False
    def tearDown(self): self.db.close()
    def table(self,value):
        if isinstance(value,dict): return self.lua.table_from({k:self.table(v) for k,v in value.items()})
        if isinstance(value,list): return self.lua.table_from([self.table(v) for v in value])
        return value
    def plain(self,value):
        if hasattr(value,'items'): return {k:self.plain(v) for k,v in value.items()}
        return value
    def decode(self,text): return self.table(json.loads(text or '{}'))
    def encode(self,value): return json.dumps(self.plain(value),sort_keys=True,separators=(',',':'))
    def query(self,sql,params):
        sql=sql.replace(' FOR UPDATE','').replace('INSERT IGNORE','INSERT OR IGNORE')
        if self.fail_update and sql.lstrip().startswith('UPDATE inventory_items'): raise RuntimeError('lost storage write')
        if self.fail_equipment and sql.lstrip().startswith('INSERT INTO character_equipment'): raise RuntimeError('assignment write failed')
        cur=self.db.execute(sql,[params[i] for i in range(1,len(params)+1)])
        if cur.description:
            names=[v[0] for v in cur.description]
            return self.table([dict(zip(names,row)) for row in cur.fetchall()])
        return self.table({'affectedRows':cur.rowcount})
    def run_transaction(self,context,fn):
        self.db.execute('BEGIN')
        tx=self.lua.table_from({'query':self.query,'CreateInstance':self.create})
        try:
            result=fn(tx)
            if result.ok: self.db.commit();return result
            self.db.rollback();return result
        except Exception:
            self.db.rollback();return self.table({'ok':False,'error':{'code':'internal'}})
    def create(self,tx,inventory,definition,metadata):
        count=self.db.execute('SELECT COUNT(*) FROM inventory_items WHERE inventory_id=?',(inventory,)).fetchone()[0]
        capacity=self.db.execute('SELECT max_slots FROM inventory WHERE id=?',(inventory,)).fetchone()[0]
        if count>=capacity: return self.table({'ok':False,'error':{'code':'limit_exceeded'}})
        cur=self.db.execute('INSERT INTO inventory_items(inventory_id,item_id,slot_index,metadata,row_revision) VALUES(?,?,?,?,0)',
            (inventory,definition,count,self.encode(metadata)))
        return self.table({'ok':True,'value':{'instanceId':cur.lastrowid,'revision':0}})
    def request(self,**args): return self.table(dict(characterId='owner',collectionKey='tack.v1',**args))
    def get(self,adopt=True): return self.api.Get(self.request(adopt=adopt),'issuer')
    def grant(self,key='new-order',collection=True):
        r=dict(grantId=key,characterId='owner',definitionId=7,itemName='horse_saddle',metadata={'condition':100,'stablesTackOrder':key})
        if collection:r['collectionKey']='tack.v1'
        return self.lua.globals().UniqueGrantOnceAPI.Grant(self.table(r),'issuer')
    def test_adoption_preserves_ids_metadata_and_assembly_and_frees_carried_space(self):
        result=self.get();self.assertTrue(result.ok);id=result.value.id
        self.assertEqual(self.db.execute('SELECT id,inventory_id,row_revision FROM inventory_items WHERE id IN (101,102) ORDER BY id').fetchall(),[(101,id,5),(102,id,3)])
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM inventory_items WHERE inventory_id=1').fetchone()[0],1)
        self.assertEqual(self.db.execute('SELECT metadata FROM inventory_items WHERE id=101').fetchone()[0],'{"stablesTackOrder":"order-a","condition":67}')
        self.assertEqual(self.db.execute('SELECT inventory_items_id FROM character_equipment ORDER BY slot').fetchall(),[(101,),(102,)])
        self.assertTrue(self.get().ok)
        self.assertEqual(self.db.execute('SELECT row_revision FROM inventory_items WHERE id=101').fetchone()[0],5)
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM inventory_character_collections').fetchone()[0],1)
    def test_item_reads_are_character_and_purpose_scoped(self):
        self.get()
        self.assertTrue(self.api.Item(self.request(instanceId=101),'issuer').ok)
        self.assertFalse(self.api.Item(self.request(instanceId=104),'issuer').ok)
        self.assertFalse(self.api.Item(self.table(dict(characterId='other',collectionKey='tack.v1',instanceId=101)),'issuer').ok)
        self.assertFalse(self.api.Get(self.request(),'untrusted').ok)
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM inventory_character_collections').fetchone()[0],1)
    def test_missing_marker_and_unrelated_items_stay_carried(self):
        self.db.execute('UPDATE inventory_items SET metadata=? WHERE id=102',('{"condition":42}',));self.db.commit()
        self.get()
        self.assertEqual(self.db.execute('SELECT inventory_id FROM inventory_items WHERE id=102').fetchone()[0],1)
        self.assertEqual(self.db.execute('SELECT inventory_id FROM inventory_items WHERE id=103').fetchone()[0],1)
    def test_guard_or_sql_failure_rolls_back_all_adoption(self):
        self.lua.globals().blocked=102
        self.assertFalse(self.get().ok)
        self.assertEqual(self.db.execute('SELECT inventory_id,row_revision FROM inventory_items WHERE id=101').fetchone(),(1,4))
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM inventory_character_collections').fetchone()[0],0)
        self.lua.globals().blocked=None;self.fail_update=True
        self.assertFalse(self.get().ok)
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM inventory_character_collections').fetchone()[0],0)
    def test_full_collection_rolls_back_and_never_drops_items(self):
        self.lua.execute("Config.TrustedCharacterCollections.issuer['tack.v1'].maxItems=1")
        self.assertFalse(self.get().ok)
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM inventory_items WHERE inventory_id=1').fetchone()[0],3)
    def test_new_grant_bypasses_full_carried_capacity_and_replays_once(self):
        first=self.grant();self.assertTrue(first.ok)
        self.assertNotEqual(first.value.inventoryId,1)
        again=self.grant();self.assertTrue(again.ok);self.assertEqual(first.value.instanceId,again.value.instanceId)
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM inventory_items').fetchone()[0],5)
        self.assertFalse(self.grant(collection=False).ok,'Same receipt cannot change custody fingerprint')
    def test_old_receipt_replays_after_adoption_without_regrant(self):
        self.db.execute('UPDATE inventory SET max_slots=100 WHERE id=1');self.db.commit()
        old=self.grant(collection=False);self.assertTrue(old.ok)
        self.get()
        again=self.grant(collection=False);self.assertTrue(again.ok);self.assertEqual(again.value.instanceId,old.value.instanceId)
        self.assertNotEqual(self.db.execute('SELECT inventory_id FROM inventory_items WHERE id=?',(old.value.instanceId,)).fetchone()[0],1)
    def test_collection_equipment_works_but_carried_api_still_refuses(self):
        self.get()
        changes=self.table([dict(slot='horse_a',expected=101,instanceId=0),dict(slot='horse_b',expected=0,instanceId=101)])
        self.assertFalse(self.lua.globals().EquipmentAPI.SetEquipmentBatchForCharacter('owner',changes).ok)
        result=self.api.Batch(self.request(changes=changes),'issuer');self.assertTrue(result.ok)
        self.assertEqual(self.db.execute("SELECT inventory_items_id FROM character_equipment WHERE slot='horse_b'").fetchone()[0],101)
        self.assertEqual(self.db.execute('SELECT inventory_items_id FROM character_equipment WHERE slot=?',('tack_horn_101',)).fetchone()[0],102)
    def test_adoption_uses_zero_based_slots_through_last_available_slot(self):
        self.lua.execute("Config.TrustedCharacterCollections.issuer['tack.v1'].maxItems=2")
        result=self.get();self.assertTrue(result.ok)
        self.assertEqual(self.db.execute('SELECT slot_index FROM inventory_items WHERE inventory_id=? ORDER BY slot_index',(result.value.id,)).fetchall(),[(0,),(1,)])
        self.assertFalse(self.grant().ok)

    def test_same_character_other_scope_cannot_read_or_equip_collection_items(self):
        self.get()
        self.lua.execute("Config.TrustedCharacterCollections.issuer.other=Config.TrustedCharacterCollections.issuer['tack.v1']")
        other=self.table(dict(characterId='owner',collectionKey='other'))
        self.assertTrue(self.api.Get(other,'issuer').ok)
        other.instanceId=101
        self.assertFalse(self.api.Item(other,'issuer').ok)
        other.changes=self.table([dict(slot='horse_a',expected=101,instanceId=0)])
        self.assertFalse(self.api.Batch(other,'issuer').ok)
        self.assertEqual(self.db.execute("SELECT inventory_items_id FROM character_equipment WHERE slot='horse_a'").fetchone()[0],101)
    def test_collection_grant_respects_configured_slots_and_does_not_leak_to_carried(self):
        self.get()
        self.lua.execute("Config.TrustedCharacterCollections.issuer['tack.v1'].maxItems=2")
        before=self.db.execute('SELECT COUNT(*) FROM inventory_items').fetchone()[0]
        self.assertFalse(self.grant().ok)
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM inventory_items').fetchone()[0],before)
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM inventory_unique_grant_receipts').fetchone()[0],0)
    def test_storage_resolves_same_container_after_resource_reload(self):
        first=self.get();id=first.value.id
        self.lua.execute((ROOT/'server/services/character_collections.lua').read_text(encoding='utf-8'))
        self.api=self.lua.globals().CharacterCollectionAPI
        self.assertEqual(self.get().value.id,id)
        self.assertEqual(self.api.Item(self.request(instanceId=101),'issuer').value.metadata.condition,67)
        self.assertEqual(self.db.execute('SELECT row_revision FROM inventory_items WHERE id=101').fetchone()[0],5)

    def test_collection_identity_tampering_refuses_without_recreation(self):
        r=self.get();self.assertTrue(r.ok)
        self.db.execute('UPDATE inventory SET is_public=1 WHERE id=?',(r.value.id,));self.db.commit()
        self.assertFalse(self.get().ok)
        self.assertEqual(self.db.execute('SELECT COUNT(*) FROM inventory_character_collections').fetchone()[0],1)

if __name__=='__main__':unittest.main()
