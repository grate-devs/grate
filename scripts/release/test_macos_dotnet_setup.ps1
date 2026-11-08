#!/usr/bin/env pwsh
. "$PSScriptRoot/workflow_test_helpers.ps1"
. "$PSScriptRoot/release_common.ps1"
. "$PSScriptRoot/release_test_helpers.ps1"

$actionPath = Join-Path $repositoryRoot '.github/actions/setup-dotnet-macos-arm64/action.yml'
$action = Get-Content -LiteralPath $actionPath -Raw | ConvertFrom-Yaml
$workflow = Read-Workflow 'build.yml'

function Assert-InstallerPolicy {
    param(
        [hashtable] $Action,
        [hashtable] $Workflow
    )

    $job = $Workflow.jobs['build-standalone-mac-arm64']
    $setup = $job.steps | Where-Object uses -CEQ './.github/actions/setup-dotnet-macos-arm64'
    Assert-Policy ($null -ne $setup) 'The macOS release build must use the isolated installer.'
    Assert-Policy ($setup.with.'global-json-file' -ceq 'global.json' -and $setup.with.'dotnet-version' -ceq '10.0.x') 'Preserve SDK inputs.'
    Assert-Policy ($Workflow.on.pull_request.paths -contains '.github/actions/setup-dotnet-macos-arm64/**') 'Action changes must trigger the release build.'

    $installs = @($Action.runs.steps | Where-Object uses -Like 'actions/setup-dotnet@*')
    Assert-Policy ($installs.Count -eq 2) 'Allow exactly two installation attempts.'
    foreach ($install in $installs) {
        Assert-Policy ($install.uses -ceq 'actions/setup-dotnet@67a3573c9a986a3f9c594539f4ab511d57bb3ce9') 'Preserve the trusted installer pin.'
        Assert-Policy ($install.with.'global-json-file' -ceq '${{ inputs.global-json-file }}' -and $install.with.'dotnet-version' -ceq '${{ inputs.dotnet-version }}') 'Both attempts must use identical SDK selection inputs.'
    }
    $first = $installs[0]
    $retry = $installs[1]
    Assert-Policy ($first.id -ceq 'first' -and $first.'continue-on-error' -eq $true) 'Only the initial installation may recover from failure.'
    Assert-Policy ($retry.id -ceq 'retry' -and !$retry.'continue-on-error') 'The final installation failure must fail the job.'
    Assert-Policy ($retry.if -ceq "steps.first.outcome == 'failure'") 'Retry only the initial failed installation outcome.'
    Assert-Policy ($first.env.DOTNET_INSTALL_DIR -ceq '${{ steps.prepare.outputs.root }}/first/install' -and $retry.env.DOTNET_INSTALL_DIR -ceq '${{ steps.prepare.outputs.root }}/retry/install') 'Never reuse a partially installed SDK tree.'
    Assert-Policy ($first.env.TMPDIR -ceq '${{ steps.prepare.outputs.root }}/first/temp' -and $retry.env.TMPDIR -ceq '${{ steps.prepare.outputs.root }}/retry/temp') 'Each attempt requires its own temporary directory.'
    foreach ($step in $Action.runs.steps | Where-Object run) {
        Assert-Policy (!$step.'continue-on-error') 'Preparation and verification cannot ignore failures.'
        $tokens = $null
        $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseInput($step.run, [ref]$tokens, [ref]$errors)
        Assert-Policy ($errors.Count -eq 0) "PowerShell action syntax: $($errors.Message -join '; ')"
    }
}

Invoke-Test 'workflow installs into distinct owned directories with a bounded retry' {
    Assert-InstallerPolicy -Action $action -Workflow $workflow
}

Invoke-Test 'policy rejects unsafe retries and missed workflow triggers' {
    $mutations = @(
        {
            param(
                $copy
            )
            $copy.runs.steps[3].env.DOTNET_INSTALL_DIR = $copy.runs.steps[1].env.DOTNET_INSTALL_DIR
        },
        {
            param(
                $copy
            )
            $copy.runs.steps[3].env.TMPDIR = $copy.runs.steps[1].env.TMPDIR
        },
        {
            param(
                $copy
            )
            $copy.runs.steps[3].'continue-on-error' = $true
        },
        {
            param(
                $copy
            )
            $copy.runs.steps[3].if = "steps.first.conclusion == 'failure'"
        },
        {
            param(
                $copy
            )
            $copy.runs.steps[1].with.'global-json-file' = 'different.json'
        },
        {
            param(
                $copy
            )
            $copy.runs.steps[3].uses = 'actions/setup-dotnet@v6'
        }
    )
    foreach ($mutate in $mutations) {
        $copy = $action | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
        & $mutate $copy
        Assert-Throws { Assert-InstallerPolicy -Action $copy -Workflow $workflow }
    }
    $copy = $workflow | ConvertTo-Json -Depth 60 | ConvertFrom-Json -AsHashtable
    $copy.on.pull_request.paths = @('.github/workflows/build.yml')
    Assert-Throws { Assert-InstallerPolicy -Action $action -Workflow $copy }
}

