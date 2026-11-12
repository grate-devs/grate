---
title: "Everytime Scripts"
permalink: script-types/everytime/
parent: Script types
---
# Everytime Scripts
Everytime scripts are scripts that are run everytime grate runs, regardless of changes.  

If you name your file with `.EVERYTIME.`, grate will run that file everytime, regardless of changes.  For example, if you name a file **Something.EVERYTIME.sql** or **EVERYTIME.something.sql**, grate will run that file on each migration. 

## Why would I use this?
This is handy when you are using a script to drop and insert data or you need certain scripts to run everytime (say they do some sort of autowiring).

## Folders
The following migration folders use the `EveryTime` type by default and accept ordinary `.sql` filenames.

* `beforeMigration`
* `permissions`
* `afterMigration`


## Where not to use
* The `up` folder - This folder is meant for scripts that run only once and it can be confusing to have everytime scripts in here.  That said it will work just fine, so you do you...
 

