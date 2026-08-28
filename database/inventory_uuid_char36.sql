-- Feather Inventory MariaDB compatibility migration.
--
-- Run once on an existing database whose inventory.uuid column uses
-- MariaDB's native UUID datatype. Back up the database first.
-- New databases created from feather-recipe already use CHAR(36).

ALTER TABLE `inventory`
    MODIFY COLUMN `uuid` CHAR(36) NOT NULL;
