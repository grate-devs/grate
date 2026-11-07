#!/usr/bin/env pwsh
. "$PSScriptRoot/resolve_release_context.ps1"
. "$PSScriptRoot/release_test_helpers.ps1"
$sha = 'a' * 40
$script:UnexpectedReleaseReads = 0
$base = @{EVENT_NAME='push'; GITVERSION_SEMVER='2.3.4-alpha.12'; GITHUB_SHA=$sha; GITHUB_REPOSITORY='grate-devs/grate'}
Invoke-Test 'gh invocation reads only metadata and redacts native or JSON failures' {
    $original = (Get-Item Function:Invoke-ReleaseProcess).ScriptBlock
    try {
        function Invoke-ReleaseProcess($FilePath,$Arguments,$TimeoutSeconds) {
            Assert-Equal 'gh' $FilePath
            Assert-Equal @('release','view','2.3.4-rc.1','--repo','grate-devs/grate','--json','isDraft,isPrerelease') $Arguments
            Assert-Equal 45 $TimeoutSeconds
            @{ExitCode=0;Text='{"isDraft":false,"isPrerelease":true}'}
        }
        Assert-Equal @{isDraft=$false;isPrerelease=$true} (Read-GitHubRelease '2.3.4-rc.1' 'grate-devs/grate')
        foreach ($mode in @('exit','json','timeout')) {
            function Invoke-ReleaseProcess { if ($mode -ceq 'timeout') { throw 'SECRET_COMMAND' }; @{ExitCode=$(if ($mode -ceq 'exit') {1} else {0});Text='SECRET_RESPONSE'} }
            $caught=$null
            try { Read-GitHubRelease '2.3.4' 'grate-devs/grate' } catch { $caught=$_ }
            Assert-True ($null -ne $caught -and $caught.Exception.Message -cnotmatch 'SECRET_') 'Redact process output.'
        }
    } finally { Set-Item Function:Invoke-ReleaseProcess $original }
}
function Resolve-TestContext([hashtable]$Values = @{}, [scriptblock]$Reader = { $script:UnexpectedReleaseReads++; throw 'Unexpected release metadata lookup.' }) {
    $environment = $base.Clone()
    foreach ($key in $Values.Keys) { $environment[$key] = $Values[$key] }
    Resolve-ReleaseContext $environment $Reader
}
function Resolve-TestRelease([hashtable]$Values = @{}) {
    $release = @{EVENT_NAME='release'; RELEASE_ACTION='published'; RELEASE_DRAFT='false'; RELEASE_TAG='2.3.4'; RELEASE_PRERELEASE='false'}
    foreach ($key in $Values.Keys) { $release[$key] = $Values[$key] }
    if (!$release.ContainsKey('GITHUB_REF')) { $release.GITHUB_REF = 'refs/tags/' + $release.RELEASE_TAG }
    Resolve-TestContext $release
}
Invoke-Test 'tagged runs validate workflow ref and SHA before lookup' {
    foreach ($reference in @('','refs/heads/main','refs/heads/2.3.4','refs/tags/9.9.9')) {
        Assert-Throws { Resolve-TestRelease @{GITHUB_REF=$reference} } '*workflow ref*'
        foreach ($publish in @('true','false')) { Assert-Throws { Resolve-TestContext @{EVENT_NAME='workflow_dispatch';MANUAL_TAG='2.3.4';MANUAL_PUBLISH=$publish;GITHUB_REF=$reference} } '*workflow ref*' }
    }
    Assert-Throws { Resolve-TestRelease @{GITHUB_SHA=''} } '*GITHUB_SHA*'
    Assert-Throws { Resolve-TestContext @{EVENT_NAME='workflow_dispatch';MANUAL_TAG='2.3.4';MANUAL_PUBLISH='false';GITHUB_REF='refs/tags/2.3.4';GITHUB_SHA=''} } '*GITHUB_SHA*'
    Assert-Throws { Resolve-TestContext @{EVENT_NAME='workflow_dispatch';MANUAL_PUBLISH='true'} } '*MANUAL_TAG*'
}
$manual = @{EVENT_NAME='workflow_dispatch';MANUAL_PUBLISH='true';MANUAL_TAG='2.3.4';GITHUB_REF='refs/tags/2.3.4'}
Invoke-Test 'manual publication reads requested release and validates booleans' {
    foreach ($version in @('2.3.4','2.3.4-rc.1')) {
        $values = $manual.Clone(); $values.MANUAL_TAG=$version; $values.GITHUB_REF="refs/tags/$version"
        $reader = { param($tag,$repository) Assert-Equal $version $tag; Assert-Equal 'grate-devs/grate' $repository; @{isDraft=$false;isPrerelease=$version.Contains('-')} }
        $context = Resolve-TestContext $values $reader
        Assert-Equal 'true' $context.publish
        Assert-Equal ($version.Contains('-').ToString().ToLowerInvariant()) $context.prerelease
    }
    foreach ($metadata in @(@{isDraft=$true;isPrerelease=$false},@{},$null,@(),@{isDraft=$false},@{isPrerelease=$false},@{isDraft='false';isPrerelease=$false},@{isDraft=$false;isPrerelease=0})) {
        Assert-Throws { Resolve-TestContext $manual { $metadata } }
    }
    foreach ($version in @('2.3.4','2.3.4-rc.1')) {
        $values = $manual.Clone(); $values.MANUAL_TAG=$version; $values.GITHUB_REF="refs/tags/$version"
        Assert-Throws { Resolve-TestContext $values { @{isDraft=$false;isPrerelease=(!$version.Contains('-'))} } } '*disagree*'
    }
    $caught = $null
    try { Resolve-TestContext $manual { throw 'SECRET_RESPONSE' } } catch { $caught = $_ }
    Assert-True ($null -ne $caught -and $caught.Exception.Message -cnotlike '*SECRET_RESPONSE*') 'Redact release lookup errors.'
}
Invoke-Test 'manual booleans and repository names fail before lookup' {
    foreach ($change in @(@{MANUAL_PUBLISH='True'},@{MANUAL_PUBLISH='1'},@{GITHUB_REPOSITORY=''},@{GITHUB_REPOSITORY="bad`nrepository"})) {
        $values=$manual.Clone(); foreach ($key in $change.Keys) { $values[$key]=$change[$key] }
        Assert-Throws { Resolve-TestContext $values }
    }
}
Invoke-Test 'invalid or injected versions and commit identities fail' {
    foreach ($version in @('','latest','v2.3.4','2.3','02.3.4','2.03.4','2.3.04','2.3.4-01','2.3.4-rc.01','2.3.4-','2.3.4-rc..1','2.3.4+build.1','2.3.4-rc.1+build.1',"2.3.4`npublish=true",'2.3.4;echo secret')) {
        Assert-Throws { Resolve-TestContext @{GITVERSION_SEMVER=$version} }
        if ($version) { $values=$manual.Clone();$values.MANUAL_TAG=$version; Assert-Throws { Resolve-TestContext $values } }
    }
    foreach ($version in @('0.0.0','2.3.4-0','2.3.4-01a','2.3.4-rc.0','2.3.4--')) { Assert-Equal $version (Resolve-TestContext @{GITVERSION_SEMVER=$version}).version }
    foreach ($invalidSha in @('','main',('a'*39),('a'*41),($sha+"`npublish=true"))) { Assert-Throws { Resolve-TestContext @{GITHUB_SHA=$invalidSha} } '*GITHUB_SHA*' }
    Assert-Equal ('b'*64) (Resolve-TestContext @{GITHUB_SHA=('b'*64)}).checkout_ref
}
Invoke-Test 'commit build uses exact SHA and metadata-free GitVersion without lookup' {
    Assert-Equal @{checkout_ref=$sha;core_version='2.3.4';version='2.3.4-alpha.12';publish='false';prerelease='true';release_tag=''} (Resolve-TestContext @{GITVERSION_FULL_SEMVER='2.3.4-alpha.12+15'})
}
Invoke-Test 'nonrelease events ignore publication inputs' {
    foreach ($event in @('push','pull_request','pull_request_target','schedule')) {
        $context = Resolve-TestContext @{EVENT_NAME=$event; MANUAL_TAG='9.9.9';MANUAL_PUBLISH='true';RELEASE_TAG='8.8.8';RELEASE_PRERELEASE='false';RELEASE_ACTION='published';RELEASE_DRAFT='false'}
        Assert-Equal @('false','2.3.4-alpha.12',$sha,'') @($context.publish,$context.version,$context.checkout_ref,$context.release_tag)
    }
}
Invoke-Test 'published stable and prerelease events preserve full versions' {
    Assert-Equal @{checkout_ref=$sha;core_version='2.3.4';version='2.3.4';publish='true';prerelease='false';release_tag='2.3.4'} (Resolve-TestRelease)
    $context = Resolve-TestRelease @{RELEASE_TAG='2.3.4-rc.1';RELEASE_PRERELEASE='true'}
    Assert-Equal @('2.3.4-rc.1','2.3.4','true','true') @($context.version,$context.core_version,$context.prerelease,$context.publish)
}
Invoke-Test 'unpublished draft and malformed release events fail' {
    foreach ($action in @('created','released','prereleased','')) { Assert-Throws { Resolve-TestRelease @{RELEASE_ACTION=$action} } }
    foreach ($draft in @('true','','False')) { Assert-Throws { Resolve-TestRelease @{RELEASE_DRAFT=$draft} } }
    Assert-Throws { Resolve-TestRelease @{RELEASE_TAG=''} }
    foreach ($flag in @('','True','0')) { Assert-Throws { Resolve-TestRelease @{RELEASE_PRERELEASE=$flag} } }
}
Invoke-Test 'release prerelease flags must agree with version' {
    Assert-Throws { Resolve-TestRelease @{RELEASE_PRERELEASE='true'} } '*disagree*'
    Assert-Throws { Resolve-TestRelease @{RELEASE_TAG='2.3.4-rc.1'} } '*disagree*'
}
Invoke-Test 'manual dry runs do not fetch release metadata' {
    foreach ($flag in @('false','')) {
        $context = Resolve-TestContext @{EVENT_NAME='workflow_dispatch';MANUAL_PUBLISH=$flag}
        Assert-Equal @('false',$sha,'2.3.4-alpha.12') @($context.publish,$context.checkout_ref,$context.version)
    }
    foreach ($version in @('2.3.4','2.3.4-rc.1')) {
        $context = Resolve-TestContext @{EVENT_NAME='workflow_dispatch';MANUAL_PUBLISH='false';MANUAL_TAG=$version;GITHUB_REF="refs/tags/$version"}
        Assert-Equal @($sha,$version,'false',$version.Contains('-').ToString().ToLowerInvariant()) @($context.checkout_ref,$context.release_tag,$context.publish,$context.prerelease)
    }
}
Invoke-Test 'CLI appends outputs and summary and keeps files intact on failure' {
    $directory = New-TestDirectory
    $values = $base.Clone(); $values.GITHUB_OUTPUT="$directory/output"; $values.GITHUB_STEP_SUMMARY="$directory/summary"
    $saved = @{}
    foreach ($key in $values.Keys) { $saved[$key]=[Environment]::GetEnvironmentVariable($key); [Environment]::SetEnvironmentVariable($key,$values[$key]) }
    try {
        [IO.File]::WriteAllText($values.GITHUB_OUTPUT,"retained=existing`n")
        & (Get-Process -Id $PID).Path -NoLogo -NoProfile -File "$PSScriptRoot/resolve_release_context.ps1"
        Assert-Equal 0 $LASTEXITCODE
        $outputs = @{}
        foreach ($line in [IO.File]::ReadAllLines($values.GITHUB_OUTPUT)) { $key,$value=$line -split '=',2; $outputs[$key]=$value }
        Assert-Equal 'existing' $outputs.retained; $outputs.Remove('retained')
        Assert-Equal (Resolve-TestContext) $outputs
        $summary = [IO.File]::ReadAllText($values.GITHUB_STEP_SUMMARY)
        Assert-True ($summary.Contains('- Publish: `false`') -and $summary.Contains('- Checkout ref: `' + $sha + '`')) 'Summary must contain exact release context.'
        [IO.File]::WriteAllText($values.GITHUB_OUTPUT,"retained=existing`n"); Remove-Item -LiteralPath $values.GITHUB_STEP_SUMMARY
        $env:GITVERSION_SEMVER='SECRET_INVALID_VERSION'
        $result = & (Get-Process -Id $PID).Path -NoLogo -NoProfile -File "$PSScriptRoot/resolve_release_context.ps1" 2>&1
        Assert-True ($LASTEXITCODE -ne 0 -and ($result -join "`n") -cnotlike '*SECRET_INVALID_VERSION*') 'CLI must redact invalid versions.'
        Assert-Equal "retained=existing`n" ([IO.File]::ReadAllText($values.GITHUB_OUTPUT))
        Assert-True (!(Test-Path -LiteralPath $values.GITHUB_STEP_SUMMARY)) 'Failed validation must not create summary.'
        $env:GITHUB_OUTPUT=''
        Assert-Throws { Invoke-ReleaseContext } '*GITHUB_OUTPUT*'
    } finally {
        foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key,$saved[$key]) }
        Remove-Item -LiteralPath $directory -Recurse -Force
    }
}
Assert-Equal 0 $script:UnexpectedReleaseReads 'Invalid inputs and dry runs must fail or complete before any metadata lookup.'
Write-Host "PASS: $script:TestCount release-context scenario groups."