# Execute the actual inline preparation and verification logic. Only native
# process execution and command lookup are replaced with fixtures; selection,
# exit-code propagation, SDK resolution and architecture assertions stay intact.
$prepare = ($action.runs.steps | Where-Object id -CEQ 'prepare').run
$verify = ($action.runs.steps | Where-Object name -CEQ 'Verify the selected Arm64 .NET host').run
Assert-True ($verify.Contains('& $dotnet --version')) 'Run the selected executable for SDK resolution.'
Assert-True ($verify.Contains('& $dotnet --info')) 'Run the selected executable for architecture verification.'
$verifyFixture = $verify.Replace('Get-Command dotnet', '$script:ResolvedCommand')
$verifyFixture = $verifyFixture.Replace('& $dotnet --version', "Invoke-DotnetFixture `$dotnet '--version'")
$verifyFixture = $verifyFixture.Replace('& $dotnet --info', "Invoke-DotnetFixture `$dotnet '--info'")

function Invoke-DotnetFixture {
    param(
        [string] $Executable,
        [string] $Argument
    )

    Assert-Equal (Join-Path $env:DOTNET_ROOT 'dotnet') $Executable
    if ($Argument -ceq '--version') {
        $global:LASTEXITCODE = $script:VersionExitCode
        return $script:ReportedVersion
    }
    $global:LASTEXITCODE = $script:InfoExitCode
    "Architecture: $script:ReportedArchitecture"
}

