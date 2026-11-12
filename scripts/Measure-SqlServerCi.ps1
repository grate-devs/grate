#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [string]$OutputDirectory,
    [ValidateSet('Observer', 'Pooling')]
    [string]$Experiment = 'Observer',
    [ValidateRange(1, 10000)]
    [int]$ExpectedTests = 276,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$script:MeasurementDeadlineUtc = $null

function Get-MeasurementCommandTimeout {
    param(
        [int]$RequestedSeconds,
        [int]$CleanupTimeoutSeconds
    )

    if ($null -eq $script:MeasurementDeadlineUtc) {
        return $RequestedSeconds
    }
    # Reserve termination, two drain attempts, cancellation and asynchronous
    # disposal of both files within the 35m harness allowance. The 40m job
    # retains a further five minutes for sanitation and artifact upload.
    $remaining = [Math]::Floor(($script:MeasurementDeadlineUtc - [DateTimeOffset]::UtcNow).TotalSeconds) - (6 * $CleanupTimeoutSeconds)
    if ($remaining -le 0) {
        throw 'Measurement command budget exhausted; cleanup and export time remain reserved.'
    }
    return [int][Math]::Min($RequestedSeconds, $remaining)
}

function Invoke-CapturedCommand {
    param(
        [string]$Command,
        [string[]]$Arguments,
        [string]$LogDirectory,
        [int]$TimeoutSeconds = 300,
        [int]$CleanupTimeoutSeconds = 10
    )

    $TimeoutSeconds = Get-MeasurementCommandTimeout -RequestedSeconds $TimeoutSeconds -CleanupTimeoutSeconds $CleanupTimeoutSeconds
    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    $start = [Diagnostics.ProcessStartInfo]::new($Command)
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) {
        $start.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $stdout = [IO.File]::Create((Join-Path $LogDirectory 'stdout.log'))
    $stderr = [IO.File]::Create((Join-Path $LogDirectory 'stderr.log'))
    $cancellation = [Threading.CancellationTokenSource]::new()
    $copyOut = $null
    $copyError = $null
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        if (!$process.Start()) {
            throw "Could not start $Command."
        }
        # Drain both pipes concurrently to files so Trace output cannot fill a
        # pipe or expose disposable passwords to the unsanitized Actions console.
        $copyOut = $process.StandardOutput.BaseStream.CopyToAsync($stdout, $cancellation.Token)
        $copyError = $process.StandardError.BaseStream.CopyToAsync($stderr, $cancellation.Token)
        $terminated = $process.WaitForExit($TimeoutSeconds * 1000)
        $timedOut = !$terminated
        if ($timedOut) {
            $process.Kill($true)
            $terminated = $process.WaitForExit($CleanupTimeoutSeconds * 1000)
        }
        # Descendants can keep redirected handles open after the parent exits.
        # Bound termination and pipe draining independently of the test timeout.
        $drained = $false
        try {
            $drained = [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($copyOut, $copyError), $CleanupTimeoutSeconds * 1000)
        } catch {
            # I/O failures are command failures; do not expose raw exception text.
            $drained = $false
        }
        if (!$drained) {
            [void]$cancellation.CancelAsync().Wait($CleanupTimeoutSeconds * 1000)
            try {
                [void][Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($copyOut, $copyError), $CleanupTimeoutSeconds * 1000)
            } catch {
                # Cancellation is expected when a descendant holds a pipe open.
            }
        }
        $clock.Stop()
        $exitCode = if ($terminated) { $process.ExitCode } else { 124 }
        return [pscustomobject]@{
            ExitCode = $exitCode
            TimedOut = $timedOut
            Terminated = $terminated
            LogsDrained = $drained
            StopwatchSeconds = $clock.Elapsed.TotalSeconds
        }
    } finally {
        if (($null -eq $copyOut -or $copyOut.IsCompleted) -and ($null -eq $copyError -or $copyError.IsCompleted)) {
            $stdout.Dispose()
            $stderr.Dispose()
            $process.Dispose()
        } else {
            # Never synchronously dispose streams with pending pipe copies.
            # Bound asynchronous file cleanup too; this result is already failed.
            [void]$stdout.DisposeAsync().AsTask().Wait($CleanupTimeoutSeconds * 1000)
            [void]$stderr.DisposeAsync().AsTask().Wait($CleanupTimeoutSeconds * 1000)
        }
        $cancellation.Dispose()
    }
}

function Assert-CommandSucceeded {
    param(
        [object]$Result,
        [string]$Label
    )

    if ($Result.TimedOut -or !$Result.Terminated -or !$Result.LogsDrained -or $Result.ExitCode -ne 0) {
        throw "$Label failed (exit $($Result.ExitCode), timeout $($Result.TimedOut)); inspect sanitized command logs."
    }
}

function Get-CapturedText {
    param(
        [string]$Command,
        [string[]]$Arguments,
        [string]$LogDirectory
    )

    $result = Invoke-CapturedCommand -Command $Command -Arguments $Arguments -LogDirectory $LogDirectory
    Assert-CommandSucceeded -Result $result -Label $Command
    return (Get-Content -LiteralPath (Join-Path $LogDirectory 'stdout.log') -Raw).Trim()
}

