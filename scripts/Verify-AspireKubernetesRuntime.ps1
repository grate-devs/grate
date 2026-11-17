#!/usr/bin/env pwsh
# Exercise the generated Helm chart in an owned kind cluster and kubeconfig.
[CmdletBinding()]
param(
    [string]$HelmPath = $env:GRATE_HELM_PATH,
    [string]$KindPath = $env:GRATE_KIND_PATH,
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Release',
    [switch]$NoBuild
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
if (!$HelmPath -or !$KindPath) {
    throw 'Supply HelmPath and KindPath, or install the pinned clients with Install-KubernetesTestTools.ps1.'
}
$repository = Split-Path $PSScriptRoot -Parent
$identifier = [Guid]::NewGuid().ToString('N').Substring(0, 12)
$cluster = "grate-init-$identifier"
$workspace = Join-Path ([IO.Path]::GetTempPath()) $cluster
$kubeconfig = Join-Path $workspace 'kubeconfig'
$publication = Join-Path $workspace 'publication'
$apiRepository = "grate-init-api-$identifier"
$apiImage = "${apiRepository}:test"
$migrationImage = "grate-init-sql-${identifier}:test"
$failureImage = "grate-init-fail-${identifier}:test"
$script:password = "Grate!$([Guid]::NewGuid().ToString('N'))" + ';a"b\c'
$script:commandNumber = 0
$previousOutput = $env:GRATE_KUBE_CHECK_OUTPUT
$previousImage = $env:GRATE_KUBE_BUILD_IMAGE
$previousHelm = $env:GRATE_HELM_PATH
$createdCluster = $false
$passed = $false
New-Item -ItemType Directory -Path $workspace | Out-Null

function Invoke-Checked {
    param(
        [string]$File,
        [string[]]$Arguments,
        [int]$TimeoutSeconds = 240,
        [switch]$AllowFailure
    )

    $start = [Diagnostics.ProcessStartInfo]::new($File)
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $Arguments) {
        $start.ArgumentList.Add($argument)
    }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (!$process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw "$File exceeded the $TimeoutSeconds second verification timeout."
        }
        $text = $stdout.GetAwaiter().GetResult()
        $diagnostics = $text + $stderr.GetAwaiter().GetResult()
        $script:commandNumber++
        $log = Join-Path $workspace "command-$($script:commandNumber).log"
        Set-Content -LiteralPath $log -Value $diagnostics.Replace($script:password, '<redacted>')
        if ($process.ExitCode -ne 0 -and !$AllowFailure) {
            throw "$File failed with exit code $($process.ExitCode). Diagnostics: $log"
        }
        return $text.TrimEnd()
    }
    finally {
        $process.Dispose()
    }
}

function Invoke-OwnedKubectl {
    param(
        [string[]]$KubectlArguments,
        [switch]$AllowFailure
    )

    $arguments = @('--kubeconfig', $kubeconfig, '--context', "kind-$cluster") + $KubectlArguments
    Invoke-Checked -File 'kubectl' -Arguments $arguments -AllowFailure:$AllowFailure
}

function Set-ValuePath {
    param(
        [hashtable]$Values,
        [string]$Path,
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'The checked publication contract has a missing Helm value path.'
    }
    $segments = $Path.Split('.')
    $current = $Values
    for ($index = 0; $index -lt $segments.Length - 1; $index++) {
        if (!$current.ContainsKey($segments[$index])) {
            $current[$segments[$index]] = @{}
        }
        $current = $current[$segments[$index]]
    }
    $current[$segments[-1]] = $Value
}

function Write-Json {
    param(
        [string]$Name,
        [object]$Value
    )

    $path = Join-Path $workspace $Name
    $Value | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $path
    return $path
}

function Get-ApplicationPod {
    param(
        [string]$Namespace
    )

    $pods = Invoke-OwnedKubectl -KubectlArguments @('get', 'pods', '--namespace', $Namespace,
        '--selector', 'app.kubernetes.io/component=api', '--output', 'json') | ConvertFrom-Json
    return @($pods.items | Where-Object { !$_.metadata.deletionTimestamp } | Sort-Object { $_.metadata.creationTimestamp })[-1]
}

function Get-SqlValue {
    param(
        [string]$Sql
    )

    Invoke-OwnedKubectl -KubectlArguments @('exec', '--namespace', 'grate-data', 'deployment/postgres', '--',
        'psql', '--username', 'app', '--dbname', 'appdb', '--tuples-only', '--no-align', '--command', $Sql)
}

