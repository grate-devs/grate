---
title: "Release workflow verification, 2 November 2026"
nav_exclude: true
---

# Release workflow verification, 2 November 2026

This is historical implementation evidence for the commits named below. It is
not test or publication evidence for a later release candidate. Follow the
[current maintainer runbook](../ReleaseProcess.md) and collect evidence for the
version being released.


[Integrated release build 41410654110](https://github.com/grate-devs/grate/actions/runs/41410654110)
passed at `c8500c18116053a5c78be7a962564d584920069e`: 24 jobs passed, including
both actual MSI builds/metadata checks and the 13-file release contract. The
application test job was intentionally skipped for this PR build; it is not
fresh application/database test evidence. All four publication jobs and the
post-publication WinGet preparation job were skipped.

[Windows preparation 41410654163](https://github.com/grate-devs/grate/actions/runs/41410654163)
passed historical release inspection, helper checks and native action compilation
for both architectures.

[Focused native MSI policy 41411152047](https://github.com/grate-devs/grate/actions/runs/41411152047)
passed on x64 and ARM64, including actual full-version MSI metadata, three
same-core refusals before removal, explicit uninstall/reinstall, higher-core
upgrades and cleanup. This uses small probe apphosts to test installer policy;
the prior full Grate/WinGet lifecycle evidence remains linked in the migration
guide. Production MSI source is `c83a275`; the successful rerun includes the
`20ca2dd` test-only Windows path fix (integrated as `00a26b0`).

These runs published no Grate release, image or upstream manifest. Schema and
installation checks using the final published candidate and the accepted public
new ID remain #800 follow-up work.
