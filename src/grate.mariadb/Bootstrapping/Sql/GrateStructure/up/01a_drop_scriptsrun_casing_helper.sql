-- Older installations replay changed definitions but skip their unchanged CALL/DROP scripts.
DROP PROCEDURE IF EXISTS create_{{SchemaName}}_fix_scriptsrun_table_casing;
