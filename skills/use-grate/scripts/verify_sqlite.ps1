# 77 means verification was skipped, not passed.
$dotnet = Get-Command dotnet -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$sdkVersion = if ($dotnet) { & $dotnet.Source --version 2>$null }
if (-not $dotnet -or $LASTEXITCODE -ne 0 -or "$sdkVersion" -notmatch '^(\d+)\.' -or [int]$Matches[1] -lt 10) {
    [Console]::Error.WriteLine('SKIP: SQLite verification needs .NET SDK 10 or newer. grate and the skill can still be used without it.')
    exit 77
}
& $dotnet.Source run --file (Join-Path $PSScriptRoot 'verify_sqlite.cs') -- @args
exit $LASTEXITCODE
