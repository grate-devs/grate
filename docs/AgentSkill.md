---
layout: default
title: Agent skill
permalink: /agent-skill/
nav_order: 6
has_children: true
---

# Use grate with a coding agent

The [use-grate skill](skills/use-grate/SKILL.md) helps coding agents author, review, execute and troubleshoot grate migrations in projects that use grate. It covers script lifecycles, ordering, applied-script immutability, provider-specific transaction behavior and recovery.

Its authoring rule is **one independently tracked DML statement or DDL operation per one-time migration file**. grate can execute SQL batches; this rule makes individual changes easier to track and recover. A procedure definition is one DDL operation even when its body contains multiple statements.

## Use the skill

The grate CLI bundles the complete skill: `SKILL.md`, references and example SQL.
Install that bundled version after installing or updating
grate. The commands copy files without contacting a database, downloading a
skill, or executing SQL.

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
a self-contained grate executable. The skill adds no runtime or SDK requirement.
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
home, not the host's home. The source directory `docs/skills/use-grate` can also be
copied manually from a reviewed tag/commit when using an older grate CLI.

For example, ask your agent:

> Use the use-grate skill to add a table, an index and initial reference data. Inspect this project's pinned grate version and folder configuration, create ordered migrations, and verify them against a disposable database using our runner.

The skill does not upgrade grate or grant permission to deploy to a shared database. It uses existing project conventions and target authorization.

## Examples and verification

- [SQLite migration files](skills/use-grate/assets/sqlite-example/up/index.md) separate table creation, index creation and seed inserts.
- [Authoring reference](skills/use-grate/references/authoring.md) explains batch separators, parallel-branch naming, environments and tokens.
- [Transaction and recovery reference](skills/use-grate/references/operations.md) distinguishes requested transactions from effective rollback and explains preview limitations.
- [Verification guidance](skills/use-grate/references/verification.md) explains how to check the project's actual migrations with its pinned runner, provider and test tooling.

The skill contains no executable verifier or shell/PowerShell wrappers. It does
not require an installed SDK when used with self-contained grate. SQLite examples
illustrate file layout; they do not validate a consumer project's migrations or
establish another provider's transaction behavior.

## Maintaining the skill

The published skill and its bundled contents share one source directory:
`docs/skills/use-grate`. Jekyll renders the same Markdown files that the CLI embeds;
there is no generated copy to keep in sync. Site presentation is configured in
`docs/_config.yml`; the authoring reference protects token examples with Liquid
raw tags so they stay literal on GitHub Pages as well as in the installed file.

`unittests/Sqlite/AgentSkill/MigrationExamplesTests.cs` executes the exact bundled
SQLite example SQL and checks its table, index, seed row and rerun behavior. This
validates the example assets; it does not evaluate how an agent follows the
instructions. General migration behavior is covered by the existing provider tests.

The `Skill installation` CI workflow builds a .NET tool package and a self-contained
binary, then tests local and global installation on Windows, Linux and macOS.
The tests compare every installed file against the canonical skill directory.
