-- Read-only audit for the accepted John/Jane regular-Tomahawk test.
-- Run while both players are idle; separate SELECTs are not an atomic snapshot.
-- Expected current baseline: John revision16/Tomahawk1; Jane revision35/Tomahawk0.
-- Jane may show SQL NULL for the raw Tomahawk projection: an absent persisted
-- pool key normalizes to zero in CharacterAmmunitionAPI.ReadSnapshot. Keep this
-- raw projection visible; do not write a zero merely to change audit formatting.
-- Do not UPDATE receipts or balances to make the results match expectations.
SELECT character_id, revision,
       JSON_EXTRACT(pools, '$.ammo_tomahawk_regular') AS tomahawk,
       JSON_EXTRACT(pools, '$.ammo_repeater_regular') AS repeater,
       pools
FROM feather_character_ammunition
WHERE character_id IN (
  '4560a489-ca6c-11f1-9ad4-e0d55eaa2deb',
  '6a2fd060-c46f-11f1-9ae2-e0d55eaa2deb'
);

-- Historical allowances do not carry into a new session. Claimed rows should
-- remain claimed; this query does not authenticate a landed projectile's origin.
-- For the two accepted pickups, expect spend:165:13 -> claimed revision14 and
-- spend:165:15 -> claimed revision16. Additional historical rows may exist.
SELECT source_resource, grant_id,
       JSON_UNQUOTE(JSON_EXTRACT(result_json, '$.phase')) AS phase,
       JSON_UNQUOTE(JSON_EXTRACT(result_json, '$.candidate.identity.sessionId')) AS session_id,
       JSON_UNQUOTE(JSON_EXTRACT(result_json, '$.candidate.identity.epoch')) AS epoch,
       JSON_EXTRACT(result_json, '$.candidate.itemId') AS item_id,
       JSON_EXTRACT(result_json, '$.claimResult.revision') AS claimed_revision,
       JSON_EXTRACT(result_json, '$.claimResult.pools.ammo_tomahawk_regular') AS claimed_tomahawk
FROM inventory_grant_receipts
WHERE source_resource = 'native-tomahawk-native-spend-v1'
  AND JSON_UNQUOTE(JSON_EXTRACT(result_json, '$.candidate.identity.characterId'))
      = '4560a489-ca6c-11f1-9ad4-e0d55eaa2deb'
ORDER BY grant_id;
