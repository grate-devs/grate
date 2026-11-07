param(
    [string] $Project = (Join-Path $PSScriptRoot '../../grate.sln')
)

$ErrorActionPreference = 'Stop'

# Restore evaluates central versions, conditional TFMs and every transitive package.
# Keep low/moderate findings visible; high/critical and unavailable audit data fail.
$restoreArgs = @(
    'restore', $Project,
    '--configfile', (Join-Path $PSScriptRoot 'nuget.config'),
    '--force-evaluate',
    '-p:NuGetAudit=true',
    '-p:NuGetAuditMode=all',
    '-p:NuGetAuditLevel=low',
    '-p:TreatWarningsAsErrors=true',
    '-p:WarningsNotAsErrors=NU1901%3BNU1902'
)
& dotnet @restoreArgs
if ($LASTEXITCODE -ne 0) {
    throw "NuGet dependency audit failed (restore exit code $LASTEXITCODE). See restore diagnostics for advisories or feed errors."
}
