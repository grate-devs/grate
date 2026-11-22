param(
    [string] $UpdateType,
    [object[]] $Dependencies,
    [object] $Commit,
    [string] $ExpectedHead
)

$allowedTypes = @('version-update:semver-patch', 'version-update:semver-minor')
if ($UpdateType -cnotin $allowedTypes -or $Dependencies.Count -lt 1 -or
    $ExpectedHead -cnotmatch '^[0-9a-f]{40}$' -or $Commit.sha -cne $ExpectedHead -or
    $Commit.author.login -cne 'dependabot[bot]' -or $Commit.committer.login -cne 'web-flow' -or
    $Commit.commit.verification.verified -isnot [bool] -or !$Commit.commit.verification.verified) {
    return $false
}

# fetch-metadata reads the first live PR commit and may infer a missing type
# from the PR title. Corroborate each entry against the signed event-head SHA.
# Accept only the simple list emitted by Dependabot for NuGet and Actions.
$block = [regex]::Matches($Commit.commit.message, '(?ms)^---\nupdated-dependencies:\n(?<items>.*?)^\.\.\.(?:\n|$)')
if ($block.Count -ne 1) {
    return $false
}

$items = [regex]::Split($block[0].Groups['items'].Value.TrimEnd(), '(?m)^- dependency-name: ')
if ($items[0] -cne '' -or $items.Count -ne $Dependencies.Count + 1) {
    return $false
}

for ($index = 0; $index -lt $Dependencies.Count; $index++) {
    $dependency = $Dependencies[$index]
    $lines = $items[$index + 1].TrimEnd() -split '\n'
    $types = @($lines | Where-Object { $_ -cmatch '^  update-type: ' })
    if ($dependency.updateType -cnotin $allowedTypes -or $lines[0] -cne $dependency.dependencyName -or
        $types.Count -ne 1 -or $types[0] -cne "  update-type: $($dependency.updateType)") {
        return $false
    }

    # Reject alternate list entries or nested YAML with uninspected updates.
    foreach ($line in ($lines | Select-Object -Skip 1)) {
        if ($line -cnotmatch '^  (dependency-version|dependency-type|update-type|dependency-group): [\w./:+-]+$') {
            return $false
        }
    }
}

return $true
