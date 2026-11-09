#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$root = Join-Path ([IO.Path]::GetTempPath()) ('grate-homebrew-' + [Guid]::NewGuid().ToString('N'))
$fixtureScripts = Join-Path $root 'installers/homebrew'
$sourceArchive = Join-Path $root '2.2.0.tar.gz'
$expected = [ordered]@{
    All = @('grate', 'Grate')
    SQLite = @('grate-sqlite', 'GrateSqlite')
    SQLServer = @('grate-sqlserver', 'GrateSqlserver')
    MariaDB = @('grate-mariadb', 'GrateMariadb')
    PostgreSQL = @('grate-postgresql', 'GratePostgresql')
    Oracle = @('grate-oracle', 'GrateOracle')
}
$abcHash = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
$helloHash = '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824'
$savedAutoUpdate = $env:HOMEBREW_NO_AUTO_UPDATE
$savedInstallApi = $env:HOMEBREW_NO_INSTALL_FROM_API
$rubyChecks = 0
$homebrewChecked = $false

function Assert-Contains {
    param([string]$Actual, [string]$Expected)

    if (!$Actual.Contains($Expected)) {
        throw "Missing expected output: $Expected"
    }
}

function Assert-Rejected {
    param(
        [scriptblock]$Action,
        [string]$ExpectedError
    )

    try {
        & $Action
    } catch {
        if ($_.Exception.Message -notlike $ExpectedError) {
            throw "Expected '$ExpectedError', received '$($_.Exception.Message)'."
        }
        return
    }
    throw "Expected generator input to fail with '$ExpectedError'."
}

