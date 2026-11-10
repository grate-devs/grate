$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/windows_channel_common.ps1"
$hash = [Convert]::ToBase64String([byte[]]::new(64))
function New-Entry {
    param(
        [string]$Version,
        [bool]$Approved = $true
    )
    [pscustomobject]@{
        Id = 'grate'
        Version = $Version
        Approved = $Approved
        DownloadUrl = "https://community.chocolatey.org/api/v2/package/grate/$Version"
        HashAlgorithm = 'SHA512'
        PackageHash = $hash
    }
}
$entries = @((New-Entry '2.1.6'), (New-Entry '2.2.0'), (New-Entry '2.2.9' $false), (New-Entry '2.3.0'), (New-Entry '2.4.0'), (New-Entry '2.2.8-rc.1'))
$selected = Select-WindowsChannelChocolateyBaseline -Entries $entries -Version '2.3.0'
if ($selected.Version -cne '2.2.0') {
    throw 'Upgrade baseline was not the highest earlier approved stable package.'
}
foreach ($invalid in @(
    @((New-Entry '2.3.0'), (New-Entry '2.4.0')),
    @((New-Entry '2.2.0' $false))
)) {
    $rejected = $false
    try {
        Select-WindowsChannelChocolateyBaseline -Entries $invalid -Version '2.3.0' | Out-Null
    } catch {
        $rejected = $true
    }
    if (!$rejected) {
        throw 'A missing real earlier approved baseline was counted as upgrade coverage.'
    }
}
foreach ($field in @('DownloadUrl', 'HashAlgorithm', 'PackageHash')) {
    $bad = New-Entry '2.2.0'
    $bad.$field = 'wrong'
    $rejected = $false
    try {
        Select-WindowsChannelChocolateyBaseline -Entries @($bad) -Version '2.3.0' | Out-Null
    } catch {
        $rejected = $true
    }
    if (!$rejected) {
        throw "Baseline integrity/origin validation did not reject $field."
    }
}
Write-Output 'PASS: highest earlier approved stable Chocolatey baseline selected; absent/unapproved baseline and wrong-origin/digest metadata rejected.'

# Real Chocolatey Atom feeds identify the package in title; d:Id is absent.
# Exercise that XML shape and a later page rather than only pre-parsed objects.
$template = @'
<feed xmlns="http://www.w3.org/2005/Atom" xmlns:d="http://schemas.microsoft.com/ado/2007/08/dataservices" xmlns:m="http://schemas.microsoft.com/ado/2007/08/dataservices/metadata">
<entry><title type="text">grate</title><content type="application/zip" src="https://community.chocolatey.org/api/v2/package/grate/{0}"/>
<m:properties><d:Version>{0}</d:Version><d:IsApproved>true</d:IsApproved><d:PackageHash>{1}</d:PackageHash><d:PackageHashAlgorithm>SHA512</d:PackageHashAlgorithm></m:properties></entry>{2}</feed>
'@
$initialUri = 'https://community.chocolatey.org/api/v2/FindPackagesById()?id=%27grate%27'
$nextUri = 'https://community.chocolatey.org/api/v2/FindPackagesById?id=%27grate%27&$skip=1'
$pages = @{}
$pages[$initialUri] = $template -f '2.1.6', $hash, '<link rel="next" href="https://community.chocolatey.org/api/v2/FindPackagesById?id=%27grate%27&amp;$skip=1"/>'
$pages[$nextUri] = $template -f '2.2.0', $hash, ''
$readPage = {
    param(
        $uri
    )
    if (!$pages.ContainsKey($uri)) {
        throw "Unexpected fixture page: $uri"
    }
    $pages[$uri]
}.GetNewClosure()
$actual = Get-WindowsChannelChocolateyBaseline -Version '2.3.0' -ReadFeed $readPage
if ($actual.Id -cne 'grate' -or $actual.Version -cne '2.2.0') {
    throw 'The real Atom title/no-properties-ID shape or later approved page was not handled.'
}
$wrongTitle = ($template -f '2.2.0', $hash, '').Replace('>grate</title>', '>other-package</title>')
$rejected = $false
try {
    Get-WindowsChannelChocolateyBaseline -Version '2.3.0' -ReadFeed { param(
                                                                          $uri
                                                                      ) $wrongTitle }.GetNewClosure() | Out-Null
} catch {
    $rejected = $true
}
if (!$rejected) {
    throw 'A mismatched Atom package title was accepted as grate.'
}
Write-Output 'PASS: actual Atom title shape without d:Id and paginated approved-baseline selection; mismatched package title rejected.'
