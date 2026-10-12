CREATE TABLE IF NOT EXISTS {{SchemaName}}_{{ScriptsRunErrorsTable}} (
    id INT64,
    repository_path STRING,
    version STRING,
    script_name STRING,
    text_of_script STRING,
    erroneous_part_of_script STRING,
    error_message STRING,
    entry_date TIMESTAMP,
    modified_date TIMESTAMP,
    entered_by STRING
);
