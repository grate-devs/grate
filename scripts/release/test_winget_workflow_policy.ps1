#!/usr/bin/env pwsh
. "$PSScriptRoot/workflow_test_helpers.ps1"

$jobs = (Read-Workflow 'build.yml').jobs
$job = $jobs['prepare-winget']
$expectedProfiles = 'All,MariaDB,Oracle,PostgreSQL,SQLite,SQLServer'
Assert-Policy ((@($job.strategy.matrix.distribution | Sort-Object) -join ',') -ceq $expectedProfiles) 'Prepare one WinGet candidate for each of the six distributions.'
foreach ($dependency in @('set-version-number', 'release-ready', 'publish-github-release')) {
    Assert-Policy ($job.needs -ccontains $dependency) "WinGet preparation requires $dependency."
}

$stableReleaseCondition = '${{ needs.set-version-number.outputs.is-release == ''true'' && needs.set-version-number.outputs.is-prerelease != ''true'' }}'
Assert-Policy ($job.if -ceq $stableReleaseCondition) 'Only published stable releases may prepare migration candidates.'

$checkout = Get-ActionStep $job 'actions/checkout'
$checkoutUsesEventSource = (
    $checkout.with.ref -ceq '${{ github.sha }}' -and
    $checkout.with.'persist-credentials' -ceq $false
)
Assert-Policy $checkoutUsesEventSource 'WinGet tooling must use the event source without persisted credentials.'

$prepare = $job.steps | Where-Object { $_.run -like '*Create-Installer.ps1*' } | Select-Object -First 1
$preparePreservesReleaseContext = (
    $prepare.env.VERSION -ceq '${{ needs.set-version-number.outputs.semVer }}' -and
    $prepare.env.RELEASE_TAG -ceq '${{ needs.set-version-number.outputs.release-tag }}'
)
Assert-Policy $preparePreservesReleaseContext 'Preserve release context in WinGet preparation.'
Assert-Policy ($prepare.run.Contains('-PrepareMigration')) 'Require migration preparation.'
Assert-Policy ($prepare.run.Contains("-Distribution '`${{ matrix.distribution }}'")) 'Select the matching WinGet profile assets and MSI identities.'

$preparationHasNoPublishingAccess = (
    !$jobs.ContainsKey('publish-winget') -and
    $job.permissions.Count -eq 1 -and
    $job.permissions.contents -ceq 'read' -and
    !$job.ContainsKey('environment')
)
Assert-Policy $preparationHasNoPublishingAccess 'Do not add WinGet automatic publication or publishing permissions.'

$text = $job | ConvertTo-Json -Depth 100
Assert-Policy ($text -notmatch 'secrets\.|WINGET_GH_PAT|--submit|\bgh pr create\b') 'Do not expose publishing credentials or submit pull requests.'

$commands = ($job.steps | ForEach-Object { $_.run }) -join "`n"
Assert-Policy ($commands -notmatch '(?<!\S)-s(?!\S)|(?i:wingetcreate(?:\.exe)?\s+(?:submit|new)\b)') 'Do not submit WinGet manifests automatically.'

$requiredCommands = @(
    'winget-create/releases/download/v1.12.13.0/wingetcreate.exe'
    '24042BD37915805615E6CF969AC57C6439124C3FE85823327F5F3FB24BD9FFEA'
    'validate --manifest'
    'Initialize-LifecycleRunner.ps1'
)
foreach ($required in $requiredCommands) {
    Assert-Policy ($commands.Contains($required)) "Missing WinGet contract: $required"
}
Assert-Policy (!$commands.Contains('--ignore-warnings')) 'Do not bypass manifest validation warnings.'
Assert-Policy ($commands.Contains('$env:WINGET_PACKAGE_PATH/$env:VERSION')) 'Schema-validate the selected profile manifest directory.'
Assert-Policy ($commands.Contains('PackageIdentifier=$env:WINGET_PACKAGE_ID')) 'Bind candidate provenance to its selected WinGet identity.'