function Get-MeasurementScenarios {
    param(
        [ValidateSet('Observer', 'Pooling')]
        [string]$Experiment
    )

    if ($Experiment -ceq 'Observer') {
        return @(
            @{ Name = 'OFF'; Profile = $false; Pooling = $false }
            @{ Name = 'ON'; Profile = $true; Pooling = $false }
        )
    }
    return @(
        @{ Name = 'BASELINE-1'; Profile = $true; Pooling = $false }
        @{ Name = 'CANDIDATE-1'; Profile = $true; Pooling = $true }
        @{ Name = 'CANDIDATE-2'; Profile = $true; Pooling = $true }
        @{ Name = 'BASELINE-2'; Profile = $true; Pooling = $false }
    )
}

function Read-MeasurementTrx {
    param(
        [string]$Path,
        [int]$ExpectedCount = 276
    )

    $document = [xml]::new()
    $document.XmlResolver = $null
    $document.Load($Path)
    $results = @($document.SelectNodes("/*[local-name()='TestRun']/*[local-name()='Results']/*[local-name()='UnitTestResult']"))
    $definitions = @($document.SelectNodes("/*[local-name()='TestRun']/*[local-name()='TestDefinitions']/*[local-name()='UnitTest']"))
    $counters = $document.SelectSingleNode("/*[local-name()='TestRun']/*[local-name()='ResultSummary']/*[local-name()='Counters']")
    if ($null -eq $counters -or $results.Count -ne $ExpectedCount -or $definitions.Count -ne $ExpectedCount -or $ExpectedCount -le 0) {
        throw "Expected exactly $ExpectedCount TRX test results."
    }
    foreach ($name in @('total', 'executed', 'passed')) {
        if ($counters.GetAttribute($name) -cne [string]$ExpectedCount) {
            throw "Unexpected TRX $name count."
        }
    }
    foreach ($attribute in $counters.Attributes) {
        if ($attribute.Name -cnotin @('total', 'executed', 'passed', 'completed') -and $attribute.Value -cne '0') {
            throw "TRX reports nonzero $($attribute.Name)."
        }
    }
    $byId = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    foreach ($definition in $definitions) {
        $id = $definition.GetAttribute('id')
        $method = $definition.SelectSingleNode("*[local-name()='TestMethod']")
        if ([string]::IsNullOrWhiteSpace($id) -or $byId.ContainsKey($id) -or $null -eq $method -or
            [string]::IsNullOrWhiteSpace($method.GetAttribute('className')) -or
            [string]::IsNullOrWhiteSpace($method.GetAttribute('name'))) {
            throw 'TRX has missing or duplicate test definitions.'
        }
        $byId.Add($id, $definition)
    }
    $names = [Collections.Generic.List[string]]::new()
    $identities = [Collections.Generic.List[string]]::new()
    $seenIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($result in $results) {
        if ($result.GetAttribute('outcome') -cne 'Passed' -or [string]::IsNullOrWhiteSpace($result.GetAttribute('testName'))) {
            throw 'TRX has a skipped, failed or unnamed result.'
        }
        $id = $result.GetAttribute('testId')
        if (!$byId.ContainsKey($id) -or !$seenIds.Add($id) -or $byId[$id].GetAttribute('name') -cne $result.GetAttribute('testName')) {
            throw 'TRX test result does not match a unique test definition.'
        }
        $method = $byId[$id].SelectSingleNode("*[local-name()='TestMethod']")
        $names.Add($result.GetAttribute('testName'))
        $identity = @($method.GetAttribute('className'), $method.GetAttribute('name'), $result.GetAttribute('testName'))
        $identities.Add((ConvertTo-Json -InputObject $identity -Compress))
    }
    $names.Sort([StringComparer]::Ordinal)
    $identities.Sort([StringComparer]::Ordinal)
    $times = $document.SelectSingleNode("/*[local-name()='TestRun']/*[local-name()='Times']")
    $start = [DateTimeOffset]::Parse($times.GetAttribute('start'), [Globalization.CultureInfo]::InvariantCulture)
    $finish = [DateTimeOffset]::Parse($times.GetAttribute('finish'), [Globalization.CultureInfo]::InvariantCulture)
    if ($finish -lt $start) {
        throw 'TRX finish precedes start.'
    }
    return [pscustomobject]@{
        Total = $results.Count
        Passed = $ExpectedCount
        Failed = 0
        Skipped = 0
        TrxWallSeconds = ($finish - $start).TotalSeconds
        Names = $names.ToArray()
        Identities = $identities.ToArray()
    }
}

function Assert-SameTestNames {
    param(
        [string[]]$First,
        [string[]]$Second
    )

    if ($First.Count -ne $Second.Count) {
        throw 'OFF and ON test-name multisets have different counts.'
    }
    for ($index = 0; $index -lt $First.Count; $index++) {
        if ($First[$index] -cne $Second[$index]) {
            throw 'OFF and ON test-name multisets differ before redaction.'
        }
    }
}

