function Build-DistributionTests {
    param(
        [string]$Database,
        [string]$Framework,
        [string]$OutputDirectory
    )

    # Tests retain normal JIT builds and All references; only the selected CLI changes.
    $buildArguments = @(
        'build', "unittests/CommandLine/CommandLine.$Database/CommandLine.$Database.csproj",
        '-c', 'Release', "-p:TargetFrameworks=$Framework", "-p:ArtifactsPath=$OutputDirectory/test-build"
    )
    dotnet @buildArguments
}

function Get-DistributionTestOutputDirectory {
    param(
        [string]$Database,
        [string]$Framework,
        [string]$OutputDirectory
    )

    return "$OutputDirectory/test-build/bin/CommandLine.$Database/release_$Framework"
}

function Get-NativeAotTestRunIdentity {
    param(
        [string]$Database,
        [string]$Framework,
        [string]$RuntimeIdentifier
    )

    $source = (git rev-parse HEAD).Trim()
    $attempt = 0
    if ($source -cnotmatch '^[a-f0-9]{40}$' -or $source -cne $env:GITHUB_SHA -or
        $env:GITHUB_RUN_ID -cnotmatch '^[1-9][0-9]*$' -or
        $env:GITHUB_RUN_ATTEMPT -cnotmatch '^[1-9][0-9]*$' -or
        ![int]::TryParse($env:GITHUB_RUN_ATTEMPT, [ref]$attempt)) {
        throw 'Prepared NativeAOT tests require the immutable Actions source, run and attempt.'
    }
    return @{
        Identity = @{
            SourceRevision = $source
            RunId = $env:GITHUB_RUN_ID
            Project = "CommandLine.$Database"
            Framework = $Framework
            RuntimeIdentifier = $RuntimeIdentifier
            Configuration = 'Release'
        }
        Attempt = $attempt
    }
}

function Get-NativeAotTestPayloadFiles {
    param([string]$Directory)

    foreach ($item in Get-ChildItem -LiteralPath $Directory -Recurse -Force) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'Prepared NativeAOT tests must not contain symbolic links.'
        }
        if (!$item.PSIsContainer) {
            [pscustomobject]@{
                Path = [IO.Path]::GetRelativePath($Directory, $item.FullName).Replace('\', '/')
                Sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
            }
        }
    }
}

function Get-NativeAotTestAssembly {
    param(
        [string]$PayloadDirectory,
        [string]$Project
    )

    foreach ($name in @("$Project.dll", "$Project.deps.json", "$Project.runtimeconfig.json", 'xunit.runner.json')) {
        if (!(Test-Path -LiteralPath (Join-Path $PayloadDirectory $name) -PathType Leaf)) {
            throw "Prepared NativeAOT tests are missing $name."
        }
    }
    return Join-Path $PayloadDirectory "$Project.dll"
}

function Write-NativeAotTestPayloadManifest {
    param(
        [string]$Directory,
        [hashtable]$Run
    )

    $payload = Join-Path $Directory 'payload'
    Get-NativeAotTestAssembly -PayloadDirectory $payload -Project $Run.Identity.Project | Out-Null
    $manifest = @{
        Schema = 1
        Identity = $Run.Identity
        Attempt = $Run.Attempt
        Files = @(Get-NativeAotTestPayloadFiles -Directory $payload | Sort-Object Path)
    }
    $manifest | ConvertTo-Json -Depth 6 |
        Set-Content -LiteralPath (Join-Path $Directory 'manifest.json') -Encoding utf8NoBOM
}

function Read-NativeAotTestPayload {
    param(
        [string]$Directory,
        [hashtable]$Run
    )

    if (!(Test-Path -LiteralPath $Directory -PathType Container)) {
        throw 'Missing prepared NativeAOT test directory.'
    }
    $entries = @(Get-ChildItem -LiteralPath $Directory -Force)
    $payload = Join-Path $Directory 'payload'
    $manifestPath = Join-Path $Directory 'manifest.json'
    if ($entries.Count -ne 2 -or $entries.Name -cnotcontains 'payload' -or
        $entries.Name -cnotcontains 'manifest.json' -or
        @($entries | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count -gt 0 -or
        !(Test-Path -LiteralPath $payload -PathType Container) -or
        !(Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw 'Expected only the prepared NativeAOT test payload and its manifest.'
    }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json -AsHashtable
    if ($manifest -isnot [System.Collections.IDictionary] -or $manifest.Schema -cne 1 -or
        $manifest.Identity -isnot [System.Collections.IDictionary] -or
        $manifest.Identity.Count -ne $Run.Identity.Count -or $manifest.Files -isnot [array]) {
        throw 'Invalid prepared NativeAOT test manifest.'
    }
    foreach ($key in $Run.Identity.Keys) {
        if ($manifest.Identity[$key] -isnot [string] -or $manifest.Identity[$key] -cne $Run.Identity[$key]) {
            throw "Prepared NativeAOT test identity mismatch for $key."
        }
    }
    # An unchanged producer from this run can be reused by a failed-job rerun.
    if ($manifest.Attempt -isnot [long] -or $manifest.Attempt -lt 1 -or $manifest.Attempt -gt $Run.Attempt) {
        throw 'Prepared NativeAOT tests have an invalid or future producer attempt.'
    }

    $recorded = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach ($file in $manifest.Files) {
        if ($file -isnot [System.Collections.IDictionary] -or $file.Path -isnot [string] -or
            $file.Sha256 -isnot [string] -or $file.Sha256 -cnotmatch '^[0-9A-F]{64}$' -or
            !$recorded.TryAdd($file.Path, $file.Sha256)) {
            throw 'Invalid prepared NativeAOT test file inventory.'
        }
    }
    $actual = @(Get-NativeAotTestPayloadFiles -Directory $payload)
    if ($actual.Count -ne $recorded.Count) {
        throw 'Prepared NativeAOT test inventory does not match its files.'
    }
    foreach ($file in $actual) {
        if (!$recorded.ContainsKey($file.Path) -or $recorded[$file.Path] -cne $file.Sha256) {
            throw "Prepared NativeAOT test integrity mismatch: $($file.Path)."
        }
    }
    return Get-NativeAotTestAssembly -PayloadDirectory $payload -Project $Run.Identity.Project
}
