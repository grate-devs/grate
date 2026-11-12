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
  stored as written, though, so qualify the tables a view reads: `{% raw %}{{DatabaseName}}{% endraw %}.my_table`.
  Scripts in `dropDatabase`, `createDatabase` and `alterDatabase` are the exception: they can run before the dataset
  exists, so they have no default dataset, and every table in them needs its dataset.
* **Rate limits.** A table takes 5 metadata changes per 10 seconds. DDL counts toward that limit; DML, such as grate's
  writes to its own tables, does not - it has [limits of its own](https://docs.cloud.google.com/bigquery/docs/troubleshoot-quotas).
  Prefer one `ALTER TABLE` per table per script, listing every new column.
* **A failed script is not run again.** grate sends each script with a request id of its own. A request that fails on
  its way, or that BigQuery refuses for now (`rateLimitExceeded`, `backendError`), is sent again with a back-off, under
  the same id - BigQuery runs a request id once, so the script never runs twice. A script that BigQuery ran and that
  failed is not run again, as the statements before the failure have run: fix the cause, and run grate again.
* **Timeouts.** `--commandtimeout` (and `--admincommandtimeout` for the admin scripts) limits how long grate waits for a
  job; 0 waits without a limit. When the time is up, grate asks BigQuery to cancel the job and fails, naming the job.
  Cancelling is best effort, so the job may still finish: check it in BigQuery before you run grate again.
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
