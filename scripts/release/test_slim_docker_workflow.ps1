#!/usr/bin/env pwsh
. "$PSScriptRoot/workflow_test_helpers.ps1"
$jobs = (Read-Workflow 'build.yml').jobs
$builder = $jobs['build-slim-docker-images']
$publisher = $jobs['publish-slim-docker']
$profiles = 'MariaDB,Oracle,PostgreSQL,SQLite,SQLServer'
foreach ($job in @($builder, $publisher)) {
    Assert-Policy (($job.strategy.matrix.distribution | Sort-Object) -join ',' -ceq $profiles) 'Require every slim Docker profile.'
    Assert-Policy (!$job.'continue-on-error') 'Slim Docker failures must propagate.'
}
Assert-Policy ($jobs['release-ready'].needs -ccontains 'build-slim-docker-images') 'All slim archive producers must gate release publication.'
Assert-Policy (!$builder.outputs) 'A profile matrix must not expose one shared digest output.'
$build = Get-ActionStep $builder 'docker/build-push-action'
Assert-Policy ($build.with.push -eq $false -and $build.with.platforms -ceq 'linux/amd64,linux/arm64') 'Build both platforms without pushing.'
Assert-Policy ($build.with.'build-args'.Contains('GRATE_DISTRIBUTION=${{ matrix.distribution }}')) 'Build the selected profile.'
Assert-Policy ($build.with.labels.Contains('org.opencontainers.image.flavor=${{ matrix.distribution }}')) 'Record profile provenance in image labels.'
$upload = Get-ActionStep $builder 'actions/upload-artifact'
$download = Get-ActionStep $publisher 'actions/download-artifact'
Assert-Policy ($upload.with.name -ceq $download.with.name -and $upload.with.name.Contains('${{ matrix.distribution }}')) 'Publication must use the matching profile artifact.'
Assert-Policy ($upload.with.path.Contains('slim-archive-validation.json') -and $upload.with.path.Contains('grate-image.tar')) 'Retain archive and verified digest identity together.'
Assert-Policy ($publisher.needs -ccontains 'release-ready' -and $publisher.needs -ccontains 'publish-github-release') 'Publication must wait for both release gates.'
Assert-Policy ($publisher.if -ceq '${{ needs.set-version-number.outputs.is-release == ''true'' }}') 'Only an authorized release event may publish slim images.'
$validation = $builder.steps | Where-Object name -CEQ 'Bind and preflight the profile archive before the release gate'
Assert-Policy ($validation.run.Contains("'Preflight'") -and $validation.env.EXPECTED_DIGEST -ceq '${{ steps.image.outputs.digest }}') 'Preflight this exact build digest before other assets change.'
$publication = $publisher.steps | Where-Object name -CEQ 'Publish and read back the exact verified profile digest'
Assert-Policy ($publication.run.Contains('ExpectedDigest = $verification.expected_digest') -and
    $publication.run.Contains("VerificationReport = 'slim-docker-artifact/slim-archive-validation.json'")) 'Use the retained profile-specific digest and report.'
foreach ($step in @($validation, $publication)) {
    Assert-Policy ($step.env.SOURCE_COMMIT -ceq '${{ github.sha }}') 'Bind provenance to the immutable event commit.'
}
$publisherText = $publisher | ConvertTo-Json -Depth 30
Assert-Policy ($publisherText -notmatch 'DOCKER_HUB_TOKEN|DOCKER_HUB_USER|erikbra/grate') 'Compatibility credentials and destinations stay on the All publisher.'
Write-Host 'PASS: all slim OCI profiles, exact retained artifact/digest binding, dual architectures and release/identity gates.'
