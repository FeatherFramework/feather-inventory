-- Inventory-owned startup schema. Creates empty tables only; never enrolls or credits a character.
CREATE TABLE IF NOT EXISTS feather_character_ammunition (
    character_id CHAR(36) NOT NULL,
    revision BIGINT UNSIGNED NOT NULL DEFAULT 0,
    pools LONGTEXT NOT NULL,
    migrated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (character_id)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS feather_ammunition_operations (
    character_id CHAR(36) NOT NULL,
    operation_id VARCHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
    result LONGTEXT NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (character_id, operation_id)
) ENGINE=InnoDB;
