# Verification and evidence

Choose the smallest boundary that can reject a plausible wrong implementation.
Use xUnit v3 assertions and the existing NSubstitute/fixture conventions.
Use the [test and artifact map](testing.md) to place shared database tests and
select the relevant library, CLI, NuGet, Docker, native, and platform checks.

- New functionality needs automated coverage of the promised behavior, including
  relevant success, boundary, and failure cases. Bug fixes need focused regression
  coverage. A build or coverage percentage alone does not establish that behavior.
- Derive expectations from the requested behavior, compatibility contract, or
  independently known examples. Label characterization of current behavior.
  Do not calculate the expected value by calling the production algorithm.
- Exercise meaningful boundaries and failures. For migration behavior, inspect
  actual SQL effects and history/error rows, including forbidden effects where
  relevant. Mock calls prove orchestration, not database semantics.
- For new functionality, identify a concrete, plausible wrong implementation of
  a core rule. Ensure the test data and assertions distinguish it from the required
  behavior. The reviewer should check this explicitly and, when practical,
  demonstrate an assertion failure against that variant in an isolated copy.
  Full mutation testing is not required.
- Make regressions fail for the intended assertion against the faulty behavior
  when practical; use an isolated copy for temporary mutations. Do not confuse a
  compile/setup failure with regression sensitivity.
- Give each test its own filesystem/database state and clean up what it owns,
  including on failure. Do not add arbitrary sleeps, retries, or order dependence.
  Restore culture/environment variables if a test changes them.

## Commands from the repository root

The SDK selects Microsoft.Testing.Platform in `global.json`. Use its `--project`
syntax and xUnit's `--filter-class`; do not assume VSTest `--filter` expressions
work. These entry points match repository configuration and CI; availability of
packages, runtimes, Docker, and provider images must be checked locally.

```sh
dotnet build src/grate/grate.csproj -c Release
dotnet test --project unittests/Basic_tests --framework net10.0
dotnet test --project unittests/Sqlite --framework net10.0
```

For a focused example, substitute the actual class and require collection:

```sh
dotnet test --project unittests/Basic_tests --framework net10.0 --filter-class Basic_tests.Infrastructure.GrateEnvironment_ --minimum-expected-tests 1
```

The direct executable runner is also used by `.github/workflows/skill-installation.yml`:

```sh
dotnet build unittests/Basic_tests -c Release -p:TargetFrameworks=net10.0
dotnet unittests/Basic_tests/bin/Release/net10.0/Basic_tests.dll --filter-class Basic_tests.Infrastructure.GrateEnvironment_ --minimum-expected-tests 1
```

Run the relevant existing suite after focused checks. Basic_tests and SQLite are
the first local checks for shared changes; provider projects such as
`dotnet test --project unittests/PostgreSQL --framework net10.0` require their
configured database/container environment. Use the affected provider and shared
contracts for SQL/transaction claims. Check other target frameworks when APIs or
conditional compilation change. Full-solution tests include broader environments;
inspect `.github/workflows/ci.yml` and `integration-tests.yml` before selecting them.

`--no-build` is appropriate only after building the same source/configuration/
framework. Record selected and executed test counts; zero cases, skips, and tests
that return early are evidence gaps. A provider capability guard can report a
green test without exercising the promised behavior.

Before excluding a test class or category, inspect what it exercises and explain
the reason and remaining gap. Names and associations with documentation or skill
assets do not establish relevance. Report explicit exclusions separately from
runner skips; a filtered pass establishes only the selected scope.

Report exact commands, source version, framework, selected scope, pass/fail/counts,
and relevant environment limits. Separate checks actually run from proposed
commands, stale artifacts, and supplied reports. For a review, lead with verified
defects (trigger, location, consequence) or say none were substantiated; distinguish
uncertain hypotheses, missing evidence, and optional preferences. No finding quota.
