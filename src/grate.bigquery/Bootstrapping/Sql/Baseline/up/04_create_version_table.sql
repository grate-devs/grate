CREATE TABLE IF NOT EXISTS {{SchemaName}}_{{VersionTable}} (
    id INT64,
    repository_path STRING,
    version STRING,
    entry_date TIMESTAMP,
    modified_date TIMESTAMP,
    entered_by STRING,
    status STRING
);
