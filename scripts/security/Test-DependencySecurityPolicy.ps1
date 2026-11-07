param(
    [string] $RepositoryRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
)

$ErrorActionPreference = 'Stop'

function Assert-Policy([bool] $Condition, [string] $Message) {
    if (!$Condition) { throw $Message }
}

function Get-Job([string] $Workflow, [string] $Id) {
    $match = [regex]::Match($Workflow, "(?ms)^  ${Id}:\r?\n(?<body>.*?)(?=^  [\w-]+:|\z)")
    Assert-Policy $match.Success "Missing job: $Id"
    return $match.Groups['body'].Value
}

$ci = Get-Content (Join-Path $RepositoryRoot '.github/workflows/ci.yml') -Raw
$dependencies = Get-Content (Join-Path $RepositoryRoot '.github/workflows/dependency-security.yml') -Raw
foreach ($workflow in @($ci, $dependencies)) {
    Assert-Policy ($workflow -match '(?m)^  pull_request:') 'Keep PR analysis enabled.'
    Assert-Policy ($workflow -match '(?m)^  push:') 'Keep main analysis enabled.'
    Assert-Policy ($workflow -match '(?m)^  schedule:') 'Keep periodic analysis enabled.'
    Assert-Policy ($workflow -notmatch '(?m)^  pull_request_target:|^    paths(-ignore)?:') 'Do not filter or privilege security PR checks.'
}

$analysis = Get-Job $ci 'analyze'
Assert-Policy ($analysis -match 'name: Analyze Code Security') 'Preserve the CodeQL check name.'
Assert-Policy ($analysis -match 'runs-on: windows-latest') 'Extract the Windows MSI code on Windows.'
Assert-Policy ($analysis -notmatch '(?m)^    if:|continue-on-error:|languages:') 'Keep analysis unconditional and language autodetection enabled.'
$init = $analysis.IndexOf('github/codeql-action/init@')
$autobuild = $analysis.IndexOf('github/codeql-action/autobuild@')
$native = $analysis.IndexOf('./installers/msi/native/Build-UpgradeActions.ps1 -Architecture x64')
$analyze = $analysis.IndexOf('github/codeql-action/analyze@')
Assert-Policy ($init -ge 0 -and $autobuild -gt $init -and $native -gt $init -and $analyze -gt $autobuild -and $analyze -gt $native) 'Trace C# and real native compilation between CodeQL init and analyze.'
foreach ($job in @('build-code', 'test', 'packages', 'standalone', 'docker', 'report')) {
    $body = Get-Job $ci $job
    Assert-Policy ($body -match "if: .*github.event_name == 'pull_request'.*github.event_name == 'workflow_dispatch'") "Do not run $job on main pushes or scheduled security refreshes."
}
Assert-Policy ((Get-Job $ci 'report') -match 'if: always\(\) &&') 'Retain failure reporting for PR/manual tests.'

$review = Get-Job $dependencies 'dependency-review'
Assert-Policy ($review -match 'fail-on-severity: high\s') 'Reject new high/critical dependency advisories.'
Assert-Policy ($review -match 'fail-on-scopes: runtime, development, unknown') 'Include build/test and unknown dependency scopes.'
Assert-Policy ($review -match 'warn-only: false') 'Dependency Review must fail on findings.'
Assert-Policy ($dependencies -notmatch 'contents: write|pull-requests: write|continue-on-error:') 'Security checks need no write token or ignored failures.'
$audit = Get-Job $dependencies 'nuget-audit'
Assert-Policy ($audit -notmatch '(?m)^    if:') 'Audit the resolved graph on PRs, main and schedule.'
Assert-Policy ($audit -match 'global-json-file: global.json') 'Use the repository SDK for all target frameworks.'
Assert-Policy ($audit -match './scripts/security/Test-NuGetDependencies.ps1') 'Run the same audit locally and in CI.'

# Exercise the command contract and failure propagation without contacting feeds.
$global:GrateAuditTestState = @{ Arguments = @(); ExitCode = 0 }
function dotnet {
    $global:GrateAuditTestState.Arguments = $args
    $global:LASTEXITCODE = $global:GrateAuditTestState.ExitCode
}
try {
    $auditScript = Join-Path $RepositoryRoot 'scripts/security/Test-NuGetDependencies.ps1'
    & $auditScript -Project 'fixture.csproj'
    foreach ($expected in @('restore', 'fixture.csproj', '--configfile', '--force-evaluate', '-p:NuGetAudit=true', '-p:NuGetAuditMode=all', '-p:NuGetAuditLevel=low', '-p:TreatWarningsAsErrors=true', '-p:WarningsNotAsErrors=NU1901%3BNU1902')) {
        Assert-Policy ($expected -in $global:GrateAuditTestState.Arguments) "Missing audit argument: $expected"
    }
    foreach ($exitCode in @(1, 42)) {
        $global:GrateAuditTestState.ExitCode = $exitCode
        $rejected = $false
        try { & $auditScript -Project 'fixture.csproj' } catch { $rejected = $_ -match 'NuGet dependency audit failed' }
        Assert-Policy $rejected "Propagate failed restore/feed audit exit code $exitCode."
    }
} finally {
    Remove-Item Function:dotnet
    Remove-Variable GrateAuditTestState -Scope Global
    $global:LASTEXITCODE = 0
}

[xml] $config = Get-Content (Join-Path $RepositoryRoot 'scripts/security/nuget.config') -Raw
Assert-Policy ($config.configuration.auditSources.add.value -eq 'https://data.nuget.org/v3/index.json') 'Use an explicit vulnerability feed so missing data is not silently ignored.'
Write-Host 'Dependency security policy and audit command checks passed.'