function Install-Application {
    param(
        [string]$Namespace,
        [string]$SqlImage,
        [object]$Contract
    )

    $null = Invoke-OwnedKubectl -KubectlArguments @('create', 'namespace', $Namespace)
    $serviceAccount = Write-Json -Name "$Namespace-account.json" -Value @{
        apiVersion = 'v1'
        kind = 'ServiceAccount'
        metadata = @{
            name = $Contract.ServiceAccountName
            namespace = $Namespace
        }
    }
    $pullSecret = Write-Json -Name "$Namespace-pull.json" -Value @{
        apiVersion = 'v1'
        kind = 'Secret'
        metadata = @{
            name = $Contract.ImagePullSecretName
            namespace = $Namespace
        }
        type = 'kubernetes.io/dockerconfigjson'
        stringData = @{
            '.dockerconfigjson' = '{"auths":{}}'
        }
    }
    $null = Invoke-OwnedKubectl -KubectlArguments @('apply', '--filename', $serviceAccount, '--filename', $pullSecret)
    $values = @{}
    Set-ValuePath -Values $values -Path $Contract.ApiImageValue -Value $apiImage
    Set-ValuePath -Values $values -Path $Contract.MigrationImageValue -Value $SqlImage
    # Npgsql quotes connection-string values containing separators; embedded quotes double.
    $quotedPassword = $script:password.Replace('"', '""')
    $connection = "Host=postgres.grate-data.svc.cluster.local;Database=appdb;Username=app;Password=""$quotedPassword"""
    Set-ValuePath -Values $values -Path $Contract.ConnectionValue -Value $connection
    if ($Contract.ApiConnectionValue) {
        Set-ValuePath -Values $values -Path $Contract.ApiConnectionValue -Value $connection
    }
    $valuesFile = Write-Json -Name "$Namespace-values.json" -Value $values
    $null = Invoke-Checked -File $HelmPath -Arguments @('upgrade', '--install', "grate-$Namespace", $Contract.ChartDirectory,
        '--namespace', $Namespace, '--kubeconfig', $kubeconfig, '--kube-context', "kind-$cluster", '--values', $valuesFile)
}

