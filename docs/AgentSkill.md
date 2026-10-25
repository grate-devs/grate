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

The grate CLI bundles the complete skill: `SKILL.md`, references, example SQL and
verification scripts. Install that bundled version after installing or updating
grate. The commands copy files without contacting a database, downloading a
skill, or running its verifier.

For a project-local .NET tool, run this from the project repository after
`dotnet tool install` or `dotnet tool restore`:

```sh
dotnet tool run grate -- skills install --local
```

For Homebrew, winget, MSI, Chocolatey, Debian packages, global .NET tools and
extracted self-contained binaries:

```sh
grate skills install --global
```

A global executable can also install into a single project with `--local`.
Select an explicit project directory with `grate skills install --local --path
/path/to/project`. Without `--path`, local installation finds the nearest parent
containing a `.git` directory or worktree pointer file; outside a repository it
uses the current directory. Global installation always uses the current user's
home directory. Run it as that user, without `sudo` or an elevated installer.

| Scope | Codex / agents | Claude Code |
| --- | --- | --- |
| `--local` | `<project>/.agents/skills/use-grate` | `<project>/.claude/skills/use-grate` |
| `--global` | `~/.agents/skills/use-grate` | `~/.claude/skills/use-grate` |

These are the documented [Codex skill locations](https://learn.chatgpt.com/docs/customization/overview)
and [Claude Code skill locations](https://code.claude.com/docs/en/skills).
Commit the local copies if the team should share them. Agent discovery depends
on the client; the skill itself has no vendor-specific tool dependency or metadata.

Installation is explicit: package managers and `dotnet tool install` do not run
this command automatically, and normal grate migrations do not install skills.
Both `--local` and `--global` require no additional .NET installation when using
a self-contained grate executable. Only the optional C# verifier needs an SDK.
The bundle is included in newly built releases; older installed versions of
grate do not acquire this command automatically.

An identical installed skill is left untouched. A differing `use-grate` directory
causes installation to fail before either client copy is modified. Back up local
edits before using `grate skills install --global --force` (or `--local --force`):
this replaces each entire `use-grate` directory, including extra files, with the
current executable's bundle. Other skills are preserved. Installation refuses
symbolic links/reparse points within the agent directory paths and skill trees.
To update the skill after upgrading grate, rerun the install command with
`--force` after reviewing any local changes. To uninstall it, remove the two
`use-grate` directories; uninstalling the CLI does not remove these user files.

For Docker, bind-mount the intended project and override the migration entrypoint
so no database options or secrets are required. Use your project's pinned image:

```sh
docker run --rm --entrypoint /app/grate \
  -v "$PWD:/workspace" erikbra/grate:<version> \
  skills install --local --path /workspace
```

Container execution writes as the container's user; set `--user` as appropriate
for your host's permissions. Global installation inside a container affects its
home, not the host's home. The source directory `skills/use-grate` can also be
copied manually from a reviewed tag/commit when using an older grate CLI.

For example, ask your agent:

> Use the use-grate skill to add a table, an index and initial reference data. Inspect this project's pinned grate version and folder configuration, create ordered migrations, and verify them against a disposable database using our runner.

The skill does not upgrade grate or grant permission to deploy to a shared database. It uses existing project conventions and target authorization.

## Examples and verification

- [SQLite migration files](https://github.com/grate-devs/grate/tree/main/skills/use-grate/assets/sqlite-example/up) separate table creation, index creation and seed inserts.
- [Authoring reference](https://github.com/grate-devs/grate/blob/main/skills/use-grate/references/authoring.md) explains batch separators, parallel-branch naming, environments and tokens.
- [Transaction and recovery reference](https://github.com/grate-devs/grate/blob/main/skills/use-grate/references/operations.md) distinguishes requested transactions from effective rollback and explains preview limitations.
- [SQLite verification](https://github.com/grate-devs/grate/blob/main/skills/use-grate/references/verification.md) provides a local/CI check with the real runner and records the tested version/provider and limitations.
- [PostgreSQL verification](https://github.com/grate-devs/grate/blob/main/skills/use-grate/references/postgresql-verification.md) covers effective transaction rollback.

The optional SQLite verifier is a file-based C# app requiring .NET SDK 10 or newer. Shell and PowerShell wrappers report a skipped check (exit 77) when a suitable SDK is unavailable. The skill itself and self-contained grate distributions do not require .NET to be installed.

Verification scope is recorded with the checks. SQL examples are provider-specific; the skill does not claim validation across every database or agent client.
