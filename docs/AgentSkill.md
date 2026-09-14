---
layout: default
title: Agent skill
permalink: /agent-skill/
nav_order: 6
---

# Use grate with a coding agent

The [use-grate skill](https://github.com/grate-devs/grate/tree/main/skills/use-grate) helps coding agents author, review, execute and troubleshoot grate migrations in projects that use grate. It covers script lifecycles, ordering, applied-script immutability, provider-specific transaction behavior and recovery.

Its authoring rule is **one independently tracked DML statement or DDL operation per one-time migration file**. grate can execute SQL batches; this rule makes individual changes easier to track and recover. A procedure definition is one DDL operation even when its body contains multiple statements.

## Use the skill

Take the complete `skills/use-grate` directory from a reviewed grate tag or commit, preserving `SKILL.md`, `references`, `assets` and `scripts`. Place it in your agent client's documented skill location, or explicitly give the agent `SKILL.md` and access to the supporting files. Installation and automatic discovery depend on the client; the skill has no vendor-specific tool dependency or client metadata.

For example, ask your agent:

> Use the use-grate skill to add a table, an index and initial reference data. Inspect this project's pinned grate version and folder configuration, create ordered migrations, and verify them against a disposable database using our runner.

The skill does not upgrade grate or grant permission to deploy to a shared database. It uses existing project conventions and target authorization.

## Examples and verification

- [SQLite migration files](https://github.com/grate-devs/grate/tree/main/skills/use-grate/assets/sqlite-example/up) separate table creation, index creation and seed inserts.
- [Authoring reference](https://github.com/grate-devs/grate/blob/main/skills/use-grate/references/authoring.md) explains batch separators, parallel-branch naming, environments and tokens.
- [Transaction and recovery reference](https://github.com/grate-devs/grate/blob/main/skills/use-grate/references/operations.md) distinguishes requested transactions from effective rollback and explains preview limitations.
- [SQLite verification](https://github.com/grate-devs/grate/blob/main/skills/use-grate/references/verification.md) provides a local/CI check with the real runner and records the tested version/provider and limitations.
- [PostgreSQL verification](https://github.com/grate-devs/grate/blob/main/skills/use-grate/references/postgresql-verification.md) covers effective transaction rollback.

Verification scope is recorded with the checks. SQL examples are provider-specific; the skill does not claim validation across every database or agent client.
