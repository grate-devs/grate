param(
    [ValidateSet('All', 'SQLite', 'SQLServer', 'MariaDB', 'PostgreSQL', 'Oracle')]
    [string]$Distribution = 'All',
    [Parameter(Mandatory)]
    [ValidateSet('win-x64', 'win-x86', 'win-arm64', 'linux-musl-x64', 'linux-musl-arm64', 'linux-x64', 'linux-arm64', 'osx-x64', 'osx-arm64')]
    [string]$RuntimeIdentifier,
    [Parameter(Mandatory)][ValidatePattern('\A[0-9A-Za-z][0-9A-Za-z.+-]*\z')][string]$Version,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidatePattern('(?:@sha256:|\Asha256:)[a-f0-9]{64}\z')][string]$ContainerImage,
    [string]$NuGetPackagesDirectory
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
. "$PSScriptRoot/../ci/Distribution.Common.ps1"
. "$PSScriptRoot/distribution_profiles.ps1"
$Distribution = @(Get-GrateDistributionNames | Where-Object { $_ -eq $Distribution })[0]
$RuntimeIdentifier = $RuntimeIdentifier.ToLowerInvariant()

function Invoke-NativeAotCommand {
    param(
        [string]$Executable,
        [string[]]$Arguments,
        [switch]$AllowFailure
    )

    if ($ContainerImage) {
        $containerArguments = @(
            'run', '--rm', '--volume', "${repository}:$repository", '--volume', "${OutputDirectory}:$OutputDirectory",
            '--volume', "${NuGetPackagesDirectory}:$NuGetPackagesDirectory", '--workdir', $repository,
            '--env', "NUGET_PACKAGES=$NuGetPackagesDirectory", '--entrypoint', $Executable, $ContainerImage
        ) + $Arguments
        & docker @containerArguments
    } else {
        & $Executable @Arguments
    }
    if (!$AllowFailure -and $LASTEXITCODE -ne 0) {
        throw "$Executable exited with code $LASTEXITCODE."
    }
}

function Assert-NativeAotExecutable {
    param(
        [string]$Executable
    )

    $help = Invoke-NativeAotCommand -Executable $Executable -Arguments @('--help') | Out-String
    if ($Distribution -eq 'All') {
        return
    }
    if (!$help.Contains("This build supports $Distribution only.")) {
        throw "$Executable is not the expected $Distribution CLI."
    }
    $otherProvider = if ($Distribution -eq 'SQLite') { 'postgresql' } else { 'sqlite' }
    $savedPreference = $PSNativeCommandUseErrorActionPreference
    try {
        $PSNativeCommandUseErrorActionPreference = $false
        $arguments = @('--databasetype', $otherProvider, '--connectionstring', 'invalid', '--silent')
        $rejection = Invoke-NativeAotCommand -Executable $Executable -Arguments $arguments -AllowFailure 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0 -or !$rejection.Contains("This build supports $Distribution only.")) {
            throw "$Executable did not reject $otherProvider as an unsupported provider."
        }
    } finally {
        $PSNativeCommandUseErrorActionPreference = $savedPreference
    }
}

function Test-NativeAotMigration {
    param(
        [string]$Executable,
        [string]$Directory
    )

    New-Item -ItemType Directory -Path "$Directory/sql/up" -Force | Out-Null
    # The CHECK verifies data; a rerun of this one-time script fails CREATE TABLE.
    $sql = 'CREATE TABLE package_smoke (id INTEGER PRIMARY KEY); INSERT INTO package_smoke VALUES (1); CREATE TEMP TABLE package_check (value INTEGER CHECK(value = 1)); INSERT INTO package_check SELECT CASE WHEN COUNT(*) = 1 AND MIN(id) = 1 THEN 1 ELSE 0 END FROM package_smoke;'
    Set-Content -LiteralPath "$Directory/sql/up/001_create.sql" -Value $sql -Encoding utf8NoBOM
    foreach ($attempt in 1..2) {
        $arguments = @(
            '--databasetype', 'sqlite', '--connectionstring', "Data Source=$Directory/smoke.db",
            '--files', "$Directory/sql", '--output', "$Directory/output", '--silent'
        )
        Invoke-NativeAotCommand -Executable $Executable -Arguments $arguments
    }
    if (!(Test-Path -LiteralPath "$Directory/smoke.db") -or (Get-Item -LiteralPath "$Directory/smoke.db").Length -eq 0) {
        throw 'The NativeAOT CLI did not create a SQLite database.'
    }
    $ran = @(Get-ChildItem -LiteralPath "$Directory/output" -Filter '001_create.sql' -File -Recurse |
        Where-Object { $_.FullName -match '[\\/]itemsRan[\\/]up[\\/]001_create\.sql$' })
    if ($ran.Count -ne 1) {
        throw "Expected one executed migration script, found $($ran.Count)."
    }
}

