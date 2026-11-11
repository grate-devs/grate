function Write-InstallerLifecycleDiagnostic {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[Exception]]$Failures,
        [switch]$Append
    )

    try {
        $json = $Value | ConvertTo-Json -Depth 8 -Compress:$Append
        if ($Append) {
            Add-Content -LiteralPath $Path -Value $json -ErrorAction Stop
        } else {
            Set-Content -LiteralPath $Path -Value $json -ErrorAction Stop
        }
    } catch {
        $Failures.Add($_.Exception)
        # A broken evidence path must never bypass native process/COM cleanup.
        try {
            [Console]::Error.WriteLine("MSI diagnostic write failed: $Path; $($_.Exception.Message)")
        } catch {
            $Failures.Add($_.Exception)
        }
    }
}

function Complete-InstallerLifecycleDiagnostics {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Snapshot,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[Exception]]$Failures
    )

    Write-InstallerLifecycleDiagnostic -Path $Path -Failures $Failures -Value @{
        Snapshot = $Snapshot
        Failures = @($Failures | ForEach-Object Message)
    }
}

function Assert-InstallerLifecycleDiagnostics {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[Exception]]$Failures
    )

    if ($Failures.Count) {
        throw [AggregateException]::new('Required MSI lifecycle diagnostic evidence could not be retained.', $Failures)
    }
}

function Assert-InstallerLifecyclePhaseOrder {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$RequiredPhases
    )

    $observations = @(Get-Content -LiteralPath $Path -ErrorAction Stop | ForEach-Object { $_ | ConvertFrom-Json })
    $next = 0
    foreach ($observation in $observations) {
        if ($next -lt $RequiredPhases.Count -and $observation.Phase -eq $RequiredPhases[$next]) {
            $next++
        }
    }
    if ($next -ne $RequiredPhases.Count -or !$observations.Count -or
        $observations[-1].Phase -ne $RequiredPhases[-1]) {
        throw "MSI lifecycle phases do not establish ordered execution and completed cleanup: $Path"
    }
}
