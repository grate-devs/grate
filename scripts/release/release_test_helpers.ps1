$ErrorActionPreference = 'Stop'
$script:TestCount = 0
function Assert-Equal($Expected, $Actual, [string]$Message = '') {
    if (!(Test-JsonEqual $Expected $Actual)) { throw "Assertion failed: $Message expected $($Expected | ConvertTo-Json -Depth 30 -Compress), actual $($Actual | ConvertTo-Json -Depth 30 -Compress)" }
}
function Assert-True([bool]$Value, [string]$Message = '') { if (!$Value) { throw "Assertion failed: $Message" } }
function Assert-Throws([scriptblock]$Action, [string]$Pattern = '*') {
    $caught = $null
    try { $null = & $Action } catch { $caught = $_ }
    if (!$caught) { throw 'Expected an exception.' }
    if ($caught.Exception.Message -notlike $Pattern) { throw "Unexpected exception: $($caught.Exception.Message), expected $Pattern" }
}
function Invoke-Test([string]$Name, [scriptblock]$TestBody) {
    try { & $TestBody; $script:TestCount++; Write-Host "PASS $Name" }
    catch { throw "FAIL ${Name}: $($_.Exception.Message)`n$($_.ScriptStackTrace)" }
}
function New-TestDirectory { $path = Join-Path ([IO.Path]::GetTempPath()) ('grate powershell test ' + [Guid]::NewGuid().ToString('N')); $null = [IO.Directory]::CreateDirectory($path); $path }