$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $OutputDirectory) {
    throw "Use a fresh output directory: $OutputDirectory"
}
$repository = [IO.Path]::GetFullPath("$PSScriptRoot/../..")
$initialLocation = (Get-Location).Path
$archivePath = $null
try {
    Set-Location -LiteralPath $repository
    New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
    if ($ContainerImage) {
        if (!$NuGetPackagesDirectory) {
            $NuGetPackagesDirectory = if ($env:NUGET_PACKAGES) { $env:NUGET_PACKAGES } else { Join-Path $HOME '.nuget/packages' }
        }
        $NuGetPackagesDirectory = [IO.Path]::GetFullPath($NuGetPackagesDirectory)
        # A bind mount keeps compiler/runtime evidence readable by host PowerShell.
        New-Item -ItemType Directory -Path $NuGetPackagesDirectory -Force | Out-Null
    }
    $buildRoot = "$OutputDirectory/build"
    $published = "$OutputDirectory/published"
    $extracted = "$OutputDirectory/extracted"
    $profile = Get-GrateDistribution -Name $Distribution
    $archivePath = "$OutputDirectory/$($profile.PackageId)-$RuntimeIdentifier-nativeaot-$Version.zip"
    $framework = 'net11.0'
    $runtimeArguments = @('msbuild', 'src/grate/grate.csproj', '-nologo', "-p:TargetFramework=$framework", '-getProperty:RuntimeFrameworkVersion')
    $expectedRuntime = (Invoke-NativeAotCommand -Executable dotnet -Arguments $runtimeArguments | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $expectedRuntime -notlike '11.0.*') {
        throw 'Could not resolve the pinned net11.0 runtime.'
    }

    # NativeAOT has no runtimeconfig. Capture the actual compiler/runtime pack and
    # linker output from the publish target, instead of inferring AOT from a flag.
    $evidenceTarget = "$OutputDirectory/NativeAot.Evidence.targets"
    $target = @'
<Project>
  <Target Name="RecordGrateNativeAotEvidence" AfterTargets="Publish" Condition="'$(MSBuildProjectName)' == 'grate'">
    <WriteLinesToFile File="$(NativeAotEvidenceFile)" Overwrite="true"
      Lines="RuntimePackagePath=$(RuntimePackagePath);IlcHostPackagePath=$(IlcHostPackagePath);NativeBinary=$(NativeBinary);NativeIntermediateOutputPath=$(NativeIntermediateOutputPath)" />
  </Target>
</Project>
'@
    Set-Content -LiteralPath $evidenceTarget -Value $target -Encoding utf8NoBOM
    $arguments = @(
        'publish', 'src/grate/grate.csproj', '-c', 'Release', '-f', $framework,
        '-r', $RuntimeIdentifier, '--self-contained', 'true',
        "-p:TargetFrameworks=$framework", "-p:GrateDistribution=$Distribution", "-p:Version=$Version",
        "-p:ArtifactsPath=$buildRoot", '-p:PublishAot=true', '-p:PublishTrimmed=true', '-p:TrimMode=full',
        '-p:PublishSingleFile=false', '-p:PublishReadyToRun=false', '-p:EnableCompressionInSingleFile=false',
        '-p:IncludeNativeLibrariesForSelfExtract=false', '-p:IncludeAllContentForSelfExtract=false',
        '-p:SuppressTrimAnalysisWarnings=false', '-p:TrimmerSingleWarn=false',
        '-p:ILLinkTreatWarningsAsErrors=false', '-p:IlcTreatWarningsAsErrors=false',
        '-p:WarningsNotAsErrors=IL2026%3BIL3050',
        "-p:CustomAfterMicrosoftCommonTargets=$evidenceTarget", "-p:NativeAotEvidenceFile=$OutputDirectory/native-build.txt",
        '-o', $published
    )
    $arguments | ConvertTo-Json | Set-Content -LiteralPath "$OutputDirectory/publish-arguments.json" -Encoding utf8NoBOM
    # Tee preserves expanded, nonfatal IL diagnostics in both CI and the evidence.
    Invoke-NativeAotCommand -Executable dotnet -Arguments $arguments 2>&1 | Tee-Object -FilePath "$OutputDirectory/publish.log" | Write-Host
    if ($LASTEXITCODE -ne 0) {
        throw "NativeAOT publish exited with code $LASTEXITCODE."
    }

    $evidence = @{}
    foreach ($line in Get-Content -LiteralPath "$OutputDirectory/native-build.txt") {
        $pair = $line -split '=', 2
        $evidence[$pair[0]] = $pair[1].Replace('\', '/')
    }
    $runtimePack = $evidence.RuntimePackagePath.TrimEnd('/')
    $compilerPack = $evidence.IlcHostPackagePath.TrimEnd('/')
    if ($runtimePack -notlike "*/microsoft.netcore.app.runtime.nativeaot.$RuntimeIdentifier/$expectedRuntime" -or
        $compilerPack -notlike "*/runtime.*.microsoft.dotnet.ilcompiler/$expectedRuntime") {
        throw 'NativeAOT compiler/runtime pack does not match the pinned runtime and RID.'
    }
    $compilerName = if ($IsWindows) { 'ilc.exe' } else { 'ilc' }
    if (!(Test-Path -LiteralPath "$compilerPack/tools/$compilerName") -or !(Test-Path -LiteralPath "$runtimePack/runtimes/$RuntimeIdentifier/native/System.Private.CoreLib.dll")) {
        throw 'NativeAOT compiler/runtime pack files are missing.'
    }
    $responseFile = "$($evidence.NativeIntermediateOutputPath.TrimEnd('/'))/grate.ilc.rsp"
    $response = (Get-Content -LiteralPath $responseFile -Raw).Replace('\', '/')
    if (!$response.Contains("$runtimePack/runtimes/$RuntimeIdentifier/native/System.Private.CoreLib.dll")) {
        throw 'Native compiler response does not reference the expected runtime pack.'
    }
    $executableName = if ($RuntimeIdentifier.StartsWith('win-')) { 'grate.exe' } else { 'grate' }
    $executable = "$published/$executableName"
    $nativeBinary = [IO.Path]::GetFullPath($evidence.NativeBinary).Replace('\', '/')
    $normalizedBuildRoot = [IO.Path]::GetFullPath($buildRoot).Replace('\', '/').TrimEnd('/')
    $pathComparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (!$nativeBinary.StartsWith("$normalizedBuildRoot/", $pathComparison) -or
        (Get-FileHash -LiteralPath $nativeBinary).Hash -cne (Get-FileHash -LiteralPath $executable).Hash) {
        throw 'Published executable does not match this isolated native linker output.'
    }
    if (Test-Path -LiteralPath "$published/grate.dll") {
        throw 'NativeAOT payload contains a managed CLI assembly.'
    }
    # Native publishing omits both deps.json and runtimeconfig.json. Verify the
    # selected restore target in this invocation's isolated assets instead.
    $assetsPath = "$buildRoot/obj/grate/project.assets.json"
    $assets = Get-Content -LiteralPath $assetsPath -Raw | ConvertFrom-Json -AsHashtable
    $assetTarget = "$framework/$RuntimeIdentifier"
    if (!$assets.targets.ContainsKey($assetTarget)) {
        throw 'NativeAOT dependency graph does not match the selected framework and RID.'
    }
    $dependencies = @{ libraries = $assets.targets[$assetTarget] }
    Assert-DistributionDependencies -Dependencies $dependencies -Distribution $Distribution
    Copy-Item -LiteralPath $assetsPath -Destination "$OutputDirectory/project.assets.json"

    $payload = @(Get-ChildItem -LiteralPath $published -File -Recurse | Where-Object {
        $_.Extension -notin @('.pdb', '.dbg') -and $_.FullName -notmatch '(?i)[\\/][^\\/]+\.dSYM([\\/]|$)'
    })
    if ($Distribution -in @('All', 'SQLite')) {
        $sqliteName = if ($RuntimeIdentifier.StartsWith('win-')) { 'e_sqlite3.dll' } elseif ($RuntimeIdentifier.StartsWith('osx-')) { 'libe_sqlite3.dylib' } else { 'libe_sqlite3.so' }
        if (!(Test-Path -LiteralPath "$published/$sqliteName")) {
            throw "NativeAOT SQLite payload is missing $sqliteName."
        }
    }
    $inventory = @(foreach ($file in $payload) {
        [ordered]@{
            Path = [IO.Path]::GetRelativePath($published, $file.FullName).Replace('\', '/')
            SHA256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
            UnixMode = if ($IsWindows) { 0 } else { [int][IO.File]::GetUnixFileMode($file.FullName) }
        }
    })
    $inventory | ConvertTo-Json | Set-Content -LiteralPath "$OutputDirectory/payload.json" -Encoding utf8NoBOM
    $archive = [IO.Compression.ZipFile]::Open($archivePath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in $inventory) {
            $entry = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, "$published/$($file.Path)", $file.Path)
            if (!$IsWindows) {
                $entry.ExternalAttributes = (0x8000 -bor $file.UnixMode) -shl 16
            }
        }
    } finally {
        $archive.Dispose()
    }

    # Restore modes from ZIP metadata: this verifies the archive's executable bit,
    # and does not mask a lost bit by unconditionally chmod'ing the extracted CLI.
    $archive = [IO.Compression.ZipFile]::OpenRead($archivePath)
    try {
        if ($archive.Entries.Count -ne $inventory.Count) {
            throw 'NativeAOT ZIP payload count differs from the publish output.'
        }
        foreach ($file in $inventory) {
            $entry = $archive.GetEntry($file.Path)
            if (!$entry) {
                throw "NativeAOT ZIP is missing $($file.Path)."
            }
            $destination = "$extracted/$($file.Path)"
            New-Item -ItemType Directory -Path (Split-Path $destination) -Force | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destination)
            if (!$IsWindows) {
                $mode = ($entry.ExternalAttributes -shr 16) -band 0x1ff
                if ($mode -ne ($file.UnixMode -band 0x1ff)) {
                    throw "NativeAOT ZIP lost Unix mode for $($file.Path)."
                }
                [IO.File]::SetUnixFileMode($destination, [IO.UnixFileMode]$mode)
            }
            if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -cne $file.SHA256) {
                throw "NativeAOT ZIP roundtrip hash mismatch for $($file.Path)."
            }
        }
    } finally {
        $archive.Dispose()
    }
    $extractedExecutable = "$extracted/$executableName"
    if (!$IsWindows -and (([int][IO.File]::GetUnixFileMode($extractedExecutable) -band 0x49) -eq 0)) {
        throw 'NativeAOT ZIP executable has no Unix execute bits.'
    }
    Assert-NativeAotExecutable -Executable $extractedExecutable
    Invoke-NativeAotCommand -Executable $extractedExecutable -Arguments @('skills', 'install', '--local', '--path', "$OutputDirectory/skill")
    if (!(Test-Path -LiteralPath "$OutputDirectory/skill/.agents/skills/use-grate/SKILL.md")) {
        throw 'The NativeAOT CLI did not install its bundled skill.'
    }
    if ($Distribution -in @('All', 'SQLite')) {
        Test-NativeAotMigration -Executable $extractedExecutable -Directory "$OutputDirectory/smoke"
    }
    Write-Host "Verified $Distribution NativeAOT $RuntimeIdentifier ($expectedRuntime): $archivePath"
} catch {
    # Failed validation must never leave a candidate release ZIP behind.
    if ($archivePath -and (Test-Path -LiteralPath $archivePath)) {
        Remove-Item -LiteralPath $archivePath -Force
    }
    throw
} finally {
    Set-Location -LiteralPath $initialLocation
}
