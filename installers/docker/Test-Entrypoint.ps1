#!/usr/bin/env pwsh
<#
Verify a locally built image through its default entrypoint, without publishing it.
Requires Docker and sqlite3 on the host; the candidate image needs no test tools.
#>
param(
    [Parameter(Mandatory)][string]$Image,
    [Parameter(Mandatory)][string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
$completed = [Collections.Generic.List[string]]::new()
$summary = [ordered]@{ requested_image = $Image; entrypoint = 'image default' }
$state = Join-Path ([IO.Path]::GetTempPath()) "grate-entrypoint-$([guid]::NewGuid().ToString('N'))"

function Invoke-TestProcess([string]$Executable, [string[]]$Arguments, [string]$Name, [int]$TimeoutSeconds = 60) {
    $log = Join-Path $OutputDirectory "$Name.log"
    $start = [Diagnostics.ProcessStartInfo]::new($Executable)
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $timedOut = !$process.WaitForExit($TimeoutSeconds * 1000)
        if ($timedOut) {
            $process.Kill($true)
            $process.WaitForExit()
        }
        $output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
        Set-Content -LiteralPath $log -Value $output
        if ($timedOut) { throw "$Name exceeded ${TimeoutSeconds}s; see $log" }
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $output }
    } finally { $process.Dispose() }
}

function Assert-Result([bool]$Condition, [string]$Message) {
    if (!$Condition) { throw $Message }
}

function Invoke-Candidate([string]$Name, [string[]]$Arguments = @(), [switch]$WithoutConnection) {
    # Pin the inspected image ID so a tag cannot change between cases. These
    # commands deliberately do not override the image's configured entrypoint.
    $container = "grate-entrypoint-$([guid]::NewGuid().ToString('N'))"
    $dockerArguments = @(
        'run', '--rm', '--name', $container, '--network', 'none',
        '--mount', "type=bind,source=$state/sql,target=/db,readonly",
        '--mount', "type=bind,source=$state/data,target=/data",
        '--tmpfs', '/output:rw,size=16m',
        '--env', 'DATABASE_TYPE=sqlite',
        '--env', 'VERSION=entrypoint-v1'
    )
    if (!$WithoutConnection) {
        $dockerArguments += @('--env', 'APP_CONNSTRING=Data Source=/data/database with spaces.db')
    }
    try {
        Invoke-TestProcess 'docker' ($dockerArguments + @($Image) + $Arguments) $Name
    } finally {
        # --rm normally removes it. Also stop a container whose docker client
        # timed out, since killing the client alone does not stop the container.
        $null = Invoke-TestProcess 'docker' @('rm', '--force', $container) "$Name-cleanup" 15
    }
}

function Assert-Query([string]$Name, [string]$Sql, [string]$ExpectedJson, [string]$Message) {
    # Read-only host SQLite is independent of the executable under test. JSON
    # preserves NULLs and numeric values as well as exact row/order comparisons.
    $query = Invoke-TestProcess 'sqlite3' @('-readonly', '-json', $database, $Sql) $Name 15
    Assert-Result ($query.ExitCode -eq 0) "SQLite query failed; see $Name.log"
    $actual = ConvertTo-Json -InputObject @($query.Output | ConvertFrom-Json) -Depth 8 -Compress
    $expected = ConvertTo-Json -InputObject @($ExpectedJson | ConvertFrom-Json) -Depth 8 -Compress
    Assert-Result ($actual -ceq $expected) "$Message; expected $expected, got $actual. See $Name.log"
}

try {
    $null = Get-Command 'sqlite3' -CommandType Application -ErrorAction Stop
    $inspection = Invoke-TestProcess 'docker' @('image', 'inspect', $Image) 'image-inspect'
    Assert-Result ($inspection.ExitCode -eq 0) 'Candidate image must already exist locally; see image-inspect.log'
    $metadata = @($inspection.Output | ConvertFrom-Json)[0]
    $Image = $metadata.Id
    $summary.image_id = $Image
    $summary.image_os = $metadata.Os
    $summary.image_architecture = $metadata.Architecture
    $summary.configured_entrypoint = $metadata.Config.Entrypoint
    # Retain identity metadata, not the image's environment.
    $summary | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $OutputDirectory 'image-inspect.log')

    $scripts = Join-Path $state 'sql/up'
    New-Item -ItemType Directory -Force $scripts, (Join-Path $state 'data') | Out-Null
    $database = Join-Path $state 'data/database with spaces.db'
    @'
