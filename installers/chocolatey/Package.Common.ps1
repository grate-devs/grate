function Assert-ChocolateyPayloadIdentity {
    param(
        [string]$ProductName,
        [string]$ProductVersion,
        [ValidateSet('All', 'SQLite', 'SQLServer', 'MariaDB', 'PostgreSQL', 'Oracle')]
        [string]$Distribution,
        [string]$Version
    )

    $canonicalName = @('All', 'SQLite', 'SQLServer', 'MariaDB', 'PostgreSQL', 'Oracle') |
        Where-Object { $_ -eq $Distribution }
    $expectedName = if ($canonicalName -eq 'All') { 'grate database migration' } else { "grate ($canonicalName)" }
    if ($ProductName -cne $expectedName) {
        throw "Executable ProductName does not identify $canonicalName (expected '$expectedName')."
    }
    if (!$ProductVersion -or $ProductVersion.Split('+')[0] -cne $Version) {
        throw 'Executable ProductVersion must match the full package version, including its prerelease suffix.'
    }
}
