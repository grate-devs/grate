# C# formatting

Use the stable .NET 11 SDK selected by the repository's `global.json`.
From the repository root, check changed C# files with:

```powershell
pwsh -NoProfile -File scripts/format/Check-ChangedCSharp.ps1
```

The default base is `origin/main`; fetch it first. `-BaseRef <commit-or-branch>`
uses the merge base with `HEAD` and checks the current working tree. This includes
committed, staged, unstaged and untracked changes under `src/` and `unittests/`,
including renamed files. Deleted and ignored files are excluded. A missing base
fails the check. No changed C# files is a successful no-op.

The `CI · C# formatting` workflow calls this same script for pull requests and pushes
to `main`, using the PR base commit or previous push commit. Manual runs use
`-All`. Changes to `.editorconfig` or `global.json` also check all tracked C# files.
The workflow always starts, including for documentation changes; it is not yet a
required branch-protection check.

The command is deliberately limited to `dotnet format whitespace --folder`:
indentation, spacing, line breaks and the existing EditorConfig encoding rule.
It does not apply analyzer suggestions, reorder usings, rename symbols, or add
braces. Existing style preferences with `silent`/`suggestion` severity retain
their current meaning. C# sources use four-space indentation and UTF-8 **with
BOM**, as already required by `.editorconfig` and used by most existing files.
This rule applies to C# source, not SQL migration fixtures or persisted script
identity. Keep encoding-policy changes separate from mechanical formatting.

To fix selected files reported by the check:

```powershell
dotnet format whitespace --folder --include src/path/File.cs unittests/path/Test.cs
```

To verify the complete source and test scope:

```powershell
pwsh -NoProfile -File scripts/format/Check-ChangedCSharp.ps1 -All
```

The real-formatter integration checks use a disposable Git repository and cover
clean, staged, unstaged, untracked, deleted and renamed files, existing debt,
configuration changes and an unavailable base:

```powershell
pwsh -NoProfile -File scripts/format/Test-ChangedCSharp.ps1
```