Push-Location ([IO.Path]::GetTempPath())
try {
    $project = Join-Path $repository 'examples/aspire/Kubernetes/PublicationChecks/PublicationChecks.csproj'
    $executable = Join-Path $repository "examples/aspire/Kubernetes/PublicationChecks/bin/$Configuration/net10.0/PublicationChecks.dll"
    if (!$NoBuild) {
        $null = Invoke-Checked -File 'dotnet' -Arguments @('build', $project, '--configuration', $Configuration)
    }
    if (!(Test-Path -LiteralPath $executable)) {
        throw 'Build the Kubernetes publication checks before using -NoBuild.'
    }
    $env:GRATE_KUBE_CHECK_OUTPUT = $publication
    $env:GRATE_KUBE_BUILD_IMAGE = $migrationImage
    $env:GRATE_HELM_PATH = $HelmPath
    $null = Invoke-Checked -File 'dotnet' -Arguments @($executable)
    $contract = Get-Content -LiteralPath (Join-Path $publication 'runtime-contract.json') -Raw | ConvertFrom-Json
    $runtime = if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') {
        'linux-arm64'
    }
    else {
        'linux-x64'
    }
    $apiProject = Join-Path $repository 'examples/aspire/Api/Api.csproj'
    $null = Invoke-Checked -File 'dotnet' -Arguments @('publish', $apiProject, '--configuration', $Configuration,
        '--framework', 'net10.0', '-t:PublishContainer', "-p:ContainerRepository=$apiRepository",
        '-p:ContainerImageTag=test', "-p:ContainerRuntimeIdentifier=$runtime")

    $failureDirectory = New-Item -ItemType Directory -Path (Join-Path $workspace 'failure-image')
    Set-Content -LiteralPath (Join-Path $failureDirectory '003_fail.sql') -Value 'THIS IS INTENTIONALLY INVALID SQL;'
    Set-Content -LiteralPath (Join-Path $failureDirectory 'Dockerfile') -Value "FROM $migrationImage`nCOPY 003_fail.sql /db/up/003_fail.sql`n"
    $null = Invoke-Checked -File 'docker' -Arguments @('build', '--tag', $failureImage, $failureDirectory.FullName)

    # Never use or modify the caller's kubeconfig/current context, even during cleanup.
    $createdCluster = $true
    $nodeImage = 'kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5'
    $null = Invoke-Checked -File $KindPath -Arguments @('create', 'cluster', '--name', $cluster,
        '--image', $nodeImage, '--kubeconfig', $kubeconfig, '--wait', '180s') -TimeoutSeconds 360
    $null = Invoke-Checked -File $KindPath -Arguments @('load', 'docker-image', '--name', $cluster, $apiImage, $migrationImage, $failureImage)
    $null = Invoke-OwnedKubectl -KubectlArguments @('create', 'namespace', 'grate-data')
    $database = Write-Json -Name 'database.json' -Value @{
        apiVersion = 'v1'
        kind = 'List'
        items = @(
            @{
                apiVersion = 'v1'
                kind = 'Secret'
                metadata = @{
                    name = 'postgres'
                    namespace = 'grate-data'
                }
                stringData = @{
                    POSTGRES_PASSWORD = $script:password
                }
            }
            @{
                apiVersion = 'apps/v1'
                kind = 'Deployment'
                metadata = @{
                    name = 'postgres'
                    namespace = 'grate-data'
                }
                spec = @{
                    selector = @{
                        matchLabels = @{
                            app = 'postgres'
                        }
                    }
                    template = @{
                        metadata = @{
                            labels = @{
                                app = 'postgres'
                            }
                        }
                        spec = @{
                            containers = @(@{
                                name = 'postgres'
                                image = 'postgres:16'
                                env = @(
                                    @{
                                        name = 'POSTGRES_USER'
                                        value = 'app'
                                    }
                                    @{
                                        name = 'POSTGRES_DB'
                                        value = 'appdb'
                                    }
                                    @{
                                        name = 'POSTGRES_PASSWORD'
                                        valueFrom = @{
                                            secretKeyRef = @{
                                                name = 'postgres'
                                                key = 'POSTGRES_PASSWORD'
                                            }
                                        }
                                    }
                                )
                                readinessProbe = @{
                                    exec = @{
                                        command = @('pg_isready', '--username', 'app', '--dbname', 'appdb')
                                    }
                                    periodSeconds = 1
                                }
                            })
                        }
                    }
                }
            }
            @{
                apiVersion = 'v1'
                kind = 'Service'
                metadata = @{
                    name = 'postgres'
                    namespace = 'grate-data'
                }
                spec = @{
                    selector = @{
                        app = 'postgres'
                    }
                    ports = @(@{
                        port = 5432
                        targetPort = 5432
                    })
                }
            }
        )
    }
    $null = Invoke-OwnedKubectl -KubectlArguments @('apply', '--filename', $database)
    $null = Invoke-OwnedKubectl -KubectlArguments @('rollout', 'status', 'deployment/postgres', '--namespace', 'grate-data', '--timeout=180s')
    Install-Application -Namespace 'grate-success' -SqlImage $migrationImage -Contract $contract
    $null = Invoke-OwnedKubectl -KubectlArguments @('rollout', 'status', "deployment/$($contract.DeploymentName)", '--namespace', 'grate-success', '--timeout=180s')
    $pod = Get-ApplicationPod -Namespace 'grate-success'
    if ($pod.status.initContainerStatuses[0].state.terminated.exitCode -ne 0) {
        throw 'The successful Pod did not complete its actual grate init container.'
    }
    $message = Invoke-OwnedKubectl -KubectlArguments @('get', '--raw', "/api/v1/namespaces/grate-success/services/$($contract.ServiceName):http/proxy/")
    if ($message -ne 'Hello from grate and Aspire' -or (Get-SqlValue -Sql "SELECT message FROM aspire_demo WHERE id=2") -ne 'PRODUCTION') {
        throw 'The API or packaged production migration did not produce the expected SQL effects.'
    }
    $historySql = "SELECT count(*)::text || ':' || min(id)::text || ':' || min(text_hash) FROM grate.`"ScriptsRun`" WHERE script_name='001_create_demo.sql' AND one_time_script"
    $history = Get-SqlValue -Sql $historySql
    if (!$history.StartsWith('1:', [StringComparison]::Ordinal)) {
        throw 'The migration did not record its one-time history.'
    }
    Write-Output 'PASS: Kubernetes init migration completed before the actual API served its seeded row.'

    $originalPod = $pod.metadata.uid
    $null = Invoke-OwnedKubectl -KubectlArguments @('rollout', 'restart', "deployment/$($contract.DeploymentName)", '--namespace', 'grate-success')
    $null = Invoke-OwnedKubectl -KubectlArguments @('rollout', 'status', "deployment/$($contract.DeploymentName)", '--namespace', 'grate-success', '--timeout=180s')
    $restarted = Get-ApplicationPod -Namespace 'grate-success'
    $retained = Get-SqlValue -Sql $historySql
    if ($restarted.metadata.uid -eq $originalPod -or $restarted.status.initContainerStatuses[0].state.terminated.exitCode -ne 0 -or
        $history -ne $retained -or (Get-SqlValue -Sql 'SELECT COUNT(*) FROM aspire_demo') -ne '2') {
        throw 'A new Pod must rerun init without duplicating one-time SQL or replacing its history identity/hash.'
    }
    Write-Output 'PASS: Kubernetes Pod restart reran init and preserved one-time data and history.'

    Install-Application -Namespace 'grate-failure' -SqlImage $failureImage -Contract $contract
    $deadline = [DateTime]::UtcNow.AddSeconds(180)
    $failed = $false
    while ([DateTime]::UtcNow -lt $deadline) {
        $pod = Get-ApplicationPod -Namespace 'grate-failure'
        $init = @($pod.status.initContainerStatuses)[0]
        $exit = $init.state.terminated
        if (!$exit) {
            $exit = $init.lastState.terminated
        }
        if ($exit -and $exit.exitCode -ne 0) {
            $failed = $true
            break
        }
        Start-Sleep -Seconds 1
    }
    $primary = @($pod.status.containerStatuses)[0]
    if (!$failed -or $primary.state.running -or $primary.state.terminated -or
        (Get-SqlValue -Sql 'SELECT COUNT(*) FROM grate."ScriptsRunErrors"') -eq '0') {
        throw 'Invalid SQL must exit unsuccessfully, record error history and keep the primary container from starting.'
    }
    $migrationLog = Invoke-OwnedKubectl -KubectlArguments @('logs', $pod.metadata.name, '--namespace', 'grate-failure', '--container', $contract.InitContainerName)
    if ($migrationLog.Contains($script:password, [StringComparison]::Ordinal)) {
        throw 'The failed migration exposed its generated database password in output.'
    }
    Write-Output 'PASS: Kubernetes SQL failure kept the primary container unstarted and recorded migration errors.'
    $passed = $true
}
catch {
    if ($createdCluster -and (Test-Path -LiteralPath $kubeconfig)) {
        $null = Invoke-OwnedKubectl -KubectlArguments @('get', 'pods', '--all-namespaces', '--output', 'json') -AllowFailure
        $null = Invoke-OwnedKubectl -KubectlArguments @('get', 'events', '--all-namespaces') -AllowFailure
    }
    throw "Kubernetes runtime verification failed. Redacted diagnostics: $workspace. $($_.Exception.Message)"
}
finally {
    $cleanupFailures = [Collections.Generic.List[string]]::new()
    try {
        if ($createdCluster) {
            try {
                $null = Invoke-Checked -File $KindPath -Arguments @('delete', 'cluster', '--name', $cluster, '--kubeconfig', $kubeconfig)
                $remainingNodes = Invoke-Checked -File 'docker' -Arguments @('ps', '--all', '--filter', "label=io.x-k8s.kind.cluster=$cluster", '--format', '{{.ID}}')
                if ($remainingNodes) {
                    throw "The owned kind cluster still has containers: $cluster"
                }
            }
            catch {
                $cleanupFailures.Add($_.Exception.Message)
            }
        }
        try {
            $null = Invoke-Checked -File 'docker' -Arguments @('image', 'rm', '--force', $apiImage, $migrationImage, $failureImage) -AllowFailure:(!$passed)
        }
        catch {
            $cleanupFailures.Add($_.Exception.Message)
        }
    }
    finally {
        foreach ($file in @('database.json', 'grate-success-values.json', 'grate-failure-values.json')) {
            $path = Join-Path $workspace $file
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Force
            }
        }
        $env:GRATE_KUBE_CHECK_OUTPUT = $previousOutput
        $env:GRATE_KUBE_BUILD_IMAGE = $previousImage
        $env:GRATE_HELM_PATH = $previousHelm
        Pop-Location
    }
    if ($cleanupFailures.Count -gt 0) {
        $message = "Owned Kubernetes test resources could not be cleaned up. Keep $workspace for recovery. " + ($cleanupFailures -join ' ')
        if ($passed) {
            throw $message
        }
        Write-Warning $message
    }
    elseif (Test-Path -LiteralPath $kubeconfig) {
        Remove-Item -LiteralPath $kubeconfig -Force
    }
    if ($passed) {
        Remove-Item -LiteralPath $workspace -Recurse -Force
        Write-Output 'PASS: owned Kubernetes cluster and images removed; caller context unchanged.'
    }
}
