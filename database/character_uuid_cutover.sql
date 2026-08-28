-- Feather Inventory canonical Character UUID cutover.
-- Run once against an existing development database before setting
-- Config.CharacterIdentity.mode = 'uuid'. Back up first. A clean rebuild
-- from feather-recipe/database/migration.sql is preferred when possible.

SET FOREIGN_KEY_CHECKS = 0;

-- Replace MariaDB's newer native UUID datatype/default with the portable
-- representation used throughout Feather. New identifiers are supplied
-- explicitly by feather-inventory.
ALTER TABLE `inventory`
    MODIFY COLUMN `uuid` CHAR(36) NOT NULL;

-- Legacy releases used more than one constraint-name convention. Discover
-- every foreign key into characters instead of assuming a particular name.
-- SELECT 1 makes each block a safe no-op when no matching key exists.
SET @drop_inventory_character_fks = (
    SELECT IF(
        COUNT(*) = 0,
        'SELECT 1',
        CONCAT(
            'ALTER TABLE `inventory` ',
            GROUP_CONCAT(
                CONCAT('DROP FOREIGN KEY `', REPLACE(`CONSTRAINT_NAME`, '`', '``'), '`')
                SEPARATOR ', '
            )
        )
    )
    FROM `information_schema`.`KEY_COLUMN_USAGE`
    WHERE `CONSTRAINT_SCHEMA` = DATABASE()
      AND `TABLE_NAME` = 'inventory'
      AND `REFERENCED_TABLE_NAME` = 'characters'
);
PREPARE drop_inventory_character_fks FROM @drop_inventory_character_fks;
EXECUTE drop_inventory_character_fks;
DEALLOCATE PREPARE drop_inventory_character_fks;

ALTER TABLE `inventory`
    MODIFY COLUMN `character_id` CHAR(36) NULL,
    MODIFY COLUMN `owner_character_id` CHAR(36) NULL;

SET @drop_access_character_fks = (
    SELECT IF(
        COUNT(*) = 0,
        'SELECT 1',
        CONCAT(
            'ALTER TABLE `inventory_access` ',
            GROUP_CONCAT(
                CONCAT('DROP FOREIGN KEY `', REPLACE(`CONSTRAINT_NAME`, '`', '``'), '`')
                SEPARATOR ', '
            )
        )
    )
    FROM `information_schema`.`KEY_COLUMN_USAGE`
    WHERE `CONSTRAINT_SCHEMA` = DATABASE()
      AND `TABLE_NAME` = 'inventory_access'
      AND `REFERENCED_TABLE_NAME` = 'characters'
);
PREPARE drop_access_character_fks FROM @drop_access_character_fks;
EXECUTE drop_access_character_fks;
DEALLOCATE PREPARE drop_access_character_fks;

ALTER TABLE `inventory_access`
    MODIFY COLUMN `character_id` CHAR(36) NOT NULL,
    MODIFY COLUMN `granted_by_character_id` CHAR(36) NULL;

SET @drop_equipment_character_fks = (
    SELECT IF(
        COUNT(*) = 0,
        'SELECT 1',
        CONCAT(
            'ALTER TABLE `character_equipment` ',
            GROUP_CONCAT(
                CONCAT('DROP FOREIGN KEY `', REPLACE(`CONSTRAINT_NAME`, '`', '``'), '`')
                SEPARATOR ', '
            )
        )
    )
    FROM `information_schema`.`KEY_COLUMN_USAGE`
    WHERE `CONSTRAINT_SCHEMA` = DATABASE()
      AND `TABLE_NAME` = 'character_equipment'
      AND `REFERENCED_TABLE_NAME` = 'characters'
);
PREPARE drop_equipment_character_fks FROM @drop_equipment_character_fks;
EXECUTE drop_equipment_character_fks;
DEALLOCATE PREPARE drop_equipment_character_fks;

ALTER TABLE `character_equipment`
    MODIFY COLUMN `character_id` CHAR(36) NOT NULL;

SET FOREIGN_KEY_CHECKS = 1;

-- Numeric rows are temporary bridge data. They are not converted into UUID
-- ownership. Remove them when enabling the UUID-only Character flow:
-- DELETE FROM `inventory` WHERE `character_id` IS NOT NULL AND `character_id` NOT REGEXP
--   '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$';
