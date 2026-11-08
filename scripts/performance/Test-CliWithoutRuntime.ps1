param(
    [Parameter(Mandatory)][string]$Executable,
    [Parameter(Mandatory)][string]$BuildManifest,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [string]$Image = 'mcr.microsoft.com/dotnet/runtime-deps@sha256:7fb51d25f06ab09c32cf56b35696895fdfdb0f83757a559483e61f98dd1de33c'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
. (Join-Path $PSScriptRoot 'Benchmark.Common.ps1')
$Executable = (Resolve-Path -LiteralPath $Executable).Path
$manifest = Get-Content -LiteralPath $BuildManifest -Raw | ConvertFrom-Json
$hash = (Get-FileHash -LiteralPath $Executable -Algorithm SHA256).Hash.ToLowerInvariant()
if ($hash -cne $manifest.executableSha256) {
    throw 'Executable does not match its build manifest.'
}
$architecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString().ToLowerInvariant()
if ($manifest.runtimeIdentifier -cne "linux-$architecture") {
    throw 'Use a host matching the artifact architecture.'
}
$platform = switch ($architecture) {
    'arm64' { 'linux/arm64' }
    'x64' { 'linux/amd64' }
    default { throw 'Only Linux x64 and Arm64 artifacts are supported.' }
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $OutputDirectory) {
    throw 'Use a fresh output directory.'
}
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
$fixtures = New-BenchmarkFixtures -Root "$OutputDirectory/fixtures" -SmallScriptCount 5 -LargeRowCount 50
$publishDirectory = Split-Path -Parent $Executable
$dockerArguments = @(
    'run', '--rm', '--network', 'none', '--platform', $platform,
    '--mount', "type=bind,source=$publishDirectory,target=/app,readonly",
    '--mount', "type=bind,source=$OutputDirectory,target=/work",
    '--env', 'DOTNET_BUNDLE_EXTRACT_BASE_DIR=/work/extraction',
    '--entrypoint', '/bin/sh', $Image, '-c',
    'if command -v dotnet >/dev/null 2>&1 || [ -d /usr/share/dotnet ]; then exit 90; fi; exec "$@"',
    'grate', ('/app/' + [IO.Path]::GetFileName($Executable))
)
$invocations = [Collections.Generic.List[object]]::new()

function Invoke-PackagedCli {
    param(
        [string]$Name,
        [string[]]$Arguments,
        [int]$ExpectedExitCode = 0
    )

    & docker @dockerArguments @Arguments 1> "$OutputDirectory/$Name.stdout.txt" 2> "$OutputDirectory/$Name.stderr.txt"
    $exitCode = $LASTEXITCODE
    $invocations.Add([ordered]@{
        name = $Name
        arguments = $Arguments
        exitCode = $exitCode
    })
    if ($exitCode -ne $ExpectedExitCode) {
        throw "$Name exited $exitCode; expected $ExpectedExitCode. Inspect retained stdout/stderr."
    }
}

$report = [ordered]@{
    executableSha256 = $hash
    runtimeIdentifier = $manifest.runtimeIdentifier
    image = $Image
    platform = $platform
    runtimeAbsenceCheck = 'Each invocation rejects dotnet on PATH or /usr/share/dotnet before executing the packaged binary.'
    invocations = $invocations
    complete = $false
}
try {
    Invoke-PackagedCli -Name 'help' -Arguments @('--help')
    $migrationArguments = @(
        '--databasetype=sqlite', '--connectionstring=Data Source=/work/check.db;Pooling=False',
        '--files=/work/fixtures/small', '--output=/work/migration-output', '--silent', '--version=benchmark-1'
    )
    Invoke-PackagedCli -Name 'migration' -Arguments $migrationArguments
    Assert-BenchmarkDatabase -Database "$OutputDirectory/check.db" -Fixture small -Fixtures $fixtures
    $history = Get-BenchmarkHistory "$OutputDirectory/check.db"
    Invoke-PackagedCli -Name 'rerun' -Arguments $migrationArguments
    Assert-BenchmarkDatabase -Database "$OutputDirectory/check.db" -Fixture small -Fixtures $fixtures
    Assert-BenchmarkEqual (Get-BenchmarkHistory "$OutputDirectory/check.db") $history 'Runtime-free rerun history'
    $failureArguments = @(
        '--databasetype=sqlite', '--connectionstring=Data Source=/work/failure.db;Pooling=False',
        '--files=/work/fixtures/failure', '--output=/work/failure-output', '--silent', '--version=benchmark-1'
    )
    Invoke-PackagedCli -Name 'failure' -Arguments $failureArguments -ExpectedExitCode 1
    Assert-BenchmarkDatabase -Database "$OutputDirectory/failure.db" -Fixture failure -Fixtures $fixtures
    Invoke-PackagedCli -Name 'skill' -Arguments @('skills', 'install', '--local', '--path=/work/skill')
    if (!(Test-Path -LiteralPath "$OutputDirectory/skill/.agents/skills/use-grate/SKILL.md")) {
        throw 'The packaged binary did not install its bundled skill.'
    }
    $report.complete = $true
    Write-Host 'Packaged CLI passed help, SQLite migration/rerun/failure and bundled skill checks without an installed .NET runtime.'
}
finally {
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath "$OutputDirectory/runtime-free.json" -Encoding utf8
}
