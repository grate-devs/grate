# Distribution identities shared by release artifact producers and validators.
function Assert-GrateSourceTag {
    param(
        [string]$Tag,
        [string]$SourceCommit
    )

    if ($Tag -cnotmatch '\Av?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\z' -or
        $SourceCommit -cnotmatch '\A[a-f0-9]{40}\z') {
        throw 'A stable release tag and immutable source SHA are required.'
    }
    $references = @(git ls-remote --tags origin "refs/tags/$Tag" "refs/tags/$Tag^{}")
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not verify the source archive tag.'
    }
    $peeled = @($references | Where-Object { $_.EndsWith("refs/tags/$Tag^{}", [StringComparison]::Ordinal) })
    $target = @(if ($peeled.Count -eq 1) {
        $peeled
    } else {
        $references
    })
    if ($target.Count -ne 1 -or ($target[0] -split '\s+')[0] -cne $SourceCommit) {
        throw 'The source archive tag does not identify the verified release commit.'
    }
}

function Get-GrateDistribution {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('All', 'SQLite', 'SQLServer', 'MariaDB', 'PostgreSQL', 'Oracle')]
        [string]$Name
    )

    $packageId = if ($Name -eq 'All') {
        'grate'
    } else {
        'grate-' + $Name.ToLowerInvariant()
    }
    [pscustomobject]@{
        Name = $Name
        PackageId = $packageId
    }
}

function Get-GrateReleaseAssets {
    param(
        [Parameter(Mandatory)]
        [string]$Version
    )

    foreach ($name in @('All', 'SQLite', 'SQLServer', 'MariaDB', 'PostgreSQL', 'Oracle')) {
        $profile = Get-GrateDistribution -Name $name
        foreach ($rid in @('win-x64', 'win-x86', 'win-arm64', 'linux-musl-x64', 'linux-musl-arm64', 'linux-x64', 'linux-arm64', 'osx-x64', 'osx-arm64')) {
            "$($profile.PackageId)-$rid-self-contained-$Version.zip"
        }
        foreach ($architecture in @('amd64', 'arm64')) {
            "$($profile.PackageId)_${Version}_${architecture}.deb"
        }
        foreach ($architecture in @('x64', 'arm64')) {
            "$($profile.PackageId)-msi-win-$architecture-$Version.msi"
        }
    }
}

function Write-GrateReleaseManifest {
    param(
        [Parameter(Mandatory)]
        [string]$Directory,
        [Parameter(Mandatory)]
        [string]$Version,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Tag,
        [Parameter(Mandatory)]
        [string]$Repository
    )

    $expected = @(Get-GrateReleaseAssets -Version $Version | Sort-Object -CaseSensitive)
    $actual = @(Get-ChildItem -LiteralPath $Directory -File | Select-Object -ExpandProperty Name | Sort-Object -CaseSensitive)
    if ($actual.Count -ne $expected.Count -or @(Compare-Object -ReferenceObject $expected -DifferenceObject $actual -CaseSensitive).Count -ne 0) {
        throw "Release asset inventory differs from the expected $($expected.Count) files."
    }
    $assets = @(foreach ($name in $expected) {
        $path = Join-Path $Directory $name
        [ordered]@{
            name = $name
            sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
            size = (Get-Item -LiteralPath $path).Length
        }
    })
    $checksums = @($assets | ForEach-Object { "$($_.sha256)  $($_.name)" }) -join "`n"
    Set-Content -LiteralPath (Join-Path $Directory 'checksums.sha256') -Value ($checksums + "`n") -NoNewline -Encoding utf8NoBOM
    $manifest = [ordered]@{
        repository = $Repository
        tag = $Tag
        version = $Version
        assets = $assets
    }
    $json = $manifest | ConvertTo-Json -Depth 8
    Set-Content -LiteralPath (Join-Path $Directory 'release-manifest.json') -Value ($json + "`n") -NoNewline -Encoding utf8NoBOM
}

function Get-GrateReleaseNugetPackages {
    param(
        [Parameter(Mandatory)]
        [string]$Directory,
        [Parameter(Mandatory)]
        [string]$Version
    )

    $expectedIds = @(
        'grate', 'grate-sqlite', 'grate-sqlserver', 'grate-mariadb', 'grate-postgresql', 'grate-oracle',
        'grate.core', 'grate.sqlite', 'grate.sqlserver', 'grate.mariadb', 'grate.postgresql', 'grate.oracle'
    )
    $packages = @(Get-ChildItem -LiteralPath $Directory -Filter '*.nupkg' -File -Recurse | Sort-Object FullName)
    if ($packages.Count -ne $expectedIds.Count) {
        throw "Expected exactly $($expectedIds.Count) NuGet packages, found $($packages.Count)."
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($package in $packages) {
        $archive = [IO.Compression.ZipFile]::OpenRead($package.FullName)
        try {
            $metadata = @($archive.Entries | Where-Object { $_.FullName.EndsWith('.nuspec', [StringComparison]::Ordinal) })
            if ($metadata.Count -ne 1) {
                throw "Expected one nuspec in $($package.Name)."
            }
            $reader = [IO.StreamReader]::new($metadata[0].Open())
            try {
                [xml]$nuspec = $reader.ReadToEnd()
            } finally {
                $reader.Dispose()
            }
            $id = [string]$nuspec.package.metadata.id
            if ($id -cnotin $expectedIds -or !$seen.Add($id)) {
                throw "Unexpected or duplicate NuGet package ID '$id'."
            }
            if ([string]$nuspec.package.metadata.version -cne $Version) {
                throw "Unexpected version in NuGet package '$id'."
            }
        } finally {
            $archive.Dispose()
        }
    }
    # Return candidates only after the entire set passes; callers may now publish.
    $packages.FullName
}
