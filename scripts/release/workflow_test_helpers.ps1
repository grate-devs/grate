$ErrorActionPreference = 'Stop'
Import-Module powershell-yaml -RequiredVersion 0.4.12 -ErrorAction Stop
$repositoryRoot = Split-Path (Split-Path $PSScriptRoot)
function Resolve-WorkflowValue {
    param(
        [AllowNull()]
        [object]$Value,
        [System.Collections.IDictionary]$Inputs
    )

    if ($Value -is [System.Collections.IDictionary]) {
        $resolved = @{}
        foreach ($key in $Value.Keys) {
            $resolved[$key] = Resolve-WorkflowValue -Value $Value[$key] -Inputs $Inputs
        }
        return $resolved
    }
    if ($Value -is [array] -or $Value -is [System.Collections.IList]) {
        $resolved = [Collections.Generic.List[object]]::new()
        foreach ($item in $Value) {
            $resolved.Add((Resolve-WorkflowValue -Value $item -Inputs $Inputs))
        }
        return ,$resolved.ToArray()
    }
    if ($Value -isnot [string]) {
        return $Value
    }
    if ($Value -cmatch '^\$\{\{\s*fromJSON\(inputs\.([\w-]+)\)\s*\}\}$') {
        $inputName = $Matches[1]
        if (!$Inputs.Contains($inputName)) {
            throw "Unknown reusable input '$inputName'."
        }
        # Static matrix JSON is supplied literally by the caller. Do not guess
        # values computed by GitHub contexts at runtime.
        return ,(ConvertFrom-Json -InputObject $Inputs[$inputName] -NoEnumerate)
    }
    $direct = [regex]::Match($Value, '^\$\{\{\s*inputs\.([\w-]+)\s*\}\}$')
    if ($direct.Success) {
        $inputName = $direct.Groups[1].Value
        if (!$Inputs.Contains($inputName)) {
            throw "Unknown reusable input '$inputName'."
        }
        return $Inputs[$inputName]
    }
    $resolved = [regex]::Replace($Value, '\$\{\{\s*inputs\.([\w-]+)\s*\}\}', {
        param($match)
        $inputName = $match.Groups[1].Value
        if (!$Inputs.Contains($inputName)) {
            throw "Unknown reusable input '$inputName'."
        }
        if ($Inputs[$inputName] -is [bool]) {
            return $Inputs[$inputName].ToString().ToLowerInvariant()
        }
        return [string]$Inputs[$inputName]
    })
    $resolved = [regex]::Replace($resolved, '\$\{\{(?<body>.*?)\}\}', {
        param($expression)
        # Preserve quoted GitHub literals and unwrap supplied context expressions.
        $body = [regex]::Replace($expression.Groups['body'].Value, "'(?:[^']|'')*'|(?<input>\binputs\.(?<name>[\w-]+))", {
            param($token)
            if (!$token.Groups['input'].Success) {
                return $token.Value
            }
            $name = $token.Groups['name'].Value
            if (!$Inputs.Contains($name)) {
                throw "Unknown reusable input '$name'."
            }
            $value = $Inputs[$name]
            if ($value -is [bool]) {
                return $value.ToString().ToLowerInvariant()
            }
            if ($value -is [ValueType]) {
                return [Convert]::ToString($value, [Globalization.CultureInfo]::InvariantCulture)
            }
            if ($value -cmatch '^\$\{\{\s*(?<context>.*?)\s*\}\}$') {
                $context = $Matches['context'].Trim()
                if ($context -cmatch '^[\w-]+(?:\.[\w-]+)*$') {
                    return $context
                }
                return "($context)"
            }
            return "'" + ([string]$value).Replace("'", "''") + "'"
        })
        return '${{' + $body + '}}'
    })
    return $resolved
}

function Get-WorkflowInputs {
    param(
        [System.Collections.IDictionary]$Call,
        [System.Collections.IDictionary]$Declaration
    )

    $supplied = $Call['with']
    $definitions = $Declaration['inputs']
    $inputs = @{}
    if (!$supplied) {
        $supplied = @{}
    }
    if (!$definitions) {
        $definitions = @{}
    }
    foreach ($name in $supplied.Keys) {
        if (!$definitions.Contains($name)) {
            throw "Unknown forwarded reusable input '$name'."
        }
    }
    foreach ($name in $definitions.Keys) {
        $definition = $definitions[$name]
        if ($supplied.Contains($name)) {
            $inputs[$name] = $supplied[$name]
        } elseif ($definition['required']) {
            throw "Missing required reusable input '$name'."
        } elseif ($definition.Contains('default')) {
            $inputs[$name] = $definition['default']
        } else {
            $inputs[$name] = switch ($definition['type']) {
                'boolean' {
                    $false
                }
                'number' {
                    0
                }
                default {
                    ''
                }
            }
        }
    }
    return $inputs
}

