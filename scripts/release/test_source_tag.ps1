#!/usr/bin/env pwsh
. "$PSScriptRoot/release_common.ps1"
. "$PSScriptRoot/release_test_helpers.ps1"
. "$PSScriptRoot/distribution_profiles.ps1"
$PSNativeCommandUseErrorActionPreference = $true
$directory = New-TestDirectory

try {
    Push-Location $directory
    git init --quiet
    git config user.email 'grate-test@example.invalid'
    git config user.name 'grate test'
    git remote add origin $directory
    Set-Content -LiteralPath fixture.txt -Value 'first'
    git add fixture.txt
    git commit --quiet -m first
    $firstCommit = git rev-parse HEAD
    git tag 2.3.4
    git tag -a v2.3.5 -m annotated

    Invoke-Test 'lightweight and annotated tags bind to the exact source commit' {
        Assert-GrateSourceTag -Tag '2.3.4' -SourceCommit $firstCommit
        Assert-GrateSourceTag -Tag 'v2.3.5' -SourceCommit $firstCommit
    }
    Invoke-Test 'missing tag is rejected' {
        Assert-Throws { Assert-GrateSourceTag -Tag '2.3.6' -SourceCommit $firstCommit } '*verified release commit*'
    }
    Invoke-Test 'tag moved after download is rejected' {
        Set-Content -LiteralPath fixture.txt -Value 'second'
        git add fixture.txt
        git commit --quiet -m second
        git tag -f 2.3.4 | Out-Null
        Assert-Throws { Assert-GrateSourceTag -Tag '2.3.4' -SourceCommit $firstCommit } '*verified release commit*'
    }
    Invoke-Test 'unsafe tag and nonimmutable commit are rejected' {
        foreach ($tag in @('2.3.4-rc.1', '../2.3.4', '2.3.4?other', '02.3.4')) {
            Assert-Throws { Assert-GrateSourceTag -Tag $tag -SourceCommit $firstCommit } '*stable release tag*'
        }
        Assert-Throws { Assert-GrateSourceTag -Tag '2.3.4' -SourceCommit 'HEAD' } '*immutable source SHA*'
    }
    Invoke-Test 'remote lookup failure is propagated' {
        git remote set-url origin "$directory/missing.git"
        Assert-Throws { Assert-GrateSourceTag -Tag '2.3.4' -SourceCommit $firstCommit }
    }
} finally {
    Pop-Location
    Remove-Item -LiteralPath $directory -Recurse -Force
}
Write-Host "PASS: $script:TestCount source tag binding cases."
