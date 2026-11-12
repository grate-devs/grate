---
title: "Anytime Scripts"
permalink: script-types/anytime/
parent: Script types
---
# Anytime Scripts

By default, grate runs anytime scripts when they are new or have changed.

## Folders
The following migration folders use the `AnyTime` type by default.

* `alterDatabase`
* `runAfterCreateDatabase`
* `runBeforeUp`
* `runFirstAfterUp`
* `functions`
* `views`
* `sprocs`
* `triggers`
* `indexes`
* `runAfterOtherAnyTimeScripts`

Grate processes `runAfterCreateDatabase` only on the run that creates the database. A dry run that previews database creation also includes this folder.

See [Default folder configuration](../ConfigurationOptions/FolderConfiguration.md#default-folder-configuration) for the full migration order and database setup behavior.

## Notes

Remember that as your script may be run multiple times, you can't just make it a `create...` script, but should use `create or alter...` instead.  If your DBMS version doesn't support `create or alter...` semantics then you can use a 'create if not exists, alter otherwise' workflow instead.

eg:
``` sql
IF NOT EXISTS (SELECT * FROM dbo.sysobjects WHERE id = OBJECT_ID('[ss].[usp_GetAllThis]'))
EXECUTE('CREATE PROC [ss].[usp_GetAllThis] AS SELECT * FROM sys.objects') -- Create a dummy placeholder object if needed

GO
-- You can then alter the proc as needed here over repeat migrations without losing permissions etc.

ALTER PROCEDURE [ss].[usp_GetAllThis] 
/* your procedure guts here */
```
