function Assert-DistributionDependencies {
    param(
        [hashtable]$Dependencies,
        [string]$Distribution
    )

    $providers = @{
        SQLite = @('grate.sqlite', 'Microsoft.Data.Sqlite', 'SQLitePCLRaw.lib.e_sqlite3')
        SQLServer = @('grate.sqlserver', 'Microsoft.Data.SqlClient')
        MariaDB = @('grate.mariadb', 'MySqlConnector')
        PostgreSQL = @('grate.postgresql', 'Npgsql')
        Oracle = @('grate.oracle', 'Oracle.ManagedDataAccess.Core')
    }
    foreach ($provider in $providers.Keys) {
        foreach ($dependency in $providers[$provider]) {
            $present = @($Dependencies.libraries.Keys | Where-Object { $_.StartsWith("$dependency/", [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
            $expected = $Distribution -eq 'All' -or $Distribution -eq $provider
            if ($present -ne $expected) {
                throw "$Distribution dependency mismatch for $dependency (present=$present, expected=$expected)."
            }
        }
    }
}

function Assert-DistributionExecutable {
    param(
        [string]$Executable,
        [string]$Distribution
    )

    $help = & $Executable --help | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "$Executable --help failed."
    }
    if ($Distribution -eq 'All') {
        return
    }
    if (!$help.Contains("This build supports $Distribution only.")) {
        throw "$Executable is not the expected $Distribution CLI."
    }
    # Reject an accidental All apphost or shim before trying a connection.
    $otherProvider = if ($Distribution -eq 'SQLite') { 'postgresql' } else { 'sqlite' }
    $savedNativePreference = $PSNativeCommandUseErrorActionPreference
    try {
        $PSNativeCommandUseErrorActionPreference = $false
        $rejection = & $Executable --databasetype $otherProvider --connectionstring invalid --silent 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0 -or !$rejection.Contains("This build supports $Distribution only.")) {
            throw "$Executable did not reject $otherProvider as an unsupported provider."
        }
    } finally {
        $PSNativeCommandUseErrorActionPreference = $savedNativePreference
    }
}
