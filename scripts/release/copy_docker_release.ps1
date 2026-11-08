#!/usr/bin/env pwsh
[CmdletBinding()]
param([string]$SourceAuthfile, [string]$Report)
. "$PSScriptRoot/docker_copy_common.ps1"
if ($MyInvocation.InvocationName -ne '.') {
    try { $null = Copy-DockerRelease $env:DOCKER_TAGS $env:EXPECTED_DIGEST $SourceAuthfile $Report $env:DOCKER_HUB_USER $env:DOCKER_HUB_TOKEN }
    catch { throw 'Compatibility publication failed; inspect the redacted report.' }
}
