function Assert-MsiPayloadIdentity {
    param(
        [string]$ProductVersion,
        [string]$ProductName,
        [Parameter(Mandatory)]
        [object]$Identity
    )

    if (!$ProductVersion -or $ProductVersion.Split('+')[0] -cne $Identity.ReleaseVersion) {
        throw 'The executable ProductVersion must match ReleaseVersion (excluding +build metadata). Pass the full prerelease version explicitly; never package it as its stable core.'
    }
    $expectedName = if ($Identity.Distribution -eq 'All') {
        'grate database migration'
    } else {
        $Identity.ProductName
    }
    if ($ProductName -cne $expectedName) {
        throw "The executable ProductName must match the $($Identity.Distribution) distribution: expected '$expectedName', found '$ProductName'."
    }
}
