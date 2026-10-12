-- the provider gives each row an id one above the highest, as BigQuery has no identity columns
CREATE TABLE IF NOT EXISTS {{SchemaName}}_{{ScriptsRunTable}} (
    id INT64,
    version_id INT64,
    script_name STRING,
    text_of_script STRING,
    text_hash STRING,
    one_time_script BOOL,
    entry_date TIMESTAMP,
    modified_date TIMESTAMP,
    entered_by STRING
);
