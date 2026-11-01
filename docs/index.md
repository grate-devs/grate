---
title: "Home"
nav_order: 1
---

# grate
SQL scripts migration runner 

## What is grate?

grate is a SQL scripts migration runner, using plain, old SQL for migrations. No meta-language, no code, no config,
no EF migrations. It gives you full flexibility, and full control of your migrations, and lets you use
all the fancy features of you particular database system. You are not constrained to any lowest common 
feature set of all supported databases.

### grate supports the following DMBS's

* Microsoft SQL server
* PostgreSQL
* MariaDB/MySQL
* Sqlite
* Oracle


## Prerequisites

grate is built with .NET, but is compiled as a self-contained executable, which means there are no big
prerequisites for running grate. ICU is required (e.g. libicu on Debian Linux)


## Goal

The goal of grate is to be largely backwards compatible with RoundhousE, which is an amazing tool. It is initiated by the main
maintainer of RoundhousE for the last three years, please see this issue in the RoundhousE repo for details: [https://github.com/chucknorris/roundhouse/issues/438](https://github.com/chucknorris/roundhouse/issues/438).

While early versions of grate may not support every last RoundhousE feature, those features that are implemented should work identically, or with only very small changes.  For detailed information see the [migration](MigratingFromRoundhousE.md) documentation.

## Why the name grate?

grate is short for migrate. And it's also pronounced the same way as _great_, so, there you go. 

## Documentation
* [Getting started](GettingStarted.md)
* [Getting grate](GettingGrate.md)
* [Migrating from RoundhousE](MigratingFromRoundhousE.md)
* [Configuration Options](ConfigurationOptions/index.md)
* [Environment scripts](EnvironmentScripts.md)
* [Token replacement](TokenReplacement.md)
* [Response files](ConfigurationOptions/ResponseFiles.md)
* [Agent skill](AgentSkill.md)

## Status

grate is catching up on RoundhousE features, there are a couple of features missing, they are documented in unit tests. But I've successfully replaced 
RoundhousE with grate in a 5-year-in-development folder of SQL scripts, without any issues. 

## Contributing

Head over to the [github page]({{ site.github.repository_url }}), and please see [CONTRIBUTING.md]({{ site.github.repository_url }}/blob/main/CONTRIBUTING.md)