CREATE TABLE entrypoint_probe (id INTEGER PRIMARY KEY, value TEXT NOT NULL);
INSERT INTO entrypoint_probe VALUES (42, 'entrypoint payload');
'@ | Set-Content (Join-Path $scripts '001_create.sql')

    $result = Invoke-Candidate 'dryrun-new' @('--dryrun')
    Assert-Result ($result.ExitCode -eq 0) 'New-database preview failed; see dryrun-new.log'
    Assert-Result ($result.Output.Contains('DryRun') -and $result.Output.Contains('001_create.sql')) 'Forwarded --dryrun must preview the migration; see dryrun-new.log'
    Assert-Result (!(Test-Path -LiteralPath $database)) 'Forwarded --dryrun created a database'
    $completed.Add('dryrun-new')

    foreach ($name in @('migrate', 'rerun')) {
        $result = Invoke-Candidate $name
        Assert-Result ($result.ExitCode -eq 0) "$name failed; see $name.log"
        Assert-Result (Test-Path -LiteralPath $database -PathType Leaf) "$name did not create the configured database"
        Assert-Query "$name-schema" 'PRAGMA table_info(entrypoint_probe)' '[{"cid":0,"name":"id","type":"INTEGER","notnull":0,"dflt_value":null,"pk":1},{"cid":1,"name":"value","type":"TEXT","notnull":1,"dflt_value":null,"pk":0}]' "$name did not preserve the expected application schema"
        Assert-Query "$name-data" 'SELECT id,value FROM entrypoint_probe ORDER BY id' '[{"id":42,"value":"entrypoint payload"}]' "$name did not preserve the exact application data"
        Assert-Query "$name-history" 'SELECT script_name,one_time_script FROM grate_ScriptsRun ORDER BY id' '[{"script_name":"001_create.sql","one_time_script":1}]' "$name did not record exactly one one-time execution"
        Assert-Query "$name-version" 'SELECT version,status FROM grate_Version ORDER BY id' '[{"version":"entrypoint-v1","status":"Finished"}]' "$name ignored VERSION or changed completed version history"
        Assert-Query "$name-errors" 'SELECT COUNT(*) AS count FROM grate_ScriptsRunErrors' '[{"count":0}]' "$name recorded unexpected migration errors"
        $completed.Add($name)
    }

    # A pending script distinguishes preview from an ordinary no-op invocation.
    # Compare the entire database too, including schema, data and history.
    $previewScript = Join-Path $scripts '002_preview.sql'
    'CREATE TABLE preview_only (id INTEGER);' | Set-Content $previewScript
    $before = (Get-FileHash -LiteralPath $database -Algorithm SHA256).Hash
    $result = Invoke-Candidate 'dryrun-existing' @('--dryrun')
    Assert-Result ($result.ExitCode -eq 0) 'Existing-database preview failed; see dryrun-existing.log'
    Assert-Result ($result.Output.Contains('DryRun') -and $result.Output.Contains('002_preview.sql')) 'Existing-database preview did not report the pending script'
    Assert-Result ((Get-FileHash -LiteralPath $database -Algorithm SHA256).Hash -ceq $before) 'Existing-database preview modified schema, data or migration history'
    Remove-Item -LiteralPath $previewScript
    $completed.Add('dryrun-existing')

    $result = Invoke-Candidate 'missing-connection' -WithoutConnection
    Assert-Result ($result.ExitCode -ne 0 -and $result.Output.Contains('APP_CONNSTRING')) 'Missing APP_CONNSTRING must fail with a useful diagnostic; see missing-connection.log'
    Assert-Result ((Get-FileHash -LiteralPath $database -Algorithm SHA256).Hash -ceq $before) 'Missing connection configuration changed the database'
    $completed.Add('missing-connection')

    'INSERT INTO missing_entrypoint_table VALUES (1);' | Set-Content (Join-Path $scripts '003_failure.sql')
    $result = Invoke-Candidate 'failing-sql'
    Assert-Result ($result.ExitCode -ne 0 -and $result.Output.Contains('missing_entrypoint_table') -and $result.Output.Contains('003_failure.sql')) 'Invalid SQL must return nonzero and identify the cause; see failing-sql.log'
    Assert-Query 'failing-sql-data' 'SELECT id,value FROM entrypoint_probe' '[{"id":42,"value":"entrypoint payload"}]' 'The failing migration changed existing application data'
    Assert-Query 'failing-sql-history' 'SELECT script_name FROM grate_ScriptsRun ORDER BY id' '[{"script_name":"001_create.sql"}]' 'The failing SQL was recorded as successful'
    Assert-Query 'failing-sql-errors' 'SELECT script_name FROM grate_ScriptsRunErrors ORDER BY id' '[{"script_name":"003_failure.sql"}]' 'The failing SQL did not record its error history'
    $completed.Add('failing-sql')

    $summary.result = 'passed'
    Write-Host 'PASS: default Docker entrypoint, environment, migration/rerun, dry runs and failures'
} catch {
    $summary.result = 'failed'
    $summary.error = $_.Exception.Message
    throw
} finally {
    $summary.completed = $completed.ToArray()
    $summary | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $OutputDirectory 'summary.json')
    if (Test-Path -LiteralPath $state) { Remove-Item -LiteralPath $state -Recurse -Force }
}
