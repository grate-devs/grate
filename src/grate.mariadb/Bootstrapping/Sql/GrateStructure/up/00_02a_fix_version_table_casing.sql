-- Replace helpers left by an interrupted bootstrap or changed internal script.
DROP PROCEDURE IF EXISTS create_{{SchemaName}}_fix_version_table_casing;
CREATE PROCEDURE create_{{SchemaName}}_fix_version_table_casing()
BEGIN
    DECLARE CONTINUE HANDLER FOR 1060 BEGIN END;
    -- A case-only rename refers to the same table when names are case-insensitive.
    IF @@lower_case_table_names = 0 AND EXISTS (SELECT 1
      FROM INFORMATION_SCHEMA.TABLES
      WHERE table_schema = DATABASE()
            AND BINARY `table_name` = BINARY '{{SchemaName}}_{{VersionTableLowerCase}}' -- exists in db
    )
    THEN
        -- we need to make sure the target table is not existing, otherwise, mariadb will throw an error like table already exists
        IF NOT EXISTS (SELECT 1
            FROM INFORMATION_SCHEMA.COLUMNS
            WHERE table_schema = DATABASE()
                AND BINARY `table_name` = BINARY '{{SchemaName}}_{{VersionTable}}'
        )
        THEN
            RENAME TABLE `{{SchemaName}}_{{VersionTableLowerCase}}` TO `{{SchemaName}}_{{VersionTable}}`;
        END IF;
    END IF;
END;
