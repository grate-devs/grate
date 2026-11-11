function Publish-DistributionCli {
    param(
        [string]$Distribution,
        [string]$Framework,
        [string]$RuntimeIdentifier,
        [string]$Version,
        [string]$OutputDirectory
    )

    $publishArguments = @(
        'publish', 'src/grate/grate.csproj', '-c', 'Release', '-f', $Framework,
        '-r', $RuntimeIdentifier, '--self-contained', 'true',
        "-p:TargetFrameworks=$Framework", "-p:GrateDistribution=$Distribution",
        "-p:ArtifactsPath=$OutputDirectory/cli-build", "-p:Version=$Version",
        '-o', "$OutputDirectory/standalone"
    )
    dotnet @publishArguments

    $dependencyFiles = @(Get-ChildItem -LiteralPath "$OutputDirectory/cli-build/bin/grate" -Filter grate.deps.json -Recurse)
    if ($dependencyFiles.Count -ne 1) {
        throw 'Expected exactly one self-contained CLI dependency manifest.'
    }
    $dependencies = Get-Content -LiteralPath $dependencyFiles[0].FullName -Raw | ConvertFrom-Json -AsHashtable
    Assert-DistributionDependencies -Dependencies $dependencies -Distribution $Distribution
    Copy-Item -LiteralPath $dependencyFiles[0].FullName -Destination "$OutputDirectory/grate.deps.json"
}

function Assert-DistributionToolPackage {
    param(
        [string]$PackagePath,
        [string[]]$Frameworks,
        [string]$Distribution
    )

    $archive = [IO.Compression.ZipFile]::OpenRead($PackagePath)
    try {
        foreach ($framework in $Frameworks) {
            $prefix = "tools/$framework/any"
            $dependencyEntry = $archive.GetEntry("$prefix/grate.deps.json")
            $settingsEntry = $archive.GetEntry("$prefix/DotnetToolSettings.xml")
            if (!$dependencyEntry -or !$settingsEntry) {
                throw "Missing $framework tool payload."
            }
            $reader = [IO.StreamReader]::new($dependencyEntry.Open())
            try {
                $dependencies = $reader.ReadToEnd() | ConvertFrom-Json -AsHashtable
                Assert-DistributionDependencies -Dependencies $dependencies -Distribution $Distribution
            } finally {
                $reader.Dispose()
            }
            $reader = [IO.StreamReader]::new($settingsEntry.Open())
            try {
                [xml]$settings = $reader.ReadToEnd()
                if ($settings.DotNetCliTool.Commands.Command.Name -cne 'grate') {
                    throw 'Every distribution must expose the command grate.'
                }
            } finally {
                $reader.Dispose()
            }
        }
    } finally {
        $archive.Dispose()
    }
}

function Build-DistributionTool {
    param(
        [string]$Distribution,
        [string[]]$Frameworks,
        [string]$Version,
        [string]$PackageId,
        [string]$OutputDirectory
    )

    $packArguments = @(
        'pack', 'src/grate/grate.csproj', '-c', 'Release',
        '-p:PackAsTool=true', '-p:SelfContained=false',
        "-p:GrateDistribution=$Distribution", "-p:ArtifactsPath=$OutputDirectory/tool-build",
        "-p:PackageVersion=$Version", '-o', "$OutputDirectory/packages"
    )
    dotnet @packArguments
    $packageParameters = @{
        PackagePath = "$OutputDirectory/packages/$PackageId.$Version.nupkg"
        Frameworks = $Frameworks
        Distribution = $Distribution
    }
    Assert-DistributionToolPackage @packageParameters
}

function Install-DistributionTool {
    param(
        [string]$PackageId,
        [string]$Version,
        [string]$Framework,
        [string]$OutputDirectory
    )

    # Only the freshly built package may satisfy this installation.
    $feed = [Security.SecurityElement]::Escape("$OutputDirectory/packages")
    "<configuration><packageSources><clear/><add key=`"local`" value=`"$feed`"/></packageSources></configuration>" |
        Set-Content -LiteralPath "$OutputDirectory/NuGet.Config" -Encoding utf8NoBOM
    $savedPackages = $env:NUGET_PACKAGES
    try {
        $env:NUGET_PACKAGES = "$OutputDirectory/tool-cache"
        $installArguments = @(
            'tool', 'install', $PackageId, '--version', $Version, '--framework', $Framework,
            '--tool-path', "$OutputDirectory/tool", '--configfile', "$OutputDirectory/NuGet.Config"
        )
        dotnet @installArguments
    } finally {
        $env:NUGET_PACKAGES = $savedPackages
    }
}

function Build-DistributionTests {
    param(
        [string]$Database,
        [string]$Framework,
        [string]$OutputDirectory
    )

    # Tests retain normal All references; only the explicitly selected executable is slim.
    $buildArguments = @(
        'build', "unittests/CommandLine/CommandLine.$Database/CommandLine.$Database.csproj",
        '-c', 'Release', "-p:TargetFrameworks=$Framework", "-p:ArtifactsPath=$OutputDirectory/test-build"
    )
    dotnet @buildArguments
}

