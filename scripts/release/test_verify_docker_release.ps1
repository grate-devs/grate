#!/usr/bin/env pwsh
. "$PSScriptRoot/verify_docker_release.ps1"
. "$PSScriptRoot/release_test_helpers.ps1"
$script:BuildDigest='sha256:' + ('a'*64)
$script:References=@('gratedevs/grate:3.0.0','gratedevs/grate:latest','erikbra/grate:3.0.0','erikbra/grate:latest')
function Reset-Verification {
    $script:FactoryCalls=[Collections.Generic.List[string]]::new()
    $script:ManifestCalls=[Collections.Generic.List[string]]::new()
    $script:ObservedDigest=$script:BuildDigest
    $script:FirstFails=$false
}
function New-Registry([string]$Repository) { $script:FactoryCalls.Add($Repository);@{Repository=$Repository} }
function Get-RegistryManifest($Registry,[string]$Reference) {
    $script:ManifestCalls.Add("$($Registry.Repository):$Reference")
    if ($script:FirstFails -and $script:ManifestCalls.Count -eq 1) { throw 'sensitive response' }
    @{Digest=$script:ObservedDigest;Data=@{}}
}
Invoke-Test 'every tag body digest is compared with build output' {
    Reset-Verification
    $result=Confirm-DockerRelease $script:References $script:BuildDigest
    Assert-Equal 'verified' $result.status
    Assert-Equal $script:References @($script:ManifestCalls)
    Assert-Equal @('gratedevs/grate','erikbra/grate') @($script:FactoryCalls)
}
Invoke-Test 'matching repositories with wrong digest still fail' {
    Reset-Verification;$script:ObservedDigest='sha256:'+('b'*64)
    $result=Confirm-DockerRelease $script:References $script:BuildDigest
    Assert-Equal 'failed' $result.status
    Assert-Equal 4 @($result.tags | Where-Object status -ceq 'digest_mismatch').Count
}
Invoke-Test 'partial failure checks remaining tags and redacts exception' {
    Reset-Verification;$script:FirstFails=$true
    $result=Confirm-DockerRelease $script:References $script:BuildDigest
    Assert-Equal 'failed' $result.status
    Assert-Equal 'unavailable_or_invalid_manifest' $result.tags[0].status
    Assert-Equal 3 @($result.tags | Where-Object status -ceq 'verified').Count
    Assert-True (!(($result|ConvertTo-Json -Depth 20).Contains('sensitive')))
}
Invoke-Test 'missing build output records all tags but cannot pass' {
    Reset-Verification
    $result=Confirm-DockerRelease $script:References $null
    Assert-Equal 'failed' $result.status
    Assert-Equal 4 $script:ManifestCalls.Count
    Assert-Equal 4 @($result.tags | Where-Object status -ceq 'observed_without_build_digest').Count
}
Invoke-Test 'invalid input cannot contact registry' {
    Reset-Verification
    Assert-Throws { Confirm-DockerRelease @() $script:BuildDigest }
    Assert-Throws { Confirm-DockerRelease @('another/repo:3.0.0') $script:BuildDigest }
    Assert-Throws { Confirm-DockerRelease @("gratedevs/grate:bad`ntag") $script:BuildDigest }
    Assert-Throws { Confirm-DockerRelease $script:References 'invalid' }
    Assert-Throws { Confirm-DockerRelease $script:References '' }
    Assert-Equal 0 $script:FactoryCalls.Count
}
Write-Host "$script:TestCount verification checks passed."
