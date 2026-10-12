---
title: "Google BigQuery"
permalink: /bigquery/
---
# Google BigQuery

grate migrates a BigQuery **dataset**: in BigQuery terms, the dataset is grate's database.

```sh
grate --databasetype=bigquery \
      --connectionstring="ProjectId=my-project;Dataset=my_dataset;Location=EU" \
      --sqlfilesdirectory=./db
```

## The connection string

BigQuery has no connections - every statement grate runs is a BigQuery job - so the connection string only says where
the jobs run:

| Key | Required | What it is |
|--|--|--|
| `ProjectId` | yes | The Google Cloud project that holds the dataset, and runs (and pays for) the jobs |
| `Dataset` | yes | The dataset to migrate - grate's "database" |
| `Location` | no | The dataset's location, e.g. `EU` or `europe-west2` - used when grate creates the dataset |
| `Endpoint` | no | The address of a BigQuery emulator, e.g. `http://localhost:9050` - no credentials are used then |

grate uses [Application Default Credentials](https://cloud.google.com/docs/authentication/application-default-credentials):
`gcloud auth application-default login` on a developer machine, `GOOGLE_APPLICATION_CREDENTIALS`, or the service
account of the workload (e.g. Workload Identity on GKE).

The credentials need to run query jobs in the project (e.g. `roles/bigquery.jobUser`) and to change the dataset's
tables and views (e.g. `roles/bigquery.dataEditor` on the dataset). To let grate create the dataset when it does not
exist, they also need `bigquery.datasets.create` on the project. If you create your datasets yourself, run grate with
`--createdatabase=false`.

## grate's own tables

A dataset holds tables, but no schemas, so grate keeps its tables in the dataset it migrates, named
`{schema}_{table}`: `grate_ScriptsRun`, `grate_ScriptsRunErrors` and `grate_Version` by default. `--schema` changes the
prefix. BigQuery has no identity columns, so grate gives each row the next `id` itself; run one migration against a
dataset at a time.

## Writing scripts for BigQuery

* **No transactions.** BigQuery runs no DDL in a transaction, so `--transaction` is not supported, and nothing is
  rolled back when a script fails.
* **A script runs whole, as one multi-statement job.** If a statement fails, the statements before it in the same
  script stay done. Write every statement so that it is safe to run again: `CREATE TABLE IF NOT EXISTS`,
  `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`, `CREATE OR REPLACE VIEW`.
* **Unqualified table names resolve to the migrated dataset**, as it is the jobs' default dataset. A view body is
  stored as written, though, so qualify the tables a view reads: `{{DatabaseName}}.my_table`.
* **Rate limits.** A table takes 5 metadata changes (DDL, and DML on grate's tables) per 10 seconds. grate tries a job
  again, with a back-off, when BigQuery answers `rateLimitExceeded` or `backendError`, but prefer one `ALTER TABLE` per
  table per script, listing every new column.
* **Not supported:** `--restore`, and the database user and permission scripts that some other databases use.

## Trying it locally

The [BigQuery emulator](https://github.com/goccy/bigquery-emulator) serves BigQuery's API for one project, without
credentials:

```sh
docker run -d -p 9050:9050 ghcr.io/goccy/bigquery-emulator:0.8.1 --project=my-project
grate --databasetype=bigquery \
      --connectionstring="ProjectId=my-project;Dataset=my_dataset;Endpoint=http://localhost:9050" \
      --sqlfilesdirectory=./db
```

The emulator is not BigQuery: error messages differ, and some features are missing. It also slows down, and
eventually fails, as it runs more jobs and drops more tables, so restart it now and then. Check your migrations against
a real dataset before you rely on them.
