#!/usr/bin/env pwsh
. "$PSScriptRoot/publish_docker_archive.ps1"
. "$PSScriptRoot/release_test_helpers.ps1"
. "$PSScriptRoot/docker_publication_test_fixture.ps1"
$oldUser = $env:DOCKER_HUB_USER; $oldToken = $env:DOCKER_HUB_TOKEN
$env:DOCKER_HUB_USER = ''; $env:DOCKER_HUB_TOKEN = ''
try {
Invoke-PublicationCase 'publishes exact archive with OIDC before latest' 'canonical' {
    $result = Invoke-Publication
    Assert-Equal @('gratedevs/grate') @($script:RegistryCalls)
    Assert-Equal 'verified' $result.status
    Assert-Equal @('2.3.4','latest') @(Get-PublicationCopies | ForEach-Object { $_[-1].Split(':')[-1] })
    Assert-True ([IO.File]::Exists($script:ArchivePath))
    Assert-True ((Get-Content -LiteralPath $script:AuthPath -Raw).Contains('OIDC_AUTH'))
    Assert-Equal ($result | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable) (Get-PublicationReport)
}
Invoke-PublicationCase 'archive mismatch prevents registry and copies' 'canonical' {
    $script:ArchiveRaw = [Text.Encoding]::UTF8.GetBytes('different archive')
    Assert-Throws { Invoke-Publication } '*archive differs*'
    Assert-Equal 0 $script:RegistryCalls.Count
    Assert-Equal 0 @(Get-PublicationCopies).Count
    Assert-Equal 'failed' (Get-PublicationReport).status
}
Invoke-PublicationCase 'conflicting immutable version prevents writes' 'canonical' {
    $script:Destination.Tags['2.3.4'] = $script:OtherDigest
    Assert-Throws { Invoke-Publication } '*conflicting*'
    Assert-Equal 0 @(Get-PublicationCopies).Count
}
Invoke-PublicationCase 'matching version verifies without overwrite' 'canonical' {
    $script:Destination.Tags['2.3.4'] = $script:Digest
    $result = Invoke-Publication
    Assert-True $result.tags['2.3.4'].already_present
    Assert-Equal @('latest') @(Get-PublicationCopies | ForEach-Object { $_[-1].Split(':')[-1] })
}
Invoke-PublicationCase 'prerelease never touches latest' 'canonical' {
    $result = Invoke-Publication "gratedevs/grate:2.3.4-rc.1`nerikbra/grate:2.3.4-rc.1"
    Assert-Equal @('2.3.4-rc.1') @($result.tags.Keys)
    Assert-Equal $script:OtherDigest $script:Destination.Tags.latest
}
Invoke-PublicationCase 'invalid tags and digests fail before external commands' 'canonical' {
    foreach ($value in @('', 'gratedevs/grate:2.3.4', ($script:TagsValue + "`nother/grate:2.3.4"), $script:TagsValue.Replace('2.3.4','2.3.4-rc.1'), $script:TagsValue.Replace('2.3.4','2.3.4;bad'))) { Assert-Throws { Invoke-Publication $value } }
    foreach ($value in @('', 'sha256:bad', ('sha256:' + 'A' * 64))) { Assert-Throws { Invoke-Publication $script:TagsValue $value } }
    Assert-Equal 0 $script:RegistryCalls.Count
    Assert-Equal 0 $script:Commands.Count
}
Invoke-PublicationCase 'missing archive or authentication file prevents tools' 'canonical' {
    [IO.File]::Delete($script:ArchivePath)
    Assert-Throws { Invoke-Publication } '*archive is missing*'
    [IO.File]::WriteAllText($script:ArchivePath,'fixture')
    [IO.File]::Delete($script:AuthPath)
    Assert-Throws { Invoke-Publication } '*authentication file is missing*'
    Assert-Equal 0 $script:RegistryCalls.Count
    Assert-Equal 0 $script:Commands.Count
}
Invoke-PublicationCase 'compatibility credentials are rejected before authentication' 'canonical' {
    foreach ($configuration in @(@{ User='legacy-user';Token='' },@{ User='';Token='LEGACY_SECRET' },@{ User='legacy-user';Token='LEGACY_SECRET' })) {
        try { $env:DOCKER_HUB_USER=$configuration.User; $env:DOCKER_HUB_TOKEN=$configuration.Token; Assert-Throws { Invoke-Publication } '*compatibility Docker credentials*' }
        finally { $env:DOCKER_HUB_USER=''; $env:DOCKER_HUB_TOKEN='' }
    }
    Assert-Equal 0 $script:RegistryCalls.Count
    Assert-Equal 0 $script:Commands.Count
}
Invoke-PublicationCase 'registry failure other than absence prevents writes' 'canonical' {
    $script:RegistryError = 401
    Assert-Throws { Invoke-Publication }
    Assert-Equal 0 @(Get-PublicationCopies).Count
    Assert-Equal 'failed' (Get-PublicationReport).status
}
Invoke-PublicationCase 'failed latest copy retains verified version journal' 'canonical' {
    $script:FailCopy = 'latest'
    Assert-Throws { Invoke-Publication } '*canonical copy failed*'
    $result = Get-PublicationReport
    Assert-Equal 'failed' $result.status
    Assert-Equal 'verified' $result.tags['2.3.4'].status
    Assert-Equal 'copy_started' $result.tags.latest.status
    Assert-Equal $script:OtherDigest $script:Destination.Tags.latest
}
Invoke-PublicationCase 'wrong version readback stops before latest' 'canonical' {
    $script:ReferenceRaw['docker://docker.io/gratedevs/grate:2.3.4'] = [Text.Encoding]::UTF8.GetBytes('changed')
    Assert-Throws { Invoke-Publication } '*build digest*'
    Assert-Equal 'copied' (Get-PublicationReport).tags['2.3.4'].status
    Assert-Equal 'pending' (Get-PublicationReport).tags.latest.status
    Assert-Equal 1 @(Get-PublicationCopies).Count
}
Invoke-PublicationCase 'final version movement is detected' 'canonical' {
    $script:AfterCopy = { param($Tag) if ($Tag -ceq 'latest') { $script:Destination.Tags['2.3.4'] = $script:OtherDigest } }
    Assert-Throws { Invoke-Publication } '*build digest*'
    Assert-Equal 'failed' (Get-PublicationReport).status
}
Invoke-PublicationCase 'tool exceptions redact credentials' 'canonical' {
    $script:FailTool = $true
    Assert-Throws { Invoke-Publication } '*could not complete*'
    Assert-Equal 'failed' (Get-PublicationReport).status
}
Invoke-PublicationCase 'verify only validates archive without credentials tags or registry' 'canonical' {
    [IO.File]::Delete($script:AuthPath)
    $env:DOCKER_HUB_TOKEN = 'LEGACY_SECRET'
    try { $result = Confirm-DockerArchive $script:Digest $script:ArchivePath $script:ReportPath }
    finally { $env:DOCKER_HUB_TOKEN = '' }
    Assert-Equal 'verified' $result.status
    Assert-Equal $script:Digest $result.digest
    Assert-Equal 1 $script:Commands.Count
    Assert-Equal 0 $script:RegistryCalls.Count
}
Invoke-PublicationCase 'verify only mismatch and invalid digest fail without registry' 'canonical' {
    $script:ArchiveRaw = [Text.Encoding]::UTF8.GetBytes('different')
    Assert-Throws { Confirm-DockerArchive $script:Digest $script:ArchivePath $script:ReportPath } '*archive differs*'
    Assert-Equal 'failed' (Get-PublicationReport).status
    $script:Commands.Clear()
    Assert-Throws { Confirm-DockerArchive '' $script:ArchivePath $script:ReportPath } '*SHA256*'
    Assert-Equal 0 $script:Commands.Count
    Assert-Equal 0 $script:RegistryCalls.Count
}
Invoke-PublicationCase 'preflight verifies missing and matching version without authfile or writes' 'canonical' {
    [IO.File]::Delete($script:AuthPath)
    foreach ($matching in @($false,$true)) {
        if ($matching) { $script:Destination.Tags['2.3.4'] = $script:Digest }
        $result = Confirm-ReleasePreflight $script:TagsValue $script:Digest $script:ArchivePath $script:ReportPath
        Assert-Equal 'preflight' $result.mode
        Assert-Equal 'verified' $result.status
        Assert-Equal $matching $result.tags['2.3.4'].already_present
        Assert-Equal 'preflight_verified' $result.tags['2.3.4'].status
    }
    Assert-Equal 0 @(Get-PublicationCopies).Count
    Assert-Equal $script:OtherDigest $script:Destination.Tags.latest
}
Invoke-PublicationCase 'preflight conflict does not write' 'canonical' {
    $script:Destination.Tags['2.3.4'] = $script:OtherDigest
    Assert-Throws { Confirm-ReleasePreflight $script:TagsValue $script:Digest $script:ArchivePath $script:ReportPath } '*conflicting*'
    Assert-Equal 0 @(Get-PublicationCopies).Count
    Assert-Equal 'failed' (Get-PublicationReport).status
}
Invoke-PublicationCase 'preflight rejects credentials and archive mismatch before registry' 'canonical' {
    try { $env:DOCKER_HUB_TOKEN='LEGACY_SECRET'; Assert-Throws { Confirm-ReleasePreflight $script:TagsValue $script:Digest $script:ArchivePath $script:ReportPath } '*compatibility Docker credentials*' }
    finally { $env:DOCKER_HUB_TOKEN='' }
    Assert-Equal 0 $script:Commands.Count
    $script:ArchiveRaw = [Text.Encoding]::UTF8.GetBytes('different')
    Assert-Throws { Confirm-ReleasePreflight $script:TagsValue $script:Digest $script:ArchivePath $script:ReportPath } '*archive differs*'
    Assert-Equal 0 $script:RegistryCalls.Count
}
} finally { $env:DOCKER_HUB_USER=$oldUser; $env:DOCKER_HUB_TOKEN=$oldToken }
Write-Host "$script:TestCount archive publication checks passed."
