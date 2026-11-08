#!/usr/bin/env pwsh
. "$PSScriptRoot/release_common.ps1"
. "$PSScriptRoot/release_test_helpers.ps1"
$repository = Split-Path (Split-Path $PSScriptRoot)
$allowed = @('examples/docker/my-entrypoint.sh','examples/k8s/multitenancy/script/migrate.sh','installers/docker/entrypoint.sh')
Invoke-Test 'only the three documented runtime launchers remain as shell files' {
    $paths = & git -C $repository ls-files --cached --others --exclude-standard -- '*.sh'
    if ($LASTEXITCODE -ne 0) { throw 'Could not enumerate repository shell files.' }
    $present = @($paths | Where-Object { Test-Path -LiteralPath "$repository/$_" -PathType Leaf } | Sort-Object -Unique)
    Assert-Equal $allowed $present
    $guidance = Get-Content -LiteralPath "$repository/AGENTS.md" -Raw
    foreach ($path in $allowed) { Assert-True ($guidance.Contains($path)) "Document runtime exception: $path" }
}
Write-Host "PASS: $script:TestCount repository shell-policy check."
