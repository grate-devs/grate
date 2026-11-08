$ErrorActionPreference = 'Stop'
Import-Module powershell-yaml -RequiredVersion 0.4.12 -ErrorAction Stop
$repositoryRoot = Split-Path (Split-Path $PSScriptRoot)
function Read-Workflow([string]$Name) {
    Get-Content -LiteralPath (Join-Path $repositoryRoot ".github/workflows/$Name") -Raw | ConvertFrom-Yaml
}
function Assert-Policy([bool]$Condition, [string]$Message) {
    if (!$Condition) { throw $Message }
}
function Get-ActionStep($Job, [string]$Action) {
    $Job.steps | Where-Object { $_.uses -like "$Action@*" } | Select-Object -First 1
}
