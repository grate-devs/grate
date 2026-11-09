#!/usr/bin/env pwsh
. "$PSScriptRoot/workflow_test_helpers.ps1"

$state = Join-Path ([IO.Path]::GetTempPath()) ('grate-workflow-policy-' + [guid]::NewGuid().ToString('N'))
$workflowDirectory = Join-Path $state '.github/workflows'
New-Item -ItemType Directory -Path $workflowDirectory -Force | Out-Null
$caller = @'
on: workflow_dispatch
permissions:
  contents: write
env:
  CALLER_ONLY: never-inherited
jobs:
  package:
    name: Package caller
    needs: policy
    if: ${{ always() && needs.policy.result == 'success' }}
    uses: ./.github/workflows/phase.yml
    with:
      version: ${{ needs.context.outputs.version }}
      runtimes: '["linux-x64", "linux-arm64"]'
      native: true
'@
$child = @'
on:
  workflow_call:
    inputs:
      version: { type: string, required: true }
      runtimes: { type: string, required: true }
      native: { type: boolean, default: false }
      optional: { type: string }
    outputs:
      digest:
        value: ${{ jobs.main.outputs.digest }}
permissions:
  contents: write
  id-token: write
env:
  CHILD: workflow-default
  VERSION: ${{ inputs.version }}
defaults:
  run:
    shell: pwsh
jobs:
  main:
    name: Package producer
    if: ${{ inputs.native && startsWith(github.workflow_ref, 'grate-devs/grate/') }}
    runs-on: ubuntu-latest
    env:
      CHILD: leaf-override
      NATIVE: ${{ inputs.native }}
    strategy:
      matrix:
        arch: ${{ fromJSON(inputs.runtimes) }}
    outputs:
      digest: ${{ steps.image.outputs.digest }}
    steps:
      - run: echo '${{ inputs.version }}'
        if: ${{ !inputs.native }}
      - run: echo '${{ inputs.optional }}'
        name: ${{ format('package-{0}', inputs.version) }}
'@

function Write-Fixture {
    param(
        [string]$Caller = $caller,
        [string]$Child = $child
    )

    Set-Content -LiteralPath (Join-Path $workflowDirectory 'caller.yml') -Value $Caller -Encoding utf8NoBOM
    Set-Content -LiteralPath (Join-Path $workflowDirectory 'phase.yml') -Value $Child -Encoding utf8NoBOM
}

function Assert-ResolverRejected {
    param(
        [string]$Message
    )

    try {
        $null = Read-Workflow -Name 'caller.yml' -Root $state
    } catch {
        if ($_.Exception.Message -like "*$Message*") {
            return
        }
        throw
    }
    throw "Expected reusable resolver rejection: $Message"
}

try {
    Write-Fixture
    $raw = Read-Workflow -Name 'caller.yml' -Root $state -Raw
    Assert-Policy ($raw.jobs.package.uses -ceq './.github/workflows/phase.yml') 'Raw caller edges must remain inspectable.'
    $job = (Read-Workflow -Name 'caller.yml' -Root $state).jobs.package
    Assert-Policy ($job.name -ceq 'Package producer' -and $job.needs -ceq 'policy') 'Preserve leaf identity and caller scheduling.'
    Assert-Policy ($job.if -ceq $raw.jobs.package.if -and $job._workflowLeafIf.Contains('true && startsWith')) 'Keep both condition scopes without rewriting status functions.'
    Assert-Policy ($job._workflowCall.uses -ceq $raw.jobs.package.uses -and $job._workflowJobId -ceq 'main' -and $job._workflowFile -ceq 'phase.yml') 'Retain raw call/leaf provenance.'
    Assert-Policy (!$job.env.Contains('CALLER_ONLY') -and $job.env.CHILD -ceq 'leaf-override') 'Caller workflow env must not cross workflow_call; leaf env overrides child defaults.'
    Assert-Policy ($job.env.VERSION -ceq '${{ needs.context.outputs.version }}' -and $job.env.NATIVE -is [bool] -and $job.env.NATIVE) 'Preserve forwarded context expressions and boolean types.'
    Assert-Policy (($job.strategy.matrix.arch -join ',') -ceq 'linux-x64,linux-arm64') 'Expand literal JSON matrix inputs.'
    Assert-Policy ($job.permissions.contents -ceq 'write' -and $job.permissions.'id-token' -ceq 'none') 'Child permissions cannot exceed the caller grant.'
    Assert-Policy ($job.defaults.run.shell -ceq 'pwsh') 'Child workflow shell defaults apply to its leaf.'
    Assert-Policy ($job.outputs.digest -ceq '${{ steps.image.outputs.digest }}') 'Expose only correctly exported leaf outputs.'
    Assert-Policy ($job.steps[0].run -ceq "echo '`${{ needs.context.outputs.version }}'" -and $job.steps[0].if -ceq '${{ !true }}') 'Resolve embedded inputs and boolean negation.'
    Assert-Policy ($job.steps[1].run -ceq "echo ''" -and $job.steps[1].name -ceq '${{ format(''package-{0}'', needs.context.outputs.version) }}') 'Resolve optional defaults and input references inside expressions.'

    Write-Fixture -Caller ($caller.Replace("    with:", "    permissions: {}`n    with:"))
    $capped = (Read-Workflow -Name 'caller.yml' -Root $state).jobs.package
    Assert-Policy ($capped.permissions.contents -ceq 'none') 'An explicit empty caller grant must not inherit workflow write permission.'

    Write-Fixture -Caller ($caller.Replace('["linux-x64", "linux-arm64"]', '["linux-x64"]'))
    $single = (Read-Workflow -Name 'caller.yml' -Root $state).jobs.package.strategy.matrix.arch
    Assert-Policy ($single -is [array] -and $single.Count -eq 1 -and $single[0] -ceq 'linux-x64') 'A one-element matrix must keep its array shape.'

    Write-Fixture -Caller ($caller.Replace('      version: ${{ needs.context.outputs.version }}', ''))
    Assert-ResolverRejected 'Missing required reusable input'
    Write-Fixture -Caller ($caller.Replace('      native: true', "      native: true`n      unknown: value"))
    Assert-ResolverRejected 'Unknown forwarded reusable input'
    Write-Fixture -Child ($child.Replace('inputs.optional', 'inputs.missing'))
    Assert-ResolverRejected 'Unknown reusable input'
    Write-Fixture -Child ($child.Replace('jobs.main.outputs.digest', 'jobs.other.outputs.digest'))
    Assert-ResolverRejected 'Invalid reusable output mapping'
    Write-Fixture -Child ($child.Replace('jobs:', "jobs:`n  another:`n    runs-on: ubuntu-latest`n    steps: [{ run: echo unexpected }]"))
    Assert-ResolverRejected 'exactly one leaf job'
    Write-Fixture -Caller ($caller.Replace('./.github/workflows/phase.yml', 'other/repository/.github/workflows/phase.yml@main'))
    Assert-ResolverRejected 'Unsupported reusable workflow reference'
    Write-Host 'PASS: reusable workflow input/matrix/output bindings, permissions, env and condition scopes; six invalid wiring fixtures rejected.'
} finally {
    Remove-Item -LiteralPath $state -Recurse -Force
}
