#!/usr/bin/env pwsh
# Publish scratch fixtures only to a disposable loopback registry. No Docker Hub
# authentication or publication. Remove the builder/network/container on exit.
[CmdletBinding()]
param()
. "$PSScriptRoot/../release_tags.ps1"

$script:LocalRegistryImage = 'registry:3@sha256:d4032d4cc323c1731c707931ecada07a53076eac38e3b61ae57533f170f2c6c3'
$script:LocalIndexAccept = 'application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json'

function Invoke-LocalDocker([string[]]$Arguments) {
    $result = Invoke-ReleaseProcess 'docker' $Arguments
    if ($result.ExitCode -ne 0) { throw "Docker $($Arguments[0]) failed (exit $($result.ExitCode))." }
    return $result.Text.Trim()
}

function Get-LocalManifestDigest([string]$Address, [string]$Tag) {
    $repository, $reference = $Tag -split ':', 2
    $response = Invoke-ReleaseHttp "http://$Address/v2/$repository/manifests/$reference" @{Accept=$script:LocalIndexAccept} -NoRedirects -TimeoutSeconds 20
    $index = ConvertFrom-ResponseJson $response
    $platforms = @($index.manifests | ForEach-Object { "$($_.platform.os)/$($_.platform.architecture)" })
    foreach ($required in @('linux/amd64','linux/arm64')) {
        if ($required -cnotin $platforms) { throw "Local index for $Tag is missing $required." }
    }
    return Get-ByteDigest $response.Bytes
}

function Invoke-LocalRegistryCheck {
    $container = 'grate-dual-publish-' + [guid]::NewGuid().ToString('N').Substring(0,12)
    $network = $container+'-network'; $builder = $container+'-builder'
    $registryAddress = $container+':5000'
    $root = Join-Path ([IO.Path]::GetTempPath()) ('grate local registry '+[guid]::NewGuid().ToString('N'))
    try {
        $null = Invoke-LocalDocker @('network','create',$network)
        $null = Invoke-LocalDocker @('run','--detach','--name',$container,'--network',$network,'--publish','127.0.0.1::5000',$script:LocalRegistryImage)
        $inspection = Invoke-LocalDocker @('inspect',$container) | ConvertFrom-Json -AsHashtable -NoEnumerate
        $address = '127.0.0.1:'+$inspection[0].NetworkSettings.Ports['5000/tcp'][0].HostPort
        $null = [IO.Directory]::CreateDirectory($root)
        $config = Join-Path $root 'buildkitd.toml'
        [IO.File]::WriteAllText($config, "[registry.`"$registryAddress`"]`n  http = true`n", [Text.UTF8Encoding]::new($false))
        $null = Invoke-LocalDocker @('buildx','create','--name',$builder,'--driver','docker-container','--driver-opt',"network=$network",'--buildkitd-config',$config)
        [IO.File]::WriteAllText((Join-Path $root 'Dockerfile'), "FROM scratch`nCOPY payload /payload`n", [Text.UTF8Encoding]::new($false))
        $evidence = [ordered]@{}
        foreach ($version in @('3.0.0','3.1.0-rc.1')) {
            [IO.File]::WriteAllText((Join-Path $root 'payload'), $version, [Text.UTF8Encoding]::new($false))
            $tags = @(Get-ImageTags $version)
            $arguments = @('buildx','build','--builder',$builder,'--platform','linux/amd64,linux/arm64','--push')
            foreach ($tag in $tags) { $arguments += @('--tag',"$registryAddress/$tag") }
            $null = Invoke-LocalDocker ($arguments+@($root))
            $results = [ordered]@{}
            foreach ($tag in $tags) { $results[$tag] = Get-LocalManifestDigest $address $tag }
            if (@($results.Values | Select-Object -Unique).Count -ne 1) { throw "Canonical and compatibility digests differ for $version." }
            $evidence[$version] = $results
        }
        $stable = $evidence['3.0.0']['gratedevs/grate:latest']
        foreach ($tag in @('gratedevs/grate:latest','erikbra/grate:latest')) {
            if ((Get-LocalManifestDigest $address $tag) -cne $stable) { throw "Prerelease changed $tag." }
        }
        if ($evidence['3.1.0-rc.1']['gratedevs/grate:3.1.0-rc.1'] -ceq $stable) { throw 'Prerelease must have a different fixture digest.' }
        @{status='verified';tags=$evidence;latest_unchanged_after_prerelease=$true} | ConvertTo-Json -Depth 10
    } finally {
        # Cleanup must not replace the original failure if setup stopped early.
        foreach ($arguments in @(@('buildx','rm','--force',$builder),@('rm','--force','--volumes',$container),@('network','rm',$network))) {
            try { $null = Invoke-ReleaseProcess 'docker' $arguments 60 } catch { Write-Verbose "Cleanup failed: $_" }
        }
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($MyInvocation.InvocationName -ne '.') { Invoke-LocalRegistryCheck }
