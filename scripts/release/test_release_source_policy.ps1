#!/usr/bin/env pwsh
. "$PSScriptRoot/workflow_test_helpers.ps1"

$jobs = (Read-Workflow 'build.yml').jobs
$tagCheck = $jobs['set-version-number'].steps | Where-Object name -CEQ 'Verify release tag identifies the event commit'
$checkoutCount = 0

foreach ($name in $jobs.Keys) {
    $job = $jobs[$name]

    foreach ($step in $job.steps) {
        if ($step.uses -like 'actions/checkout@*' -and !$step.with.ContainsKey('repository')) {
            $checkoutCount++
            Assert-Policy ($step.with.ref -ceq '${{ github.sha }}') "Checkout in $name must use immutable event SHA."
        }
        if ($step.env -and $step.env.ContainsKey('SOURCE_COMMIT')) {
            Assert-Policy ($step.env.SOURCE_COMMIT -ceq '${{ github.sha }}') "Source provenance in $name must use event SHA."
        }
        if ($step.with -and $step.with.ContainsKey('labels')) {
            Assert-Policy ($step.with.labels.Contains('org.opencontainers.image.revision=${{ github.sha }}')) 'Container provenance must use event SHA.'
        }
    }

    if ($name -ne 'set-version-number') {
        Assert-Policy ($job.needs -ccontains 'set-version-number' -or $name -ceq 'release-ready') "$name must depend on source validation."
        if ($name -ne 'release-ready') {
            Assert-Policy ($job.if -cnotlike '*always()*') "$name cannot bypass failed source validation."
        }
    }
}

Assert-Policy ($checkoutCount -gt 10 -and !$jobs['set-version-number'].outputs.ContainsKey('checkout-ref')) 'Keep event SHA checkout coverage and do not expose a mutable checkout ref.'

$temporary = Join-Path ([IO.Path]::GetTempPath()) ('grate-source-policy-' + [guid]::NewGuid().ToString('N'))
$originalTag = $env:RELEASE_TAG
$originalSha = $env:GITHUB_SHA

function Invoke-TestGit {
    $result = & git @args 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git failed: $result"
    }

    ($result -join "`n").Trim()
}

try {
    $null = New-Item -ItemType Directory -Path $temporary
    Push-Location $temporary
    Invoke-TestGit init --quiet
    Invoke-TestGit -c 'user.name=Source policy test' -c 'user.email=test@example.invalid' commit --quiet --allow-empty -m 'event commit'
    $env:GITHUB_SHA = Invoke-TestGit rev-parse HEAD

    Invoke-TestGit tag 2.3.4
    Invoke-TestGit -c 'user.name=Source policy test' -c 'user.email=test@example.invalid' tag -a 2.3.4-rc.1 -m 'annotated tag'
    Invoke-TestGit -c 'user.name=Source policy test' -c 'user.email=test@example.invalid' commit --quiet --allow-empty -m 'different commit'
    Invoke-TestGit tag 9.9.9

    foreach ($tag in @('', '2.3.4', '2.3.4-rc.1', '9.9.9', '8.8.8')) {
        $env:RELEASE_TAG = $tag
        $output = & bash -c $tagCheck.run 2>&1
        $expectedSuccess = $tag -in @('', '2.3.4', '2.3.4-rc.1')
        Assert-Policy (($LASTEXITCODE -eq 0) -eq $expectedSuccess) "Unexpected tag verification result for '$tag': $output"
    }

    Invoke-TestGit tag --force 2.3.4
    $env:RELEASE_TAG = '2.3.4'
    $output = & bash -c $tagCheck.run 2>&1
    Assert-Policy ($LASTEXITCODE -ne 0 -and ($output -join "`n").Contains('Release tag must identify the workflow event commit.')) 'Reject a tag moved away from the event commit.'
    Assert-Policy ((Invoke-TestGit rev-parse HEAD) -ceq (Invoke-TestGit rev-parse 9.9.9)) 'Tag verification must not change HEAD.'
} finally {
    Pop-Location
    $env:RELEASE_TAG = $originalTag
    $env:GITHUB_SHA = $originalSha
    Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'PASS: immutable release sources and annotated/lightweight/missing/moved tag verification.'
