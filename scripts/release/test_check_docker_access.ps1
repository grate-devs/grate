#!/usr/bin/env pwsh
. "$PSScriptRoot/check_docker_access.ps1"
. "$PSScriptRoot/release_test_helpers.ps1"
Invoke-Test 'distinct identities check all three repository boundaries' {
    $script:Requests=[Collections.Generic.List[object]]::new()
    $result=Test-DockerAccess 'canonical' 'legacy' { param($Repository,$Authorization) $script:Requests.Add(@($Repository,$Authorization)); if ($Repository -ceq 'erikbra/grate' -and $Authorization -ceq 'canonical') { @('pull') } else { @('pull','push') } }
    Assert-Equal 'verified' $result.status
    Assert-Equal @(@('gratedevs/grate','canonical'),@('erikbra/grate','canonical'),@('erikbra/grate','legacy')) @($script:Requests)
}
Invoke-Test 'HTTP denial is accepted only on organization to legacy boundary' {
    foreach ($denyPositive in @($false,$true)) {
        $result=Test-DockerAccess 'canonical' 'legacy' {
            param($Repository,$Authorization)
            if (($Repository -ceq 'erikbra/grate' -and $Authorization -ceq 'canonical') -or ($denyPositive -and $Repository -ceq 'gratedevs/grate')) {
                $exception=[InvalidOperationException]::new('secret');$exception.Data['StatusCode']=403;throw $exception
            }
            @('pull','push')
        }
        Assert-Equal $(if ($denyPositive) { 'failed' } else { 'verified' }) $result.status
    }
}
Invoke-Test 'positive login without push or excess access fails' {
    foreach ($responses in @(@(@('pull'),@(),@('pull','push')),@(@('pull','push'),@('push'),@('pull','push')),@(@('pull','push'),@(),@('push')))) {
        $script:GrantIndex=0
        $result=Test-DockerAccess 'canonical' 'legacy' { param($Repository,$Authorization) $value=$responses[$script:GrantIndex];$script:GrantIndex++;$value }
        Assert-Equal 'failed' $result.status
    }
}
Invoke-Test 'errors are redacted and all identities remain checked' {
    $script:GrantIndex=0
    $result=Test-DockerAccess 'canonical' 'legacy' { param($Repository,$Authorization) $script:GrantIndex++; if ($script:GrantIndex -eq 1) { throw 'secret-value' }; if ($script:GrantIndex -eq 2) { @() } else { @('pull','push') } }
    Assert-Equal 'failed' $result.status
    Assert-Equal 3 $script:GrantIndex
    Assert-True (!(($result | ConvertTo-Json -Depth 20).Contains('secret-value')))
}
Invoke-Test 'canonical authentication cannot fall back to personal identity' {
    $directory=New-TestDirectory
    try {
        $path=Join-Path $directory 'config.json'
        foreach ($user in @('gratedevs','erikbra')) {
            $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${user}:short-lived-secret"))
            Write-ReleaseJson $path @{auths=@{'https://index.docker.io/v1/'=@{auth=$encoded}}}
            if ($user -ceq 'gratedevs') { Assert-Equal ('Basic '+$encoded) (Get-CanonicalAuthorization $path) }
            else { Assert-Throws { Get-CanonicalAuthorization $path } }
        }
    } finally { [IO.Directory]::Delete($directory,$true) }
}
Invoke-Test 'grants inspect actual repository claims on auth endpoint' {
    $script:Claims=@{aud='registry.docker.io';exp=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+60;access=@(@{type='repository';name='other/repo';actions=@('push')},@{type='repository';name='gratedevs/grate';actions=@('pull')})}
    function Invoke-ReleaseHttp([string]$Uri,[hashtable]$Headers=@{},[string]$Method='GET',[switch]$NoRedirects,[int]$TimeoutSeconds) {
        Assert-True $Uri.StartsWith('https://auth.docker.io/token?')
        Assert-Equal 'Basic private' $Headers.Authorization
        Assert-Equal 'GET' $Method
        Assert-True $NoRedirects.IsPresent
        $encoded=[Convert]::ToBase64String((Get-JsonBytes $script:Claims)).TrimEnd('=').Replace('+','-').Replace('/','_')
        @{Bytes=(Get-JsonBytes @{token="header.$encoded.signature"})}
    }
    Assert-Equal @('pull') @(Get-RepositoryGrants 'gratedevs/grate' 'Basic private' | ForEach-Object { $_ })
    $script:Claims.aud='wrong'
    Assert-Throws { Get-RepositoryGrants 'gratedevs/grate' 'Basic private' } '*audience*'
    $script:Claims.aud='registry.docker.io';$script:Claims.exp=0
    Assert-Throws { Get-RepositoryGrants 'gratedevs/grate' 'Basic private' } '*expired*'
}
Write-Host "$script:TestCount access checks passed."
