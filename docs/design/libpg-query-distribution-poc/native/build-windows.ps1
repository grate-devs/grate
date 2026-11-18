[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $SourceDirectory,
    [Parameter(Mandatory)][ValidateSet('win-x64', 'win-x86', 'win-arm64')][string] $Rid,
    [Parameter(Mandatory)][string] $OutputDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) {
    throw 'This script requires Windows and Visual Studio C++ Build Tools.'
}

$source = (Resolve-Path -LiteralPath $SourceDirectory).Path
$output = [IO.Path]::GetFullPath($OutputDirectory)
$expectedCommit = 'c1546e7e97edc93fe8474d7a59881e91fbf48cfc'
$commit = & git -C $source rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $commit -ne $expectedCommit) {
    throw "Expected libpg_query 18.1.0 at $expectedCommit."
}
& git -C $source diff --exit-code HEAD
if ($LASTEXITCODE -ne 0) {
    throw 'Build from an unmodified libpg_query source checkout.'
}

$target = @{ 'win-x64' = 'amd64'; 'win-x86' = 'x86'; 'win-arm64' = 'arm64' }[$Rid]
$machine = @{ 'win-x64' = 'X64'; 'win-x86' = 'X86'; 'win-arm64' = 'ARM64' }[$Rid]
$machineCode = @{ 'win-x64' = '8664'; 'win-x86' = '14C'; 'win-arm64' = 'AA64' }[$Rid]
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) {
    throw 'Visual Studio Installer vswhere.exe was not found.'
}
$installation = & $vswhere -latest -products '*' -property installationPath
if ($LASTEXITCODE -ne 0 -or -not $installation) {
    throw 'Visual Studio C++ Build Tools were not found.'
}
$shell = Join-Path $installation 'Common7/Tools/Launch-VsDevShell.ps1'
& $shell -Arch $target -HostArch amd64 -SkipAutomaticLocation

$nativeDirectory = Join-Path $output "runtimes/$Rid/native"
$buildDirectory = Join-Path $source '.poc-windows-build'
$licenses = Join-Path $output 'licenses'
New-Item -ItemType Directory -Force $nativeDirectory, $buildDirectory, $licenses | Out-Null
$dll = Join-Path $nativeDirectory 'pg_query.dll'
$definition = Join-Path $buildDirectory 'pg_query.def'
@'
LIBRARY pg_query
EXPORTS
    pg_query_parse
    pg_query_free_parse_result
'@ | Set-Content -LiteralPath $definition -Encoding ascii

Push-Location $source
try {
    # Upstream's MSVC target produces a static archive. Build it with a static CRT,
    # then export the C API from a DLL without requiring a VC++ redistributable.
    & nmake /NOLOGO /F Makefile.msvc build 'CC=cl /nologo /O2 /MT'
    if ($LASTEXITCODE -ne 0) { throw 'MSVC static-library build failed.' }
    & link /NOLOGO /DLL "/MACHINE:$machine" "/OUT:$dll" "/DEF:$definition" "/IMPLIB:$buildDirectory/pg_query.lib" pg_query.lib
    if ($LASTEXITCODE -ne 0) { throw 'MSVC DLL link failed.' }
    $headers = & dumpbin /NOLOGO /HEADERS $dll
    if ($LASTEXITCODE -ne 0 -or ($headers -join "`n") -notmatch "(?im)\b$machineCode machine") {
        throw "The DLL machine type does not match $Rid."
    }
    $exports = & dumpbin /NOLOGO /EXPORTS $dll
    if ($LASTEXITCODE -ne 0) { throw 'Could not inspect DLL exports.' }
    foreach ($name in 'pg_query_parse', 'pg_query_free_parse_result') {
        if (($exports -join "`n") -notmatch "(?m)\b$name\s*$") {
            throw "The DLL does not export $name by its C API name."
        }
    }
    $dependencies = & dumpbin /NOLOGO /DEPENDENTS $dll
    if ($LASTEXITCODE -ne 0) { throw 'Could not inspect DLL dependencies.' }
    if (($dependencies -join "`n") -match '(?i)VCRUNTIME|MSVCP|ucrtbase') {
        throw 'Unexpected dependency on the dynamically linked Visual C++ runtime.'
    }
    $headers
    $exports
    $dependencies
}
finally {
    Pop-Location
}

Copy-Item -LiteralPath (Join-Path $source 'LICENSE') -Destination (Join-Path $licenses 'libpg_query-LICENSE')
Copy-Item -LiteralPath (Join-Path $source 'src/postgres/COPYRIGHT') -Destination (Join-Path $licenses 'PostgreSQL-COPYRIGHT')
Copy-Item -LiteralPath (Join-Path $source 'vendor/upb/LICENSE') -Destination (Join-Path $licenses 'upb-LICENSE')
Copy-Item -LiteralPath (Join-Path $source 'vendor/upb/third_party/utf8_range/LICENSE') -Destination (Join-Path $licenses 'utf8_range-LICENSE')
$xxhash = Get-Content -LiteralPath (Join-Path $source 'vendor/xxhash/xxhash.h') -Raw
$notice = [regex]::Match($xxhash, '(?s)\A/\*.*?\*/').Value
if (-not $notice.Contains('BSD 2-Clause')) { throw 'Could not extract the xxHash license notice.' }
$notice | Set-Content -LiteralPath (Join-Path $licenses 'xxhash-LICENSE') -Encoding utf8
Get-FileHash -Algorithm SHA256 -LiteralPath $dll