function Read-Workflow {
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [switch]$Raw,
        [string]$Root = $repositoryRoot
    )

    $workflow = Get-Content -LiteralPath (Join-Path $Root ".github/workflows/$Name") -Raw | ConvertFrom-Yaml
    if ($Raw) {
        return $workflow
    }
    foreach ($jobId in @($workflow.jobs.Keys)) {
        $call = $workflow.jobs[$jobId]
        if (!$call['uses']) {
            continue
        }
        # This bounded policy view follows same-commit, one-job reusable phases.
        # Keep raw calls available for independent forwarding/trust-edge tests.
        if ($call['uses'] -cnotmatch '^\./\.github/workflows/([\w-]+\.ya?ml)$') {
            throw "Unsupported reusable workflow reference: $($call['uses'])"
        }
        $file = $Matches[1]
        $child = Read-Workflow -Name $file -Root $Root -Raw
        if (!$child['on'].Contains('workflow_call') -or $child.jobs.Count -ne 1) {
            throw "Reusable policy phases require workflow_call and exactly one leaf job: $file"
        }
        $declaration = $child['on']['workflow_call']
        if (!$declaration) {
            $declaration = @{}
        }
        $inputs = Get-WorkflowInputs -Call $call -Declaration $declaration
        $leafId = @($child.jobs.Keys)[0]
        $leaf = Resolve-WorkflowValue -Value $child.jobs[$leafId] -Inputs $inputs
        if ($leaf['uses'] -or $leaf['needs']) {
            throw "Reusable policy phase must contain a self-contained leaf job: $file"
        }
        if ($leaf['if']) {
            # Call scheduling and this additional leaf guard are distinct scopes.
            # Keep both for policy tests without rewriting status functions.
            $leaf['_workflowLeafIf'] = $leaf['if']
        }
        foreach ($field in @('needs', 'if')) {
            if ($call.Contains($field)) {
                $leaf[$field] = $call[$field]
            }
        }
        $callerPermissions = $call['permissions']
        if (!$call.Contains('permissions')) {
            $callerPermissions = $workflow['permissions']
        }
        $childPermissions = $leaf['permissions']
        if (!$leaf.Contains('permissions')) {
            $childPermissions = $child['permissions']
        }
        if ($null -eq $childPermissions) {
            $childPermissions = $callerPermissions
        }
        if ($callerPermissions -is [System.Collections.IDictionary] -and
            $childPermissions -is [System.Collections.IDictionary]) {
            $levels = @{ none = 0; read = 1; write = 2 }
            $permissions = @{}
            foreach ($scope in $childPermissions.Keys) {
                $permission = $childPermissions[$scope]
                $cap = $callerPermissions[$scope]
                if (!$cap -or $levels[$cap] -lt $levels[$permission]) {
                    $permission = if ($cap) {
                        $cap
                    } else {
                        'none'
                    }
                }
                $permissions[$scope] = $permission
            }
            $leaf['permissions'] = $permissions
        } elseif ($callerPermissions -or $childPermissions) {
            throw "Unsupported reusable token permission shape: $file"
        }
        # Workflow env does not cross workflow_call. Only the child's own env
        # and its leaf's overrides apply; input forwarding must remain explicit.
        $environment = @{}
        if ($child['env']) {
            $environment = Resolve-WorkflowValue -Value $child['env'] -Inputs $inputs
        }
        if ($leaf['env']) {
            foreach ($key in $leaf['env'].Keys) {
                $environment[$key] = $leaf['env'][$key]
            }
        }
        if ($environment.Count) {
            $leaf['env'] = $environment
        }
        if (!$leaf['defaults'] -and $child['defaults']) {
            $leaf['defaults'] = Resolve-WorkflowValue -Value $child['defaults'] -Inputs $inputs
        }
        $outputs = @{}
        if ($declaration['outputs']) {
            foreach ($name in $declaration['outputs'].Keys) {
                $value = $declaration['outputs'][$name]['value']
                if ($value -cnotmatch ('^\$\{\{\s*jobs\.' + [regex]::Escape($leafId) + '\.outputs\.([\w-]+)\s*\}\}$') -or
                    !$leaf['outputs'] -or !$leaf['outputs'].Contains($Matches[1])) {
                    throw "Invalid reusable output mapping '$name' in $file."
                }
                $outputs[$name] = $leaf['outputs'][$Matches[1]]
            }
        }
        if ($leaf['outputs'] -or $outputs.Count) {
            $leaf['outputs'] = $outputs
        }
        if ($call['strategy'] -and $leaf['strategy']) {
            throw "Review nested reusable matrices explicitly: $file"
        }
        if ($call['strategy']) {
            $leaf['strategy'] = $call['strategy']
        }
        $leaf['_workflowCall'] = $call
        $leaf['_workflowFile'] = $file
        $leaf['_workflowJobId'] = $leafId
        $workflow.jobs[$jobId] = $leaf
    }
    return $workflow
}
function Assert-Policy([bool]$Condition, [string]$Message) {
    if (!$Condition) { throw $Message }
}
function Get-ActionStep($Job, [string]$Action) {
    $Job.steps | Where-Object { $_['uses'] -like "$Action@*" } | Select-Object -First 1
}
