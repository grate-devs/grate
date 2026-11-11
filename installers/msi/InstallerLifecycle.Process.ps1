function Invoke-InstallerLifecycleProcess {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [string[]]$Arguments,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$OutputDirectory,
        [int[]]$AllowedExitCodes = @(0),
        [ValidateRange(1, 180000)][int]$TimeoutMilliseconds = 180000,
        [ValidateRange(1, 5000)][int]$DrainTimeoutMilliseconds = 5000
    )

    $start = [Diagnostics.ProcessStartInfo]::new($Executable)
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) {
        $start.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $started = $false
    $command = [ordered]@{
        executable = $Executable
        arguments = $Arguments
        startedUtc = [DateTime]::UtcNow.ToString('o')
        state = 'Starting'
        exitCode = $null
        timedOut = $false
        streamDrainFailure = $null
    }
    $commandPath = Join-Path $OutputDirectory "$Name.command.json"
    $command | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $commandPath

    function Write-CommandPhase {
        param(
            [string]$Phase
        )
        $command.phase = $Phase
        $command | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $commandPath
        @{
            Phase = $Phase
            Utc = [DateTime]::UtcNow.ToString('o')
        } | ConvertTo-Json -Compress | Add-Content -LiteralPath (Join-Path $OutputDirectory "$Name.process-phases.jsonl")
    }

    try {
        Write-CommandPhase 'BeforeStart'
        [void]$process.Start()
        $started = $true
        $command.processId = $process.Id
        $command.state = 'Running'
        $command | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $commandPath
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        Write-CommandPhase 'BeforeWait'
        $command.timedOut = !$process.WaitForExit($TimeoutMilliseconds)
        Write-CommandPhase 'AfterWait'
        if ($command.timedOut) {
            # The CI VM is disposable. Avoid potentially blocking process-tree
            # enumeration; the outer supervisor also bounds the whole harness.
            Write-CommandPhase 'BeforeKill'
            $process.Kill()
            Write-CommandPhase 'AfterKill'
            Write-CommandPhase 'BeforeTerminationWait'
            $terminated = $process.WaitForExit(10000)
            Write-CommandPhase 'AfterTerminationWait'
            if (!$terminated) {
                throw "$Name did not terminate within ten seconds. See $OutputDirectory."
            }
        }

        try {
            # Descendants and Windows Installer services can retain inherited
            # pipe handles after the process exits. Process timeout is not enough.
            Write-CommandPhase 'BeforeDrain'
            [void][Threading.Tasks.Task]::WhenAll([Threading.Tasks.Task[]]@($stdout, $stderr)).WaitAsync(
                [TimeSpan]::FromMilliseconds($DrainTimeoutMilliseconds)).GetAwaiter().GetResult()
        }
        catch {
            $command.streamDrainFailure = $_.Exception.Message
        }
        Write-CommandPhase 'AfterDrain'

        $output = if ($stdout.IsCompletedSuccessfully) {
            $stdout.GetAwaiter().GetResult()
        }
        else {
            '[stdout drain did not complete successfully]'
        }
        $errorOutput = if ($stderr.IsCompletedSuccessfully) {
            $stderr.GetAwaiter().GetResult()
        }
        else {
            '[stderr drain did not complete successfully]'
        }
        ($output + $errorOutput) | Set-Content -LiteralPath (Join-Path $OutputDirectory "$Name.output.log")

        if ($command.timedOut) {
            throw "$Name exceeded its process timeout. See $OutputDirectory."
        }
        if ($command.streamDrainFailure) {
            throw "$Name output drain failed or exceeded its timeout. See $OutputDirectory."
        }
        if ($process.ExitCode -notin $AllowedExitCodes) {
            throw "$Name failed with exit code $($process.ExitCode). See $OutputDirectory."
        }
        $command.state = 'Completed'
    }
    catch {
        $command.state = 'Failed'
        $command.error = $_.Exception.Message
        throw
    }
    finally {
        if ($started -and $process.HasExited) {
            $command.exitCode = $process.ExitCode
        }
        Write-CommandPhase 'BeforeDispose'
        $process.Dispose()
        $command.completedUtc = [DateTime]::UtcNow.ToString('o')
        Write-CommandPhase 'AfterDispose'
    }
}