try {
    New-Item -ItemType Directory -Path $fixtureScripts -Force | Out-Null
    foreach ($name in @('Create-Formula.ps1', 'Create-Cask.ps1', 'Homebrew.Common.ps1', 'grate.rb.in')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $fixtureScripts
    }
    $formulaGenerator = Join-Path $fixtureScripts 'Create-Formula.ps1'
    $caskGenerator = Join-Path $fixtureScripts 'Create-Cask.ps1'
    # Known byte strings check checksum rendering without network access. These
    # synthetic inputs do not establish a valid source build or cask installation.
    [IO.File]::WriteAllText($sourceArchive, 'abc', [Text.UTF8Encoding]::new($false))
    foreach ($id in @($expected.Values | ForEach-Object { $_[0] })) {
        [IO.File]::WriteAllText("$root/$id-osx-arm64-self-contained-2.2.0.zip", 'abc', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText("$root/$id-osx-x64-self-contained-2.2.0.zip", 'hello', [Text.UTF8Encoding]::new($false))
    }
    & $formulaGenerator -version '2.2.0' -sourceArchive $sourceArchive -AllDistributions
    & $caskGenerator -version '2.2.0' -artifactDirectory $root -AllDistributions
    $formulaDirectory = "$root/artifacts/homebrew/formula"
    $caskDirectory = "$root/artifacts/homebrew/cask"
    if (@(Get-ChildItem -LiteralPath $formulaDirectory -Filter '*.rb').Count -ne 6 -or
        @(Get-ChildItem -LiteralPath $caskDirectory -Filter '*.rb').Count -ne 6) {
        throw 'Expected six separate formulae and six separate casks.'
    }
    foreach ($name in $expected.Keys) {
        $id = $expected[$name][0]
        $className = $expected[$name][1]
        $formulaPath = "$formulaDirectory/$id.rb"
        $caskPath = "$caskDirectory/$id.rb"
        $formula = Get-Content -LiteralPath $formulaPath -Raw
        $cask = Get-Content -LiteralPath $caskPath -Raw
        foreach ($fragment in @("class $className < Formula", "sha256 `"$abcHash`"", '-p:GrateDistribution=' + $name,
                'depends_on "dotnet"', '--no-self-contained', 'bin.install_symlink libexec/"grate"')) {
            Assert-Contains -Actual $formula -Expected $fragment
        }
        foreach ($fragment in @("cask `"$id`" do", "sha256 arm:   `"$abcHash`"", "intel: `"$helloHash`"",
                "/$id-osx-#{arch}-self-contained-#{version}.zip", 'binary "grate"', 'depends_on :macos')) {
            Assert-Contains -Actual $cask -Expected $fragment
        }
        foreach ($other in @($expected.Values | ForEach-Object { $_[0] } | Where-Object { $_ -cne $id })) {
            Assert-Contains -Actual $formula -Expected "conflicts_with `"$other`", because:"
            Assert-Contains -Actual $cask -Expected "`"$other`","
        }
        if ($name -in @('All', 'SQLite')) {
            Assert-Contains -Actual $formula -Expected '2.times do'
            Assert-Contains -Actual $formula -Expected 'CREATE TABLE widgets'
        } else {
            Assert-Contains -Actual $formula -Expected "This build supports $name only."
            Assert-Contains -Actual $formula -Expected '--databasetype sqlite --connectionstring invalid'
            if ($formula.Contains('CREATE TABLE widgets') -or $formula.Contains('grate-test.db')) {
                throw 'A server-only formula must not attempt a SQLite migration.'
            }
        }
        Assert-Contains -Actual $formula -Expected 'skill/.agents/skills/use-grate/SKILL.md'
        foreach ($path in @($formulaPath, $caskPath)) {
            $content = Get-Content -LiteralPath $path -Raw
            $bytes = [IO.File]::ReadAllBytes($path)
            if ($content.Contains("`r") -or $bytes[0] -eq 0xEF -or !$content.EndsWith("end`n") -or $content -match '@[A-Z_]+@') {
                throw "Invalid encoding, line ending or template placeholder: $path"
            }
            if (Get-Command ruby -ErrorAction SilentlyContinue) {
                & ruby -c $path | Out-Host
                $rubyChecks++
            }
        }
    }
    if (Get-Command brew -ErrorAction SilentlyContinue) {
        $env:HOMEBREW_NO_AUTO_UPDATE = '1'
        $env:HOMEBREW_NO_INSTALL_FROM_API = '1'
        $readDefinitions = @'
require "formulary"
require "cask/cask_loader"
require "base64"
root = Base64.strict_decode64("@ROOT_BASE64@")
formulas = Dir["#{root}/artifacts/homebrew/formula/*.rb"]
casks = Dir["#{root}/artifacts/homebrew/cask/*.rb"]
raise "Missing formulae/casks" unless formulas.length == 6 && casks.length == 6
formulas.each do |path|
  formula = Formulary.from_contents(File.basename(path, ".rb"), Pathname.new(path), File.read(path))
  raise "Missing formula conflicts" unless formula.conflicts.length == 5
end
casks.each do |path|
  cask = Cask::CaskLoader.load(File.read(path))
  raise "Missing cask conflicts" unless cask.conflicts_with[:cask].length == 5
end
puts "PASS: native Homebrew DSL loaded all six formulae and six casks."
'@
        $readDefinitions = $readDefinitions.Replace('@ROOT_BASE64@', [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($root)))
        & brew ruby -e $readDefinitions | Out-Host
        $homebrewChecked = $true
    }
    $publishedFormula = Get-Content -LiteralPath "$formulaDirectory/grate.rb" -Raw
    $publishedCask = Get-Content -LiteralPath "$caskDirectory/grate.rb" -Raw
    & $formulaGenerator -version '2.2.0' -sourceArchive $sourceArchive
    & $caskGenerator -version '2.2.0' -artifactDirectory $root
    if ((Get-Content -LiteralPath "$formulaDirectory/grate.rb" -Raw) -cne $publishedFormula -or
        (Get-Content -LiteralPath "$caskDirectory/grate.rb" -Raw) -cne $publishedCask) {
        throw 'Default All API changed identity or deterministic output.'
    }
    $prefixedFormula = "$root/custom/grate-oracle.rb"
    $prefixedCask = "$root/custom-cask/grate-oracle.rb"
    & $formulaGenerator -version '2.2.0' -releaseTag 'v2.2.0' -sourceArchive $sourceArchive -Distribution Oracle -outputPath $prefixedFormula
    & $caskGenerator -version '2.2.0' -releaseTag 'v2.2.0' -artifactDirectory $root -Distribution Oracle -outputPath $prefixedCask
    Assert-Contains -Actual (Get-Content -LiteralPath $prefixedFormula -Raw) -Expected '/tags/v2.2.0.tar.gz'
    Assert-Contains -Actual (Get-Content -LiteralPath $prefixedCask -Raw) -Expected '/download/v2.2.0/grate-oracle-osx-'
    $generatedHashes = @{}
    foreach ($path in @(Get-ChildItem -LiteralPath $formulaDirectory, $caskDirectory -Filter '*.rb' -File)) {
        $generatedHashes[$path.FullName] = (Get-FileHash -LiteralPath $path.FullName).Hash
    }
    foreach ($invalidVersion in @('2.2.0-rc.1', "2.2.0`n", '2.2.0+build')) {
        Assert-Rejected -ExpectedError "*validate*parameter 'version'*" -Action {
            & $formulaGenerator -version $invalidVersion -sourceArchive $sourceArchive
        }
        Assert-Rejected -ExpectedError "*validate*parameter 'version'*" -Action {
            & $caskGenerator -version $invalidVersion -artifactDirectory $root
        }
    }
    foreach ($tag in @('v2.3.0', '../../2.2.0', "v2.2.0`n", '2.2.0"; system("injected")')) {
        Assert-Rejected -ExpectedError 'releaseTag must be the version or the version prefixed with v.' -Action {
            & $formulaGenerator -version '2.2.0' -sourceArchive $sourceArchive -releaseTag $tag
        }
        Assert-Rejected -ExpectedError 'releaseTag must be the version or the version prefixed with v.' -Action {
            & $caskGenerator -version '2.2.0' -artifactDirectory $root -releaseTag $tag
        }
    }
    foreach ($generator in @($formulaGenerator, $caskGenerator)) {
        $parameters = @{
            version = '2.2.0'
            AllDistributions = $true
        }
        if ($generator -ceq $formulaGenerator) {
            $parameters.sourceArchive = $sourceArchive
        } else {
            $parameters.artifactDirectory = $root
        }
        Assert-Rejected -ExpectedError 'Use OutputDirectory and the default Distribution with AllDistributions.' -Action {
            & $generator @parameters -Distribution Oracle
        }
        Assert-Rejected -ExpectedError 'Use OutputDirectory and the default Distribution with AllDistributions.' -Action {
            & $generator @parameters -outputPath "$root/invalid-all.rb"
        }
    }

    $missingFormulaOutput = "$root/missing-source-output"
    Assert-Rejected -ExpectedError '*Source archive does not exist:*missing.tar.gz' -Action {
        & $formulaGenerator -version '2.2.0' -sourceArchive "$root/missing.tar.gz" -AllDistributions -OutputDirectory $missingFormulaOutput
    }
    if (Test-Path -LiteralPath $missingFormulaOutput) {
        throw 'A missing source archive created formula output.'
    }
    foreach ($extension in @('.zip', '.gz', '.tar', '.tgz', '.tar.gz.zip')) {
        $wrongExtension = "$root/source$extension"
        Copy-Item -LiteralPath $sourceArchive -Destination $wrongExtension
        Assert-Rejected -ExpectedError 'sourceArchive must be the downloaded source .tar.gz archive.' -Action {
            & $formulaGenerator -version '2.2.0' -sourceArchive $wrongExtension
        }
    }

    # The last profile's final input fails after all earlier profiles resolved.
    # A fresh output root proves no partial AllDistributions result was written.
    $missingCaskArchive = "$root/grate-oracle-osx-x64-self-contained-2.2.0.zip"
    Move-Item -LiteralPath $missingCaskArchive -Destination "$missingCaskArchive.wrong-name"
    $missingCaskOutput = "$root/missing-cask-output"
    Assert-Rejected -ExpectedError '*find*grate-oracle-osx-x64-self-contained-2.2.0.zip*' -Action {
        & $caskGenerator -version '2.2.0' -artifactDirectory $root -AllDistributions -OutputDirectory $missingCaskOutput
    }
    if (Test-Path -LiteralPath $missingCaskOutput) {
        throw 'A missing final archive created a partial cask set.'
    }
    Assert-Rejected -ExpectedError '*find*grate-oracle-osx-x64-self-contained-2.2.0.zip*' -Action {
        & $caskGenerator -version '2.2.0' -artifactDirectory $root -AllDistributions
    }
    foreach ($path in $generatedHashes.Keys) {
        if ((Get-FileHash -LiteralPath $path).Hash -cne $generatedHashes[$path]) {
            throw "Rejected input overwrote a valid manifest: $path"
        }
    }
    if ((Get-Content -LiteralPath "$formulaDirectory/grate.rb" -Raw) -cne $publishedFormula -or
        (Get-Content -LiteralPath "$caskDirectory/grate.rb" -Raw) -cne $publishedCask) {
        throw 'Rejected input overwrote a valid manifest.'
    }
    if ((Get-Content -LiteralPath "$fixtureScripts/grate.rb.in" -Raw) -cne
        (Get-Content -LiteralPath "$PSScriptRoot/grate.rb.in" -Raw)) {
        throw 'Generation modified the tracked formula template.'
    }
    Write-Host "PASS: six formula/cask identities, hashes, conflicts, provider-aware tests, stable versions, tag URLs and default All API; Ruby syntax checks: $rubyChecks; native Homebrew DSL: $homebrewChecked."
} finally {
    $env:HOMEBREW_NO_AUTO_UPDATE = $savedAutoUpdate
    $env:HOMEBREW_NO_INSTALL_FROM_API = $savedInstallApi
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
