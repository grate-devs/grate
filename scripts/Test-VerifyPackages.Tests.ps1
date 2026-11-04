#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$verify = Join-Path $PSScriptRoot 'verify-packages.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('grate-package-contract-' + [Guid]::NewGuid().ToString('N'))
$oldPath = $env:PATH
$oldExit = $env:GRATE_MOCK_PUBLISH_EXIT
$hadNativeExitCode = $null -ne (Get-Variable LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue)
$oldNativeExitCode = $global:LASTEXITCODE
try {
    New-Item -ItemType Directory -Path "$root/bin" -Force | Out-Null
    # A real child process preserves native exit handling, unlike a function mock.
    $mock = @'
#!/usr/bin/env pwsh
$ErrorActionPreference = 'Stop'
# PowerShell's script entry point splits native -name:value arguments. Restore
# that representation before recording the publish command contract.
$nativeArgs = @()
for ($index = 0; $index -lt $args.Count; $index++) {
    if ($args[$index] -in @('-p', '-getProperty')) {
        $nativeArgs += $args[$index] + ':' + $args[++$index]
    } else { $nativeArgs += $args[$index] }
}
$args = $nativeArgs
if ($args[0] -eq 'msbuild') {
    if ($args -contains '-getProperty:TargetFrameworks') { 'net11.0' }
    else { '11.0.0-rc.3.26522.148' }
    exit 0
}
if ($args[0] -ne 'publish') { throw "Unexpected dotnet command: $args" }
ConvertTo-Json -InputObject @($args) | Set-Content 'publish-args.json'
if ($env:GRATE_MOCK_PUBLISH_EXIT) { exit ([int]$env:GRATE_MOCK_PUBLISH_EXIT) }
$rid = $args[[Array]::IndexOf($args, '-r') + 1]
$output = $args[[Array]::IndexOf($args, '-o') + 1]
$build = "src/grate/bin/Release/net11.0/$rid"
New-Item -ItemType Directory -Path $output, $build -Force | Out-Null
'{"runtimeOptions":{"includedFrameworks":[{"name":"Microsoft.NETCore.App","version":"11.0.0-rc.3.26522.148"}]}}' | Set-Content "$build/grate.runtimeconfig.json"
@{ libraries = @{ "runtimepack.Microsoft.NETCore.App.Runtime.$rid/11.0.0-rc.3.26522.148" = @{} } } | ConvertTo-Json -Depth 5 | Set-Content "$build/grate.deps.json"
'@
    $mock | Set-Content "$root/bin/mock.ps1"
    if ($IsWindows) {
        "@echo off`r`n`"$PSHOME/pwsh.exe`" -NoLogo -NoProfile -File `"%~dp0mock.ps1`" %*`r`nexit /b %errorlevel%" | Set-Content "$root/bin/dotnet.cmd"
    } else {
        $mock | Set-Content "$root/bin/dotnet"
        chmod +x "$root/bin/dotnet"
    }
    $env:PATH = "$root/bin$([IO.Path]::PathSeparator)$oldPath"
    $env:GRATE_MOCK_PUBLISH_EXIT = $null
    Push-Location $root
    try {
        foreach ($version in @('0.0.1', '2.3.4')) {
            & $verify -Kind Standalone -RuntimeIdentifier win-x64 -StandaloneVersion $version -OutputDirectory "$root/output-$version"
            $publishArgs = Get-Content 'publish-args.json' -Raw | ConvertFrom-Json
            if ($publishArgs -cnotcontains "-p:Version=$version") { throw "Standalone publish did not receive fixture version $version." }
            if ($publishArgs -cnotcontains '-p:SelfContained=true' -or $publishArgs -cnotcontains '-p:TargetFrameworks=net11.0') { throw 'Standalone verification lost its selected publish form/framework.' }
            if (!(Test-Path "$root/output-$version/grate.runtimeconfig.json")) { throw 'Successful verification did not preserve runtime evidence.' }
        }
        $env:GRATE_MOCK_PUBLISH_EXIT = '42'
        $rejected = $false
        try {
            & $verify -Kind Standalone -RuntimeIdentifier win-arm64 -StandaloneVersion '0.0.1' -OutputDirectory "$root/failed"
        } catch {
            $rejected = $_.Exception.Message -match '42'
        }
        if (!$rejected) { throw 'A failed native publish must terminate standalone verification with its exit code.' }
        if (Test-Path "$root/failed/grate.runtimeconfig.json") { throw 'A failed publish must not produce successful verification evidence.' }
    } finally { Pop-Location }
} finally {
    $env:PATH = $oldPath
    $env:GRATE_MOCK_PUBLISH_EXIT = $oldExit
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    # The expected exit-42 case must not become the result of GitHub's pwsh
    # wrapper, which exits with LASTEXITCODE after dot-sourcing the step script.
    if ($hadNativeExitCode) { $global:LASTEXITCODE = $oldNativeExitCode }
    else { Remove-Variable LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue }
}
Write-Host 'PASS: explicit standalone fixture versions reach publish; native publish failures stop verification.'
