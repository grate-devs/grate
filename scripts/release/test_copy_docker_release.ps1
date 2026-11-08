#!/usr/bin/env pwsh
. "$PSScriptRoot/copy_docker_release.ps1"
. "$PSScriptRoot/release_test_helpers.ps1"
. "$PSScriptRoot/docker_publication_test_fixture.ps1"
Invoke-PublicationCase 'copy verifies platforms and attestations with separate credentials' 'compatibility' {
    $result = Invoke-Publication
    Assert-Equal 'verified' $result.status
    Assert-Equal @('erikbra/grate') @($script:RegistryCalls)
    Assert-Equal @('2.3.4','latest') @(Get-PublicationCopies | ForEach-Object { $_[-1].Split(':')[-1] })
    Assert-Equal @('sha256:attestation') $result.tags.latest.attestations
    Assert-Equal 2 $result.tags.latest.platforms.Count
    Assert-True (@($script:Authfiles | Where-Object { [IO.File]::Exists($_) }).Count -eq 0) 'temporary authfiles must be removed'
    Assert-True ([IO.File]::Exists($script:AuthPath))
    Assert-Equal ($result | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable) (Get-PublicationReport)
}
Invoke-PublicationCase 'prerelease copies version and keeps latest' 'compatibility' {
    $result = Invoke-Publication "gratedevs/grate:2.3.4-rc.1`nerikbra/grate:2.3.4-rc.1"
    Assert-Equal @('2.3.4-rc.1') @($result.tags.Keys)
    Assert-Equal $script:OtherDigest $script:Destination.Tags.latest
}
Invoke-PublicationCase 'matching version verifies without recopy' 'compatibility' {
    $script:Destination.Tags['2.3.4'] = $script:Digest
    $result = Invoke-Publication
    Assert-True $result.tags['2.3.4'].already_present
    Assert-Equal 1 @(Get-PublicationCopies).Count
}
Invoke-PublicationCase 'conflicting version prevents every write' 'compatibility' {
    $script:Destination.Tags['2.3.4'] = $script:OtherDigest
    Assert-Throws { Invoke-Publication } '*conflicting*'
    Assert-Equal 0 @(Get-PublicationCopies).Count
    Assert-Equal 'failed' (Get-PublicationReport).status
}
Invoke-PublicationCase 'invalid tags and digests fail before registry and tool' 'compatibility' {
    foreach ($value in @('', 'gratedevs/grate:2.3.4', ($script:TagsValue + "`nother/grate:2.3.4"), $script:TagsValue.Replace('erikbra/grate:2.3.4','erikbra/grate:2.3.5'), ($script:TagsValue + "`nerikbra/grate:2.3.4"), "gratedevs/grate:latest`nerikbra/grate:latest", ($script:TagsValue + "`ngratedevs/grate:2.3.5`nerikbra/grate:2.3.5"), $script:TagsValue.Replace('2.3.4','2.3.4-rc.1'), $script:TagsValue.Replace('2.3.4','other'), $script:TagsValue.Replace('2.3.4','2.3.4;echo injected'))) { Assert-Throws { Invoke-Publication $value }; Assert-Equal 'failed' (Get-PublicationReport).status }
    foreach ($value in @('', 'sha256:bad', ('sha256:' + 'A' * 64), ($script:Digest + "`nmalicious"))) { Assert-Throws { Invoke-Publication $script:TagsValue $value } }
    Assert-Equal 0 $script:RegistryCalls.Count
    Assert-Equal 0 $script:Commands.Count
}
Invoke-PublicationCase 'missing credentials and authfile fail before registry' 'compatibility' {
    Assert-Throws { Invoke-Publication $script:TagsValue $script:Digest '' 'token' }
    Assert-Throws { Invoke-Publication $script:TagsValue $script:Digest 'user' '' }
    [IO.File]::Delete($script:AuthPath)
    Assert-Throws { Invoke-Publication } '*missing*'
    Assert-Equal 0 $script:RegistryCalls.Count
}
Invoke-PublicationCase 'immutable source or selected tag mismatch prevents all copies' 'compatibility' {
    foreach ($reference in @(('@' + $script:Digest), ':2.3.4', ':latest')) {
        $script:ReferenceRaw = @{ "docker://docker.io/gratedevs/grate$reference" = [Text.Encoding]::UTF8.GetBytes('changed') }
        Assert-Throws { Invoke-Publication } '*build digest*'
        Assert-Equal 0 @(Get-PublicationCopies).Count
        Assert-Equal 'failed' (Get-PublicationReport).status
    }
}
Invoke-PublicationCase 'copy failure persists attempted version and leaves latest unchanged' 'compatibility' {
    $script:FailCopy = '2.3.4'
    Assert-Throws { Invoke-Publication } '*compatibility copy failed*'
    $result = Get-PublicationReport
    Assert-Equal 'copy_started' $result.tags['2.3.4'].status
    Assert-Equal 'pending' $result.tags.latest.status
    Assert-Equal $script:OtherDigest $script:Destination.Tags.latest
    Assert-True (@($script:Authfiles | Where-Object { [IO.File]::Exists($_) }).Count -eq 0)
}
Invoke-PublicationCase 'graph failure journals copied version and stops before latest' 'compatibility' {
    $script:FailGraph = $true
    Assert-Throws { Invoke-Publication } '*SECRET_RESPONSE*'
    Assert-Equal 'copied' (Get-PublicationReport).tags['2.3.4'].status
    Assert-Equal 1 @(Get-PublicationCopies).Count
    Assert-Equal $script:OtherDigest $script:Destination.Tags.latest
}
Invoke-PublicationCase 'wrong destination digest is never verified' 'compatibility' {
    $script:GraphOverrideDigest = $script:OtherDigest
    Assert-Throws { Invoke-Publication } '*Compatibility manifest*'
    Assert-Equal 'failed' (Get-PublicationReport).status
}
Invoke-PublicationCase 'final canonical tag movement is detected' 'compatibility' {
    $script:AfterCopy = { param($Tag) if ($Tag -ceq 'latest') { $script:ReferenceRaw['docker://docker.io/gratedevs/grate:latest'] = [Text.Encoding]::UTF8.GetBytes('changed') } }
    Assert-Throws { Invoke-Publication } '*build digest*'
    Assert-Equal 'failed' (Get-PublicationReport).status
}
Invoke-PublicationCase 'final destination tag movement is detected' 'compatibility' {
    $script:AfterCopy = { param($Tag) if ($Tag -ceq 'latest') { $script:Destination.Tags['2.3.4'] = $script:OtherDigest } }
    Assert-Throws { Invoke-Publication } '*changed during copying*'
    Assert-Equal 'failed' (Get-PublicationReport).status
}
Invoke-PublicationCase 'Skopeo start failures redact response details' 'compatibility' {
    $script:FailTool = $true
    Assert-Throws { Invoke-Publication } '*could not complete*'
    Assert-Equal 'failed' (Get-PublicationReport).status
}
Write-Host "$script:TestCount copy release checks passed."