$upload = Get-ActionStep $job 'actions/upload-artifact'
Assert-Policy ($upload.uses -cmatch '@[0-9a-f]{40}$' -and $upload.with.'if-no-files-found' -ceq 'error') 'Pin candidate upload and fail on missing artifacts.'

$msi = $jobs['build-msi']
Assert-Policy ((@($msi.strategy.matrix.distribution | Sort-Object) -join ',') -ceq $expectedProfiles) 'Build all six MSI distributions.'
Assert-Policy ((@($msi.strategy.matrix.arch | Sort-Object) -join ',') -ceq 'win-arm64,win-x64') 'Verify both MSI architectures.'
$download = Get-ActionStep $msi 'actions/download-artifact'
Assert-Policy ($download.with.name -ceq '${{ steps.distribution.outputs.package-id }}-${{ matrix.arch }}-self-contained-${{ needs.set-version-number.outputs.semVer }}') 'MSI must consume the matching distribution/architecture CLI artifact.'

$steps = @($msi.steps)
$check = $steps | Where-Object { $_.run -like '*Test-InstallerMetadata.Tests.ps1*' } | Select-Object -First 1
$upload = Get-ActionStep $msi 'actions/upload-artifact'
Assert-Policy ($null -ne $check -and $steps.IndexOf($check) -lt $steps.IndexOf($upload)) 'Verify actual MSI metadata before uploading.'

$requiredMetadataArguments = @(
    '-MsiPath $name'
    '-ExpectedVersion'
    '-ExpectedReleaseVersion "${{ needs.set-version-number.outputs.semVer }}"'
    '-ExpectedArchitecture'
    '-Distribution ''${{ matrix.distribution }}'''
)
foreach ($required in $requiredMetadataArguments) {
    Assert-Policy ($check.run.Contains($required)) "Missing MSI metadata contract: $required"
}

$commands = ($steps | ForEach-Object { $_.run }) -join "`n"
$requiredMsiContracts = @(
    '-ReleaseVersion "${{ needs.set-version-number.outputs.semVer }}"'
    'Test-CreateInstaller.Tests.ps1'
    'Test-InstallerCorrelation.Tests.ps1'
    'Test-InstallerAuthoring.Tests.ps1'
    'Test-InstallerIdentity.Tests.ps1'
)
foreach ($required in $requiredMsiContracts) {
    Assert-Policy ($commands.Contains($required)) "Missing MSI release contract: $required"
}
Assert-Policy ($upload.with.path -ceq '${{ steps.distribution.outputs.package-id }}-msi-${{ matrix.arch }}-${{ needs.set-version-number.outputs.semVer }}.msi') 'MSI release assets must use the selected profile package ID.'

$standalone = (Read-Workflow 'ci.yml').jobs.standalone
foreach ($name in @('Check per-user MSI authoring regressions', 'Build MSI from verified Windows binary', 'Check verified Windows MSI metadata', 'Verify installed MSI, major upgrade and uninstall')) {
    $step = $standalone.steps | Where-Object name -CEQ $name
    Assert-Policy ($step.if -ceq "matrix.rid == 'win-x64' || matrix.rid == 'win-arm64'") "All twelve native Windows MSI lanes must run: $name"
}
$lifecycle = $standalone.steps | Where-Object name -CEQ 'Verify installed MSI, major upgrade and uninstall'
Assert-Policy ($lifecycle.run.Contains("Distribution = '`${{ matrix.distribution }}'")) 'Native MSI lifecycle checks must select their distribution.'

Assert-Policy ($jobs['release-ready'].needs -ccontains 'build-msi') 'MSI must be part of the release gate.'
$gate = ($jobs['release-ready'].steps | ForEach-Object { $_.run }) -join "`n"
Assert-Policy ($gate.Contains('.result == "success"')) 'Release gate must require successful jobs.'

Write-Host 'PASS: six-profile WinGet candidate boundary, twelve MSI artifacts and twelve native Windows lifecycle lanes.'
