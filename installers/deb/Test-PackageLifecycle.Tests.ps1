#!/usr/bin/env pwsh
. "$PSScriptRoot/Test-PackageLifecycle.ps1"
. "$PSScriptRoot/Verify-PackageLifecycle.ps1"
$ErrorActionPreference = 'Stop'
$realProcess = (Get-Item Function:Invoke-PackageTestProcess).ScriptBlock
$count = 0
$directory = Join-Path ([IO.Path]::GetTempPath()) ('grate-deb-tests-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($directory)
function Assert-Check([bool]$Condition,[string]$Message) { if (!$Condition) { throw $Message } }
function New-Result([string]$Output='', [int]$ExitCode=0) { @{Output=$Output; ErrorOutput=''; ExitCode=$ExitCode; TimedOut=$false} }
function Reset-Fake {
    $script:Requests = [Collections.Generic.List[object]]::new()
    $script:Token = 'a' * 32
    $script:Container = 'grate-deb-lifecycle-' + $script:Token
    $script:Installed = ''; $script:Purged=$false; $script:Applied=0
    $script:BadHistory=$false; $script:BadOwner=$false; $script:ChildFailed=$false; $script:ChildTimedOut=$false
    $script:Architecture='aarch64'
}
function Invoke-PackageTestDocker([string[]]$Arguments,[int]$TimeoutSeconds=45) {
    $script:Requests.Add(@{Arguments=$Arguments;Timeout=$TimeoutSeconds})
    switch ($Arguments[0]) {
        'info' { return New-Result $script:Architecture }
        'run' { return New-Result 'test-container-id' }
        'rm' { return New-Result $Arguments[-1] }
        'inspect' { return New-Result $(if ($script:BadOwner) {'wrong-token'} else {$script:Token}) }
        'cp' { return New-Result }
        'exec' {
            $command = if ($Arguments[1] -eq '--env') { @($Arguments[7..($Arguments.Length-1)]) } else { @($Arguments[2..($Arguments.Length-1)]) }
            switch ($command[0]) {
                'test' {
                    $path=$command[-1]
                    $present = if ($path -eq '/usr/bin/grate') { [bool]$script:Installed } elseif ($path -in @('/usr','/usr/bin')) { $command[1] -in @('-e','-d') } elseif ($path.EndsWith('/grate')) { $false } elseif ($command[1] -eq '-L') { $false } else { $true }
                    return New-Result '' $(if ($present) {0} else {1})
                }
                'printenv' { return New-Result $(if ($command[1] -eq 'PATH') {'/usr/local/bin:/usr/bin:/bin'} else {'1'}) }
                'mkdir' { return New-Result }
                'cmp' { return New-Result }
                'dpkg-deb' {
                    if ($command[1] -eq '-x') { return New-Result }
                    return New-Result $(switch ($command[-1]) { 'Package' {'grate'} 'Architecture' {'arm64'} 'Version' {if ($command[2].Contains('initial')) {'0.0.1-1'} else {'0.0.2-1'}} })
                }
                'dpkg-query' {
                    if ($command.Length -eq 2) { return New-Result 'inventory retained' }
                    if ($command[1] -eq '-L') { return New-Result "/usr`n/usr/bin`n/usr/bin/grate" }
                    if ($script:Purged) { return New-Result '' 1 }
                    return New-Result $(switch ($command[2]) { '-f=${Status}' {'install ok installed'} '-f=${Version}' {$script:Installed} '-f=${Architecture}' {'arm64'} })
                }
                'dpkg' { if ($command[1] -eq '--purge') { $script:Purged=$true }; return New-Result $(if ($command[1] -eq '--print-architecture') {'arm64'} else {''}) }
                'apt-get' {
                    if ($command[1] -eq 'remove') { $script:Installed='' }
                    elseif ($command[-1] -eq '/packages/initial.deb') { $script:Installed='0.0.1-1' }
                    elseif ($command[-1] -eq '/packages/upgrade.deb') { $script:Installed='0.0.2-1' }
                    return New-Result
                }
                '/usr/bin/grate' {
                    if ($command -contains 'before-upgrade') { $script:Applied=1 }
                    if ($command -contains 'after-upgrade') { $script:Applied=2 }
                    return New-Result
                }
                'sqlite3' {
                    $sql = $command[2]
                    return New-Result $(switch -Wildcard ($sql) {
                        'SELECT group_concat(id,*' { if ($script:Applied -eq 2) {'42,43'} else {'42'} }
                        'SELECT COUNT(*) FROM grate_ScriptsRun;' { if ($script:BadHistory) {'99'} else {[string]$script:Applied} }
                        'SELECT script_name*' {'001_create.sql'}
                        'SELECT group_concat(script_name*' {'001_create.sql,002_after_upgrade.sql'}
                        'SELECT group_concat(version,*' {'before-upgrade,after-upgrade'}
                        default {'0'}
                    })
                }
                default { throw "Unexpected container command: $command" }
            }
        }
        default { throw "Unexpected Docker request: $Arguments" }
    }
}
function Invoke-PackageTestProcess([string]$FilePath,[string[]]$Arguments,[int]$TimeoutSeconds) {
    $script:Requests.Add(@{FilePath=$FilePath;Arguments=$Arguments;Timeout=$TimeoutSeconds})
    Assert-Check ($Arguments -contains "$PSScriptRoot/Verify-PackageLifecycle.ps1") 'Wrapper must invoke the PowerShell verifier.'
    Assert-Check ($TimeoutSeconds -eq 600) 'Verifier must have an overall process deadline.'
    $result = New-Result '' $(if ($script:ChildFailed) {1} else {0})
    $result.TimedOut=$script:ChildTimedOut
    $result
}
function Verify-Fake {
    Test-PackageInstallation -Container $script:Container -ContainerToken $script:Token -Architecture arm64 -InitialVersion '0.0.1-1' -UpgradeVersion '0.0.2-1' -OutputDirectory $directory
}
try {
    $result = & $realProcess (Get-Process -Id $PID).Path @('-NoLogo','-NoProfile','-Command','[Console]::Out.Write("output"); [Console]::Error.Write("error"); exit 7') 5
    Assert-Check ($result.ExitCode -eq 7 -and $result.Output -ceq 'output' -and $result.ErrorOutput -ceq 'error' -and !$result.TimedOut) 'Process boundary must preserve exit code and both output streams.'
    $result = & $realProcess (Get-Process -Id $PID).Path @('-NoLogo','-NoProfile','-Command','Start-Sleep -Seconds 20') 1
    Assert-Check ($result.TimedOut) 'Process boundary must terminate a hung child.'
    $count++
    Reset-Fake
    Verify-Fake
    Assert-Check ($script:Purged -and $script:Applied -eq 2) 'Lifecycle must upgrade, apply two migrations, remove and purge.'
    Assert-Check ((Get-Content -LiteralPath "$directory/packages.txt" -Raw).Contains('inventory retained')) 'Lifecycle must retain package inventory.'
    $migrations=@($script:Requests | Where-Object { $_.Arguments -contains '/usr/bin/grate' -and $_.Arguments -contains '--databasetype' })
    Assert-Check ($migrations.Count -eq 4) 'Verify initial/upgrade migrations and both unchanged reruns.'
    $remote=@($script:Requests | Where-Object { $_.Arguments[0] -eq 'exec' -and $_.Arguments[1] -eq '--env' })
    Assert-Check ($remote.Count -gt 40 -and @($remote | Where-Object { $_.Arguments[4] -ne 'timeout' -or $_.Timeout -gt 190 }).Count -eq 0) 'Every package command must run in a bounded container exec.'
    $count++
    Reset-Fake; $script:BadHistory=$true; $errorRecord=$null
    try { Verify-Fake } catch { $errorRecord=$_ }
    Assert-Check ($errorRecord.Exception.Message -like '*Migration history count*') 'Wrong history must fail a real assertion.'
    Assert-Check (@($script:Requests | Where-Object { ($_.Arguments -join '|') -like '*dpkg-query|-W' }).Count -eq 1) 'Failure must retain final package inventory.'
    Assert-Check (!$script:Purged) 'Do not continue destructive lifecycle steps after a failed assertion.'
    $count++
    Reset-Fake; $script:BadOwner=$true; $errorRecord=$null
    try { Verify-Fake } catch { $errorRecord=$_ }
    Assert-Check ($errorRecord.Exception.Message -like '*ownership*' -and $script:Requests.Count -eq 1) 'Ownership failure must prevent all container-side commands.'
    $count++
    Reset-Fake; $errorRecord=$null
    try { Test-PackageInstallation -Container host -ContainerToken $script:Token -Architecture arm64 -InitialVersion '1' -UpgradeVersion '2' -OutputDirectory $directory } catch { $errorRecord=$_ }
    Assert-Check ($null -ne $errorRecord -and $script:Requests.Count -eq 0) 'An arbitrary host/container target must be rejected before Docker.'
    $count++
    [IO.File]::WriteAllText("$directory/initial.deb",'initial fixture')
    [IO.File]::WriteAllText("$directory/upgrade.deb",'upgrade fixture')
    $parameters=@{InitialPackage="$directory/initial.deb";UpgradePackage="$directory/upgrade.deb";Architecture='arm64';InitialVersion='0.0.1-1';UpgradeVersion='0.0.2-1';OutputDirectory=$directory}
    foreach ($failed in @($false,$true)) {
        Reset-Fake; $script:ChildFailed=$failed; $errorRecord=$null
        try { Invoke-PackageLifecycle @parameters } catch { $errorRecord=$_ }
        Assert-Check (($null -ne $errorRecord) -eq $failed) 'Wrapper must propagate verifier failure.'
        $run=@($script:Requests | Where-Object { $_.Arguments[0] -eq 'run' })
        Assert-Check ($run.Count -eq 1 -and $run[0].Arguments -contains '--detach' -and $run[0].Arguments -contains '10m') 'Container watchdog must leave time after eight-minute work deadline for diagnostics.'
        Assert-Check (@($run[0].Arguments | Where-Object { $_ -match '\.sh|bash|powershell' }).Count -eq 0) 'Test container must not need a shell script or PowerShell runtime.'
        Assert-Check ($script:Requests[-1].Arguments[0] -eq 'rm' -and $script:Requests[-1].Arguments[-1] -like 'grate-deb-lifecycle-*') 'Success/failure must remove the owned container.'
        $count++
    }
    Reset-Fake; $script:ChildTimedOut=$true; $errorRecord=$null
    try { Invoke-PackageLifecycle @parameters } catch { $errorRecord=$_ }
    Assert-Check ($errorRecord.Exception.Message -like '*exceeded 600s*' -and $script:Requests[-1].Arguments[0] -eq 'rm') 'Verifier timeout must fail and remove its container.'
    $count++
    Reset-Fake; $script:Architecture='x86_64'; $errorRecord=$null
    try { Invoke-PackageLifecycle @parameters } catch { $errorRecord=$_ }
    Assert-Check ($errorRecord.Exception.Message -like '*Expected native arm64*' -and $script:Requests.Count -eq 1) 'Architecture mismatch must prevent container creation.'
    $count++
} finally { Remove-Item -LiteralPath $directory -Recurse -Force }
Write-Host "PASS: $count Debian lifecycle orchestration and verifier scenarios."