function Protect-MeasurementText {
    param(
        [string]$Text
    )

    # Quoted values may contain spaces/semicolons or doubled SQL quote escapes.
    $pattern = '(?i)(\b(?:Password|Pwd|MSSQL_SA_PASSWORD)\s*(?:=|:)\s*)(?:"(?:[^"\r\n]|"")*"|N?''(?:[^''\r\n]|'''')*''|[^;\r\n]+)'
    return [regex]::Replace($Text, $pattern, '${1}[REDACTED]')
}

function Protect-MeasurementJson {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($Value -is [string]) {
        return Protect-MeasurementText -Text $Value
    }
    if ($Value -is [Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $result[$key] = Protect-MeasurementJson -Value $Value[$key]
        }
        return $result
    }
    if ($Value -is [array]) {
        $result = [Collections.Generic.List[object]]::new()
        foreach ($item in $Value) {
            $result.Add((Protect-MeasurementJson -Value $item))
        }
        return ,$result.ToArray()
    }
    return $Value
}

function Export-SanitizedEvidence {
    param(
        [string]$Source,
        [string]$Destination
    )

    $invalidDocuments = [Collections.Generic.List[string]]::new()
    foreach ($file in Get-ChildItem -LiteralPath $Source -Recurse -File) {
        # No binary coverage dumps, memory dumps, or arbitrary attachments.
        if ($file.Extension -cnotin @('.trx', '.xml', '.json', '.txt', '.log', '.md')) {
            continue
        }
        $relative = [IO.Path]::GetRelativePath($Source, $file.FullName)
        $target = Join-Path $Destination $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        try {
            if ($file.Extension -cin @('.xml', '.trx')) {
                $document = [xml]::new()
                $document.XmlResolver = $null
                $document.PreserveWhitespace = $true
                $document.Load($file.FullName)
                # Redact decoded XML values, never markup. [REDACTED] is ordinary text.
                foreach ($node in $document.SelectNodes('//@* | //text() | //comment() | //processing-instruction()')) {
                    $node.Value = Protect-MeasurementText -Text $node.Value
                }
                $document.Save($target)
            } elseif ($file.Extension -ceq '.json') {
                $value = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -AsHashtable
                ConvertTo-Json -InputObject (Protect-MeasurementJson -Value $value) -Depth 30 |
                    Set-Content -LiteralPath $target -Encoding utf8NoBOM
            } else {
                $content = Get-Content -LiteralPath $file.FullName -Raw
                Set-Content -LiteralPath $target -Value (Protect-MeasurementText -Text $content) -Encoding utf8NoBOM
            }
        } catch {
            # Interrupted runs can leave truncated XML/JSON. Keep processing
            # other evidence, but never upload an unparsed document or exception.
            $invalidDocuments.Add($relative)
        }
    }
    if ($invalidDocuments.Count -gt 0) {
        ConvertTo-Json -InputObject $invalidDocuments.ToArray() |
            Set-Content -LiteralPath (Join-Path $Destination 'excluded-invalid-documents.json') -Encoding utf8NoBOM
        throw 'Incomplete documents were excluded during sanitation; remaining sanitized evidence was retained.'
    }
}

function Read-MeasurementProfile {
    param(
        [string]$Path
    )

    $profile = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($profile.SchemaVersion -ne 1 -or $profile.Errors -ne 0 -or $profile.Incomplete -ne $false -or
        $profile.ListenerCount -lt 1 -or $profile.BuildConfiguration -cne 'Debug' -or
        $profile.ProcessArchitecture -cne 'X64' -or $profile.RuntimeVersion -notlike '11.0.*' -or
        $profile.Data.Errors -ne 0 -or $profile.Data.PendingOperations -ne 0 -or
        $profile.Data.SuccessfulLogicalOpens -le 0 -or @($profile.Data.Aggregates).Count -eq 0) {
        throw 'Profiler evidence is incomplete, unhealthy, or from the wrong runtime/build.'
    }
    foreach ($operation in @('Open', 'Command')) {
        $started = ($profile.Data.Aggregates | Where-Object Operation -CEQ $operation | Measure-Object Started -Sum).Sum
        if ($started -le 0) {
            throw "Profiler did not observe $operation operations."
        }
    }
    foreach ($row in $profile.Data.Aggregates) {
        if ($row.Started -ne ($row.Succeeded + $row.Failed) -or $row.Started -lt 0 -or $row.Succeeded -lt 0 -or $row.Failed -lt 0 -or
            $row.ProviderDuplicateErrors -lt 0 -or $row.ProviderDuplicateErrors -gt $row.Failed -or
            ($row.Operation -cne 'Open' -and $row.ProviderDuplicateErrors -ne 0)) {
            throw 'Profiler operation start/terminal totals do not match.'
        }
    }
    $attributed = @($profile.Data.Aggregates | Where-Object {
        $_.Scope -ceq 'test' -and $_.CaseId -cmatch '^[a-fA-F0-9]{64}$' -and
        ![string]::IsNullOrWhiteSpace($_.ClassName) -and ![string]::IsNullOrWhiteSpace($_.MethodName)
    })
    if ($attributed.Count -eq 0) {
        throw 'Profiler did not attribute observed work to any test case.'
    }
    $logicalOpens = ($profile.Data.Aggregates | Where-Object Operation -CEQ 'Open' | Measure-Object Succeeded -Sum).Sum
    if ($logicalOpens -ne $profile.Data.SuccessfulLogicalOpens) {
        throw 'Profiler successful-open total does not match aggregate rows.'
    }
    $logicalOperations = ($profile.Data.Aggregates | Measure-Object Started -Sum).Sum
    $providerDuplicates = ($profile.Data.Aggregates | Measure-Object ProviderDuplicateErrors -Sum).Sum
    if ($profile.Data.KnownDuplicateAsyncOpenErrors -lt 0 -or
        $providerDuplicates -ne $profile.Data.KnownDuplicateAsyncOpenErrors -or
        $profile.Data.BeforeCallbacks -ne $logicalOperations -or
        $profile.Data.TerminalCallbacks -ne ($logicalOperations + $providerDuplicates) -or
        $profile.Data.Callbacks -ne ($profile.Data.BeforeCallbacks + $profile.Data.TerminalCallbacks)) {
        throw 'Raw profiler callbacks, logical operations and explicit provider duplicates do not reconcile.'
    }
    return $profile
}

function Invoke-MeasurementSelfTest {
    $temporary = Join-Path ([IO.Path]::GetTempPath()) ('sqlserver-measure-controls-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $temporary | Out-Null
    try {
        $observerScenarios = @(Get-MeasurementScenarios -Experiment Observer)
        if (($observerScenarios.Name -join '|') -cne 'OFF|ON' -or
            $observerScenarios[0].Profile -or !$observerScenarios[1].Profile -or
            @($observerScenarios | Where-Object Pooling).Count -ne 0) {
            throw 'Observer comparison must vary profiling only, with pooling disabled throughout.'
        }
        $poolingScenarios = @(Get-MeasurementScenarios -Experiment Pooling)
        if (($poolingScenarios.Name -join '|') -cne 'BASELINE-1|CANDIDATE-1|CANDIDATE-2|BASELINE-2' -or
            @($poolingScenarios | Where-Object { !$_.Profile }).Count -ne 0 -or
            $poolingScenarios[0].Pooling -or !$poolingScenarios[1].Pooling -or
            !$poolingScenarios[2].Pooling -or $poolingScenarios[3].Pooling) {
            throw 'Pooling comparison must preserve the observer and vary pooling in ABBA order.'
        }
        $profileFixture = @{
            SchemaVersion = 1
            Errors = 0
            Incomplete = $false
            ListenerCount = 1
            BuildConfiguration = 'Debug'
            ProcessArchitecture = 'X64'
            RuntimeVersion = '11.0.0'
            Data = @{
                Errors = 0
                PendingOperations = 0
                SuccessfulLogicalOpens = 1
                KnownDuplicateAsyncOpenErrors = 1
                BeforeCallbacks = 3
                TerminalCallbacks = 4
                Callbacks = 7
                Aggregates = @(
                    @{
                        Operation = 'Open'
                        Started = 2
                        Succeeded = 1
                        Failed = 1
                        ProviderDuplicateErrors = 1
                        Scope = 'test'
                        CaseId = ('A' * 64)
                        ClassName = 'Fixture'
                        MethodName = 'Control'
                    }
                    @{
                        Operation = 'Command'
                        Started = 1
                        Succeeded = 1
                        Failed = 0
                        ProviderDuplicateErrors = 0
                        Scope = 'fixture-between-teardown'
                        CaseId = $null
                        ClassName = $null
                        MethodName = $null
                    }
                )
            }
        }
        $fixtureJson = $profileFixture | ConvertTo-Json -Depth 8
        $fixturePath = Join-Path $temporary 'profile-fixture.json'
        Set-Content -LiteralPath $fixturePath -Value $fixtureJson
        Read-MeasurementProfile -Path $fixturePath | Out-Null
        foreach ($mutate in @(
            { param($value) $value.Errors = 1 }
            { param($value) $value.Incomplete = $true }
            { param($value) $value.Data.TerminalCallbacks = 3 }
            { param($value) $value.Data.KnownDuplicateAsyncOpenErrors = 0 }
            { param($value) $value.Data.Aggregates[0].ProviderDuplicateErrors = 0 }
            { param($value) $value.Data.Aggregates[1].ProviderDuplicateErrors = 1 }
            { param($value) $value.Data.Callbacks = 6 }
        )) {
            $value = $fixtureJson | ConvertFrom-Json -AsHashtable
            & $mutate $value
            $value | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $fixturePath
            $rejected = $false
            try {
                Read-MeasurementProfile -Path $fixturePath | Out-Null
            } catch {
                $rejected = $true
            }
            if (!$rejected) {
                throw 'An invalid profile callback/duplicate reconciliation was accepted.'
            }
        }
        try {
            $script:MeasurementDeadlineUtc = [DateTimeOffset]::UtcNow.AddSeconds(70)
            $bounded = Get-MeasurementCommandTimeout -RequestedSeconds 300 -CleanupTimeoutSeconds 10
            if ($bounded -gt 10 -or $bounded -lt 1) {
                throw 'Short remaining command allowance did not reserve cleanup time.'
            }
            $script:MeasurementDeadlineUtc = [DateTimeOffset]::UtcNow.AddSeconds(-1)
            $rejected = $false
            try {
                Get-MeasurementCommandTimeout -RequestedSeconds 300 -CleanupTimeoutSeconds 10 | Out-Null
            } catch {
                $rejected = $true
            }
            if (!$rejected) {
                throw 'An exhausted overall command budget was accepted.'
            }
        } finally {
            $script:MeasurementDeadlineUtc = $null
        }
        $failure = Invoke-CapturedCommand -Command (Get-Process -Id $PID).Path -Arguments @('-NoProfile', '-Command', 'exit 7') -LogDirectory "$temporary/native"
        $rejected = $false
        try {
            Assert-CommandSucceeded -Result $failure -Label 'fixture'
        } catch {
            $rejected = $true
        }
        if (!$rejected -or $failure.ExitCode -ne 7) {
            throw 'Native command failure was not preserved.'
        }
        $timeout = Invoke-CapturedCommand -Command (Get-Process -Id $PID).Path -Arguments @('-NoProfile', '-Command', 'Start-Sleep -Seconds 10') -LogDirectory "$temporary/timeout" -TimeoutSeconds 1
        if (!$timeout.TimedOut -or !$timeout.Terminated) {
            throw 'Native command timeout was not preserved.'
        }
        $parentCommand = @'
$start = [Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
$start.UseShellExecute = $false
$start.ArgumentList.Add('-NoProfile')
$start.ArgumentList.Add('-Command')
$start.ArgumentList.Add('Start-Sleep -Seconds 20')
$child = [Diagnostics.Process]::Start($start)
[IO.File]::WriteAllText('__CHILD_PID_PATH__', [string]$child.Id)
'@
        $childPidPath = "$temporary/child.pid"
        $parentCommand = $parentCommand.Replace('__CHILD_PID_PATH__', $childPidPath.Replace("'", "''"))
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($parentCommand))
        try {
            $heldPipe = Invoke-CapturedCommand -Command (Get-Process -Id $PID).Path -Arguments @('-NoProfile', '-EncodedCommand', $encoded) -LogDirectory "$temporary/held-pipe" -TimeoutSeconds 10 -CleanupTimeoutSeconds 1
            if ($heldPipe.ExitCode -ne 0 -or $heldPipe.TimedOut -or !$heldPipe.Terminated -or
                $heldPipe.LogsDrained -or $heldPipe.StopwatchSeconds -gt 8 -or !(Test-Path -LiteralPath $childPidPath)) {
                throw 'A descendant-held output pipe was not rejected within the cleanup budget.'
            }
        } finally {
            if (Test-Path -LiteralPath $childPidPath) {
                $childId = [int](Get-Content -LiteralPath $childPidPath -Raw)
                $child = Get-Process -Id $childId -ErrorAction SilentlyContinue
                if ($null -ne $child) {
                    $child.Kill()
                    [void]$child.WaitForExit(2000)
                    $child.Dispose()
                }
            }
        }
        $template = @'
<TestRun xmlns="http://microsoft.com/schemas/VisualStudio/TeamTest/2010">
<Times start="2026-11-12T00:00:00Z" finish="2026-11-12T00:00:02Z"/>
<Results><UnitTestResult testId="1" testName="case A" outcome="Passed"/><UnitTestResult testId="2" testName="case A" outcome="Passed"/></Results>
<TestDefinitions><UnitTest id="1" name="case A"><TestMethod className="Fixture.Class" name="Method"/></UnitTest><UnitTest id="2" name="case A"><TestMethod className="Fixture.Class" name="Method"/></UnitTest></TestDefinitions>
<ResultSummary><Counters total="2" executed="2" passed="2" failed="0" notExecuted="0"/></ResultSummary>
<Output><StdOut>Password=&quot;secret; space&quot;; Pwd='secret two'; MSSQL_SA_PASSWORD=secret3; CREATE LOGIN x WITH PASSWORD = N'secret&lt;&amp;four';</StdOut></Output>
</TestRun>
'@
        Set-Content -LiteralPath "$temporary/valid.trx" -Value $template
        @{ Items = @('Password="secret; space"', "PWD='secret two'"); Count = 2 } |
            ConvertTo-Json | Set-Content -LiteralPath "$temporary/values.json"
        $valid = Read-MeasurementTrx -Path "$temporary/valid.trx" -ExpectedCount 2
        Assert-SameTestNames -First $valid.Names -Second @('case A', 'case A')
        foreach ($mutation in @(
            $template.Replace('outcome="Passed"', 'outcome="NotExecuted"'),
            $template.Replace('passed="2"', 'passed="0"'),
            $template.Replace('failed="0"', 'failed="1"'),
            [regex]::Replace($template, '<UnitTestResult[^>]+/>', ''),
            $template.Replace('testId="2"', 'testId="1"'),
            $template.Replace('className="Fixture.Class"', 'className=""')
        )) {
            Set-Content -LiteralPath "$temporary/invalid.trx" -Value $mutation
            $rejected = $false
            try {
                Read-MeasurementTrx -Path "$temporary/invalid.trx" -ExpectedCount 2 | Out-Null
            } catch {
                $rejected = $true
            }
            if (!$rejected) {
                throw 'Invalid TRX was accepted.'
            }
        }
        $rejected = $false
        try {
            Assert-SameTestNames -First $valid.Names -Second @('case A', 'case B')
        } catch {
            $rejected = $true
        }
        if (!$rejected) {
            throw 'Different test-name multiplicity was accepted.'
        }
        Set-Content -LiteralPath "$temporary/changed.trx" -Value $template.Replace('Fixture.Class', 'Another.Class')
        $changed = Read-MeasurementTrx -Path "$temporary/changed.trx" -ExpectedCount 2
        $rejected = $false
        try {
            Assert-SameTestNames -First $valid.Identities -Second $changed.Identities
        } catch {
            $rejected = $true
        }
        if (!$rejected) {
            throw 'Changed class identity with identical display names was accepted.'
        }
        Remove-Item -LiteralPath "$temporary/invalid.trx"
        $export = "$temporary-export"
        Export-SanitizedEvidence -Source $temporary -Destination $export
        try {
            $clean = Get-Content -LiteralPath "$export/valid.trx" -Raw
            if ($clean.Contains('secret') -or ([regex]::Matches($clean, '\[REDACTED\]')).Count -ne 4) {
                throw 'Credential redaction failed.'
            }
            $sanitized = Read-MeasurementTrx -Path "$export/valid.trx" -ExpectedCount 2
            Assert-SameTestNames -First $valid.Names -Second $sanitized.Names
            Assert-SameTestNames -First $valid.Identities -Second $sanitized.Identities
            if ($sanitized.TrxWallSeconds -ne 2) {
                throw 'Sanitation changed TRX timing.'
            }
            $json = Get-Content -LiteralPath "$export/values.json" -Raw
            $decoded = $json | ConvertFrom-Json
            if ($json.Contains('secret') -or $decoded.Items.Count -ne 2 -or $decoded.Count -ne 2) {
                throw 'JSON redaction changed structure or leaked credentials.'
            }
            Set-Content -LiteralPath "$temporary/interrupted.xml" -Value '<incomplete>'
            $rejected = $false
            try {
                Export-SanitizedEvidence -Source $temporary -Destination $export
            } catch {
                $rejected = $true
            }
            if (!$rejected -or !(Test-Path -LiteralPath "$export/excluded-invalid-documents.json") -or
                !(Test-Path -LiteralPath "$export/valid.trx") -or (Test-Path -LiteralPath "$export/interrupted.xml")) {
                throw 'Interrupted XML was not safely excluded while retaining valid evidence.'
            }
        } finally {
            Remove-Item -LiteralPath $export -Recurse -Force
        }
        Write-Host 'PASS: overall command budget, native failure/timeout/descendant-held-pipe bounds, failed/skipped/zero/missing results, exact class/method/name identity and duplicate-name inventory, XML/JSON sanitation, and interrupted evidence controls.'
    } finally {
        Remove-Item -LiteralPath $temporary -Recurse -Force
    }
}

if ($SelfTest) {
    Invoke-MeasurementSelfTest
    return
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    throw 'Specify a fresh -OutputDirectory, or use -SelfTest for harness controls.'
}
if (!$IsLinux -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne [Runtime.InteropServices.Architecture]::X64 -or
    [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -ne [Runtime.InteropServices.Architecture]::X64) {
    throw 'Measurement requires native Linux x64; emulation is not comparable.'
}
# Configuration binds environment names case-insensitively. Even an empty
# external connection setting selects the external fixture, so reject its presence.
foreach ($variable in Get-ChildItem Env:) {
    if ($variable.Name -ieq 'GrateTestConfig__AdminConnectionString' -or $variable.Name -ieq 'GrateTestConfig:AdminConnectionString') {
        throw 'Refusing external AdminConnectionString; this experiment requires disposable fixture containers.'
    }
}

$repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$output = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $output) {
    throw 'Measurement output must be a fresh directory.'
}
New-Item -ItemType Directory -Path $output | Out-Null
$raw = Join-Path ([IO.Path]::GetTempPath()) ('sqlserver-measure-raw-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $raw | Out-Null
$environmentNames = @('GrateTestConfig__DockerImage', 'GRATE_SQLSERVER_PROFILE_OUTPUT', 'GRATE_SQLSERVER_SCOPED_POOLING', 'GRATE_REPRODUCIBLE_TABLE_CASINGS', 'LogLevel', 'TZ')
$savedEnvironment = @{}
foreach ($name in $environmentNames) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
}
$runs = [Collections.Generic.List[object]]::new()
$inventories = [Collections.Generic.List[object]]::new()
$profileSummary = @()
$design = if ($Experiment -ceq 'Observer') {
    'One sequential observer OFF/ON pair; fresh fixture containers; no optimization claim or noise estimate.'
} else {
    'Two baseline/candidate comparisons in ABBA order; observer ON throughout; same prepared binary and fresh fixture containers.'
}
$status = 'incomplete'
$script:MeasurementDeadlineUtc = [DateTimeOffset]::UtcNow.AddMinutes(35)
Push-Location $repository
try {
    $source = Get-CapturedText -Command 'git' -Arguments @('rev-parse', 'HEAD') -LogDirectory "$raw/preparation/git"
    $sdk = Get-CapturedText -Command 'dotnet' -Arguments @('--version') -LogDirectory "$raw/preparation/dotnet-version"
    $sdks = Get-CapturedText -Command 'dotnet' -Arguments @('--list-sdks') -LogDirectory "$raw/preparation/sdks"
    $runtimes = Get-CapturedText -Command 'dotnet' -Arguments @('--list-runtimes') -LogDirectory "$raw/preparation/runtimes"
    $cpu = Get-CapturedText -Command 'lscpu' -Arguments @('--json') -LogDirectory "$raw/preparation/cpu"
    $os = Get-Content -LiteralPath '/etc/os-release' -Raw
    $memory = Get-Content -LiteralPath '/proc/meminfo' -Raw
    $kernel = Get-CapturedText -Command 'uname' -Arguments @('-a') -LogDirectory "$raw/preparation/kernel"
    $docker = Get-CapturedText -Command 'docker' -Arguments @('version', '--format', '{{json .}}') -LogDirectory "$raw/preparation/docker-version"
    Write-Host 'Pulling SQL Server before timing and binding both runs to one RepoDigest.'
    $pull = Invoke-CapturedCommand -Command 'docker' -Arguments @('pull', '--platform', 'linux/amd64', 'mcr.microsoft.com/mssql/server:2022-latest') -LogDirectory "$raw/preparation/image-pull" -TimeoutSeconds 600
    Assert-CommandSucceeded -Result $pull -Label 'SQL Server image pull'
    # Select image identity only; a full inspect includes environment values.
    $imageFormat = '{"RepoDigests":{{json .RepoDigests}},"Id":{{json .Id}},"Architecture":{{json .Architecture}},"Os":{{json .Os}}}'
    $imageJson = Get-CapturedText -Command 'docker' -Arguments @('image', 'inspect', 'mcr.microsoft.com/mssql/server:2022-latest', '--format', $imageFormat) -LogDirectory "$raw/preparation/image-inspect"
    $image = $imageJson | ConvertFrom-Json
    $digests = @($image.RepoDigests | Where-Object { $_ -cmatch '^mcr\.microsoft\.com/mssql/server@sha256:[a-f0-9]{64}$' })
    if ($digests.Count -ne 1 -or $image.Architecture -cne 'amd64' -or $image.Os -cne 'linux') {
        throw 'Expected one exact Linux amd64 SQL Server RepoDigest.'
    }
    $digest = $digests[0]
    $metadata = [ordered]@{
        SchemaVersion = 1
        SourceRevision = $source
        GitHubRunId = $env:GITHUB_RUN_ID
        GitHubRunAttempt = $env:GITHUB_RUN_ATTEMPT
        RecordedUtc = [DateTimeOffset]::UtcNow
        OS = $os
        Kernel = $kernel
        Cpu = $cpu | ConvertFrom-Json
        Memory = $memory
        SelectedSdk = $sdk
        InstalledSdks = $sdks
        Runtimes = $runtimes
        DockerVersion = $docker | ConvertFrom-Json
        Image = @{ RepoDigest = $digest; Id = $image.Id; Architecture = $image.Architecture; OS = $image.Os }
        Configuration = 'Debug'
        Framework = 'net11.0'
        BuildFrameworks = @('net8.0', 'net9.0', 'net10.0', 'net11.0')
        LogLevel = 'Trace'
        ReproducibleTableCasings = $true
        ExpectedTests = $ExpectedTests
        Experiment = $Experiment
        Design = $design
    }
    $metadata | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath "$raw/metadata.json" -Encoding utf8NoBOM

    $project = Join-Path $repository 'unittests/SqlServer/SqlServer.csproj'
    $frameworks = Get-CapturedText -Command 'dotnet' -Arguments @('msbuild', $project, '-nologo', '-getProperty:TargetFrameworks') -LogDirectory "$raw/preparation/frameworks"
    if ($frameworks -cne 'net8.0;net9.0;net10.0;net11.0') {
        throw 'Expected all four supported SQL Server target frameworks.'
    }
    Write-Host 'Building the SQL Server Debug project for all four TFMs outside the measurement.'
    $build = Invoke-CapturedCommand -Command 'dotnet' -Arguments @('build', $project, '--configuration', 'Debug') -LogDirectory "$raw/preparation/build" -TimeoutSeconds 600
    Assert-CommandSucceeded -Result $build -Label 'Four-TFM Debug build'
    $assembly = Join-Path $repository 'unittests/SqlServer/bin/Debug/net11.0/SqlServer.dll'
    $assemblyHash = (Get-FileHash -LiteralPath $assembly -Algorithm SHA256).Hash
    $env:GrateTestConfig__DockerImage = $digest
    $env:GRATE_REPRODUCIBLE_TABLE_CASINGS = 'true'
    $env:LogLevel = 'Trace'
    $env:TZ = 'UTC'
    $scenarios = @(Get-MeasurementScenarios -Experiment $Experiment)
    foreach ($scenario in $scenarios) {
        $observer = $scenario.Name
        $directory = "$raw/runs/$observer"
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $env:GRATE_SQLSERVER_PROFILE_OUTPUT = if ($scenario.Profile) { "$directory/sqlclient-profile.json" } else { $null }
        $env:GRATE_SQLSERVER_SCOPED_POOLING = if ($scenario.Pooling) { 'true' } else { 'false' }
        $arguments = @(
            'test', '--project', $project, '--framework', 'net11.0',
            '--no-build', '--no-restore', '--max-parallel-test-modules', '1',
            '--minimum-expected-tests', [string]$ExpectedTests, '--stop-on-fail', 'on',
            '--long-running', '60', '--timeout', '12m',
            '--report-xunit-trx', '--coverage', '--coverage-output-format', 'xml',
            '--results-directory', "$directory/results"
        )
        Write-Host "Running $observer ($ExpectedTests cases, coverage and Trace logging)."
        $command = Invoke-CapturedCommand -Command 'dotnet' -Arguments $arguments -LogDirectory "$directory/command" -TimeoutSeconds 840
        $run = [ordered]@{
            Observer = $observer
            Arguments = $arguments
            ExitCode = $command.ExitCode
            TimedOut = $command.TimedOut
            Terminated = $command.Terminated
            LogsDrained = $command.LogsDrained
            StopwatchSeconds = $command.StopwatchSeconds
            AssemblySha256 = $assemblyHash
            ProfilerOutputEnabled = $scenario.Profile
            ScopedPooling = $scenario.Pooling
        }
        $runs.Add($run)
        Assert-CommandSucceeded -Result $command -Label "Observer $observer"
        if ((Get-FileHash -LiteralPath $assembly -Algorithm SHA256).Hash -cne $assemblyHash) {
            throw 'Prepared test binary changed during measurement.'
        }
        $trxFiles = @(Get-ChildItem -LiteralPath "$directory/results" -Recurse -Filter '*.trx' -File)
        if ($trxFiles.Count -ne 1) {
            throw "Observer $observer must emit exactly one TRX file."
        }
        $counts = Read-MeasurementTrx -Path $trxFiles[0].FullName -ExpectedCount $ExpectedTests
        $inventories.Add($counts)
        if ($inventories.Count -gt 1) {
            Assert-SameTestNames -First $inventories[0].Names -Second $counts.Names
            Assert-SameTestNames -First $inventories[0].Identities -Second $counts.Identities
        }
        $run.TrxWallSeconds = $counts.TrxWallSeconds
        $run.Total = $counts.Total
        $run.Passed = $counts.Passed
        $run.Failed = $counts.Failed
        $run.Skipped = $counts.Skipped
        $run.TestNames = $counts.Names
        # Export decoded identity fields so redaction never has to interpret
        # JSON serialized inside another JSON string.
        $run.TestIdentities = @($counts.Identities | ForEach-Object {
            $parts = ConvertFrom-Json -InputObject $_
            [pscustomobject]@{
                ClassName = $parts[0]
                MethodName = $parts[1]
                DisplayName = $parts[2]
            }
        })
        $coverage = @(Get-ChildItem -LiteralPath "$directory/results" -Recurse -Filter '*.xml' -File | Where-Object {
            $xml = [xml]::new()
            $xml.XmlResolver = $null
            $xml.Load($_.FullName)
            $xml.DocumentElement.LocalName -cin @('results', 'coverage')
        })
        if ($coverage.Count -eq 0) {
            throw "Observer $observer did not emit XML coverage."
        }
        $run.CoverageFiles = @($coverage | ForEach-Object { [IO.Path]::GetRelativePath($raw, $_.FullName) })
        if ($scenario.Profile) {
            $profile = Read-MeasurementProfile -Path "$directory/sqlclient-profile.json"
            $run.ObserverMilliseconds = $profile.Data.ObserverMilliseconds
            $run.SuccessfulLogicalOpens = $profile.Data.SuccessfulLogicalOpens
            $run.DistinctOpenConnectionIds = $profile.Data.DistinctOpenConnectionIds
            $run.KnownDuplicateAsyncOpenErrors = $profile.Data.KnownDuplicateAsyncOpenErrors
            $run.RawCallbacks = $profile.Data.Callbacks
            $profileSummary += @($profile.Data.Aggregates | Group-Object Operation, BatchCategory | ForEach-Object {
                [pscustomobject]@{
                    Scenario = $observer
                    Operation = $_.Group[0].Operation
                    BatchCategory = $_.Group[0].BatchCategory
                    Started = ($_.Group | Measure-Object Started -Sum).Sum
                    Succeeded = ($_.Group | Measure-Object Succeeded -Sum).Sum
                    Failed = ($_.Group | Measure-Object Failed -Sum).Sum
                    Milliseconds = ($_.Group | Measure-Object Milliseconds -Sum).Sum
                }
            } | Sort-Object Milliseconds -Descending)
        }
        Write-Host ("Observer {0}: {1} passed, Stopwatch {2:N3}s, TRX {3:N3}s." -f $observer, $counts.Passed, $command.StopwatchSeconds, $counts.TrxWallSeconds)
    }
    $status = 'complete'
} finally {
    try {
        [ordered]@{
            SchemaVersion = 1
            Status = $status
            Experiment = $Experiment
            ExactRawTestNameMultisetMatches = ($status -ceq 'complete')
            Runs = $runs.ToArray()
            ProfileSummary = $profileSummary
            Interpretation = "$design Selected net11 measurements do not replace full four-TFM CI."
        } | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath "$raw/measurement.json" -Encoding utf8NoBOM
        $report = [Collections.Generic.List[string]]::new()
        $report.Add('# SQL Server CI measurement')
        $report.Add('')
        $report.Add("Status: $status. $design")
        $report.Add('')
        $report.Add('| Scenario | Stopwatch seconds | TRX seconds | Passed | Failed | Skipped | Exit |')
        $report.Add('| --- | ---: | ---: | ---: | ---: | ---: | ---: |')
        foreach ($run in $runs) {
            $trxSeconds = '-'
            $passed = '-'
            $failed = '-'
            $skipped = '-'
            if ($run.Contains('TrxWallSeconds')) {
                $trxSeconds = '{0:F3}' -f $run.TrxWallSeconds
                $passed = $run.Passed
                $failed = $run.Failed
                $skipped = $run.Skipped
            }
            $report.Add(("| {0} | {1:F3} | {2} | {3} | {4} | {5} | {6} |" -f $run.Observer, $run.StopwatchSeconds, $trxSeconds, $passed, $failed, $skipped, $run.ExitCode))
        }
        $report.Add('')
        $report.Add('Runs use the same prepared Debug/net11 binary, pinned SQL Server RepoDigest, fixed table casing, Trace logging, XML coverage and fresh fixture containers. Exact raw sorted display-name and class/method/name multisets are compared before identity redaction. Full four-TFM CI remains required.')
        if ($profileSummary.Count -gt 0) {
            $report.Add('')
            $report.Add('| Scenario | SQL Client operation | Batch category | Started | Succeeded | Failed | Summed interval ms |')
            $report.Add('| --- | --- | --- | ---: | ---: | ---: | ---: |')
            foreach ($row in $profileSummary) {
                $report.Add(("| {0} | {1} | {2} | {3} | {4} | {5} | {6:F3} |" -f $row.Scenario, $row.Operation, $row.BatchCategory, $row.Started, $row.Succeeded, $row.Failed, $row.Milliseconds))
            }
            $report.Add('')
            $report.Add('Intervals include client work and waits between callbacks; sums are not server CPU or elapsed wall time. Expected SQL failures remain visible. Distinct connection IDs are reuse hints, not login counts. Per-test/method and fixture attribution is retained in each profiled scenario directory.')
        }
        $report | Set-Content -LiteralPath "$raw/report.md" -Encoding utf8NoBOM
        Export-SanitizedEvidence -Source $raw -Destination $output
        Write-Host "Sanitized evidence retained in $output."
    } finally {
        foreach ($name in $environmentNames) {
            [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name])
        }
        Pop-Location
        Remove-Item -LiteralPath $raw -Recurse -Force
    }
}