$savedEnvironment = @{}
foreach ($key in @('RUNNER_TEMP', 'GITHUB_OUTPUT', 'FIRST_OUTCOME', 'RETRY_OUTCOME', 'INSTALL_ROOT', 'DOTNET_ROOT', 'GLOBAL_JSON_FILE', 'GITHUB_STEP_SUMMARY', 'PATH')) {
    $savedEnvironment[$key] = [Environment]::GetEnvironmentVariable($key)
}
$directory = New-TestDirectory
try {
    $env:RUNNER_TEMP = $directory
    $env:GITHUB_OUTPUT = Join-Path $directory 'output.txt'
    & ([scriptblock]::Create($prepare))
    $env:INSTALL_ROOT = (Get-Content -LiteralPath $env:GITHUB_OUTPUT).Substring('root='.Length)
    foreach ($attempt in @('first', 'retry')) {
        foreach ($name in @('install', 'temp')) {
            Assert-True (Test-Path -LiteralPath "$env:INSTALL_ROOT/$attempt/$name" -PathType Container)
        }
    }
    $env:GLOBAL_JSON_FILE = Join-Path $directory 'global.json'
    '{"sdk":{"version":"42.0.123"}}' | Set-Content -LiteralPath $env:GLOBAL_JSON_FILE
    $script:VersionExitCode = 0
    $script:InfoExitCode = 0
    $script:ReportedVersion = '42.0.123'
    $script:ReportedArchitecture = 'arm64'
    $verifyScript = [scriptblock]::Create($verifyFixture)

    Invoke-Test 'verification selects either successful attempt and checks its SDK and host' {
        foreach ($attempt in @('first', 'retry')) {
            $env:FIRST_OUTCOME = if ($attempt -ceq 'first') {
                'success'
            }
            else {
                'failure'
            }
            $env:RETRY_OUTCOME = if ($attempt -ceq 'first') {
                'skipped'
            }
            else {
                'success'
            }
            $env:DOTNET_ROOT = "$env:INSTALL_ROOT/$attempt/install"
            $script:ResolvedCommand = @{
                CommandType = [Management.Automation.CommandTypes]::Application
                Source = Join-Path $env:DOTNET_ROOT 'dotnet'
            }
            & $verifyScript
        }
    }

    Invoke-Test 'verification rejects a stale root or PATH, missing SDK, bad exit and wrong architecture' {
        $env:DOTNET_ROOT = "$env:INSTALL_ROOT/first/install"
        Assert-Throws { & $verifyScript } '*DOTNET_ROOT*'
        $env:DOTNET_ROOT = "$env:INSTALL_ROOT/retry/install"
        $script:ResolvedCommand.Source = '/usr/local/share/dotnet/dotnet'
        Assert-Throws { & $verifyScript } '*PATH*'
        $script:ResolvedCommand.Source = Join-Path $env:DOTNET_ROOT 'dotnet'
        $script:ResolvedCommand.CommandType = [Management.Automation.CommandTypes]::Function
        Assert-Throws { & $verifyScript } '*resolves to Function*'
        $script:ResolvedCommand.CommandType = [Management.Automation.CommandTypes]::Application
        $script:VersionExitCode = 145
        Assert-Throws { & $verifyScript } '*SDK failed with exit code 145*'
        $script:VersionExitCode = 0
        $script:ReportedVersion = '42.0.999'
        Assert-Throws { & $verifyScript } '*Expected SDK 42.0.123*'
        $script:ReportedVersion = '42.0.123'
        $script:InfoExitCode = 1
        Assert-Throws { & $verifyScript } '*host failed with exit code 1*'
        $script:InfoExitCode = 0
        $script:ReportedArchitecture = 'x64'
        Assert-Throws { & $verifyScript } '*host is not Arm64*'
        $script:ReportedArchitecture = 'arm64'
        $env:RETRY_OUTCOME = 'failure'
        Assert-Throws { & $verifyScript } '*Neither isolated*'
    }

    Invoke-Test 'real command lookup selects one executable despite multiple native PATH candidates' {
        $fixtureName = if ($IsWindows) {
            'dotnet.exe'
        }
        else {
            'dotnet'
        }
        foreach ($attempt in @('first', 'retry')) {
            $fixturePath = "$env:INSTALL_ROOT/$attempt/install/$fixtureName"
            Copy-Item -LiteralPath (Get-Process -Id $PID).Path -Destination $fixturePath
        }
        # Exercise the actual selection gate with real executable files, without
        # launching the copied host or depending on an installed .NET SDK.
        $pathGate = $verify.Substring($verify.IndexOf('$resolvedCommand = Get-Command dotnet'))
        $pathGate = $pathGate.Substring(0, $pathGate.IndexOf('$version = & $dotnet --version'))
        $pathGateScript = [scriptblock]::Create($pathGate)
        $dotnet = "$env:INSTALL_ROOT/retry/install/$fixtureName"
        $env:PATH = @("$env:INSTALL_ROOT/retry/install", "$env:INSTALL_ROOT/first/install", $savedEnvironment.PATH) -join [IO.Path]::PathSeparator
        Assert-True (@(Get-Command dotnet -CommandType Application).Count -ge 2) 'Require multiple native PATH candidates.'
        & $pathGateScript

        $allMatches = [scriptblock]::Create($pathGate.Replace('Get-Command dotnet', 'Get-Command dotnet -CommandType Application'))
        Assert-Throws { & $allMatches } '*PATH selects*'
        $env:PATH = @("$env:INSTALL_ROOT/first/install", "$env:INSTALL_ROOT/retry/install", $savedEnvironment.PATH) -join [IO.Path]::PathSeparator
        Assert-Throws { & $pathGateScript } '*PATH selects*first/install/*expected*retry/install/*'
        Set-Alias -Name dotnet -Value Get-Date
        try {
            Assert-Throws { & $pathGateScript } '*resolves to Alias*'
        }
        finally {
            Remove-Item -LiteralPath Alias:dotnet
        }
    }

    Invoke-Test 'failed diagnostic writes and native commands cannot prevent the clean retry' {
        $diagnostics = ($action.runs.steps | Where-Object name -CEQ 'Report the failed installation and filesystem diagnostics').run
        $env:GITHUB_STEP_SUMMARY = Join-Path $directory 'missing/summary.txt'
        $global:LASTEXITCODE = 9
        & ([scriptblock]::Create($diagnostics))
        Assert-Equal 0 $LASTEXITCODE

        $env:GITHUB_STEP_SUMMARY = Join-Path $directory 'summary.txt'
        $diagnostics = $diagnostics.Replace('& /bin/df -h 2>&1', '$global:LASTEXITCODE = 7; "df failed"')
        $diagnostics = $diagnostics.Replace('& /usr/bin/log show --last 2m --style compact --predicate $predicate 2>&1', '$global:LASTEXITCODE = 8; "log failed"')
        & ([scriptblock]::Create($diagnostics))
        Assert-Equal 0 $LASTEXITCODE
    }
}
finally {
    foreach ($key in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($key, $savedEnvironment[$key])
    }
    Remove-Item -LiteralPath $directory -Recurse -Force
}

Write-Host "PASS: $script:TestCount macOS .NET installer checks."
