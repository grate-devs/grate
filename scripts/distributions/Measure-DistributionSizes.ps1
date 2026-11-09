param(
    [Parameter(Mandatory)]
    [string]$OutputDirectory,
    [ValidateSet('win-x64', 'win-x86', 'win-arm64', 'linux-x64', 'linux-arm64', 'linux-musl-x64', 'linux-musl-arm64', 'osx-x64', 'osx-arm64')]
    [string]$RuntimeIdentifier = 'linux-x64'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
. "$PSScriptRoot/../ci/Distribution.Common.ps1"
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $output) {
    throw 'Use a fresh measurement directory.'
}
$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
Push-Location $repository
try {
    $sdk = (dotnet --version).Trim()
    $expectedSdk = (Get-Content -LiteralPath global.json -Raw | ConvertFrom-Json).sdk.version
    if ($sdk -cne $expectedSdk) {
        throw "Wrong SDK: $sdk"
    }
    $source = (git rev-parse HEAD).Trim()
    $profiles = @('All', 'SQLite', 'SQLServer', 'MariaDB', 'PostgreSQL', 'Oracle')
    $frameworks = @('net8.0', 'net9.0', 'net10.0', 'net11.0')
    $measurements = [ordered]@{}
    New-Item -ItemType Directory -Path $output | Out-Null
    foreach ($profile in $profiles) {
        Write-Host "Building $profile for the size comparison"
        $work = Join-Path $output $profile.ToLowerInvariant()
        New-Item -ItemType Directory -Path $work | Out-Null
        $packageId = if ($profile -eq 'All') { 'grate' } else { 'grate-' + $profile.ToLowerInvariant() }
        $publishArguments = @(
            'publish', 'src/grate/grate.csproj', '-c', 'Release', '-f', 'net11.0', '-r', $RuntimeIdentifier,
            '--self-contained', 'true', '-p:TargetFrameworks=net11.0', '-p:Version=0.0.1',
            "-p:GrateDistribution=$profile", "-p:ArtifactsPath=$work/cli-build", '-o', "$work/published"
        )
        dotnet @publishArguments *> "$work/publish.log"
        $deps = @(Get-ChildItem -LiteralPath "$work/cli-build/bin/grate" -Filter grate.deps.json -Recurse)
        if ($deps.Count -ne 1) {
            throw 'Expected one CLI dependency manifest.'
        }
        Assert-DistributionDependencies -Distribution $profile -Dependencies (Get-Content -LiteralPath $deps[0].FullName -Raw | ConvertFrom-Json -AsHashtable)
        $archivePath = "$work/$packageId-$RuntimeIdentifier-self-contained-0.0.1.zip"
        $archive = [IO.Compression.ZipFile]::Open($archivePath, [IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($file in (Get-ChildItem -LiteralPath "$work/published" | Sort-Object Name)) {
                if ($file.PSIsContainer) {
                    throw "Unexpected publish directory: $($file.FullName)"
                }
                [IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                    $archive, $file.FullName, $file.Name, [IO.Compression.CompressionLevel]::Optimal) | Out-Null
            }
        } finally {
            $archive.Dispose()
        }
        [IO.Compression.ZipFile]::ExtractToDirectory($archivePath, "$work/extracted")
        foreach ($file in (Get-ChildItem -LiteralPath "$work/published" -File)) {
            if ((Get-FileHash -LiteralPath $file.FullName).Hash -cne
                (Get-FileHash -LiteralPath "$work/extracted/$($file.Name)").Hash) {
                throw "ZIP round-trip changed $($file.Name)."
            }
        }
        $packArguments = @(
            'pack', 'src/grate/grate.csproj', '-c', 'Release', '-p:Version=0.0.1',
            '-p:PackageVersion=0.0.1', '-p:PackAsTool=true', '-p:SelfContained=false',
            "-p:GrateDistribution=$profile", "-p:ArtifactsPath=$work/tool-build", '-o', "$work/feed"
        )
        dotnet @packArguments *> "$work/pack.log"
        $packagePath = "$work/feed/$packageId.0.0.1.nupkg"
        $package = [IO.Compression.ZipFile]::OpenRead($packagePath)
        try {
            foreach ($framework in $frameworks) {
                $prefix = "tools/$framework/any"
                foreach ($name in @('grate.dll', 'grate.deps.json', 'DotnetToolSettings.xml')) {
                    if (!$package.GetEntry("$prefix/$name")) {
                        throw "Missing $framework tool file: $name"
                    }
                }
                $reader = [IO.StreamReader]::new($package.GetEntry("$prefix/grate.deps.json").Open())
                try {
                    Assert-DistributionDependencies -Distribution $profile -Dependencies ($reader.ReadToEnd() | ConvertFrom-Json -AsHashtable)
                } finally {
                    $reader.Dispose()
                }
                $reader = [IO.StreamReader]::new($package.GetEntry("$prefix/DotnetToolSettings.xml").Open())
                try {
                    [xml]$settings = $reader.ReadToEnd()
                    if ($settings.DotNetCliTool.Commands.Command.Name -cne 'grate') {
                        throw 'Unexpected tool command.'
                    }
                } finally {
                    $reader.Dispose()
                }
            }
        } finally {
            $package.Dispose()
        }
        $executableName = if ($RuntimeIdentifier.StartsWith('win-')) { 'grate.exe' } else { 'grate' }
        $measurements[$profile] = [ordered]@{
            standalone_binary_bytes = (Get-Item -LiteralPath "$work/published/$executableName").Length
            standalone_zip_bytes = (Get-Item -LiteralPath $archivePath).Length
            tool_nupkg_bytes = (Get-Item -LiteralPath $packagePath).Length
        }
        Write-Host "$profile measurements: $($measurements[$profile] | ConvertTo-Json -Compress)"
    }
    $report = [ordered]@{
        source = $source
        sdk = $sdk
        version = '0.0.1'
        rid = $RuntimeIdentifier
        target_framework = 'net11.0'
        tool_frameworks = $frameworks
        zip_compression = '.NET ZipArchive CompressionLevel.Optimal; every top-level published file'
        measurements = $measurements
    }
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath "$output/results.json" -Encoding utf8NoBOM
} finally {
    Pop-Location
}
