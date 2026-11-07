# Shared release I/O. Keep registry/tool response bodies out of error messages.
$ErrorActionPreference = 'Stop'
$script:ManifestAccept = @(
    'application/vnd.oci.image.index.v1+json'
    'application/vnd.docker.distribution.manifest.list.v2+json'
    'application/vnd.oci.image.manifest.v1+json'
    'application/vnd.docker.distribution.manifest.v2+json'
) -join ', '

$script:SemVerNumber = '(?:0|[1-9][0-9]*)'
$script:SemVerIdentifier = "(?:$script:SemVerNumber|[0-9]*[A-Za-z-][0-9A-Za-z-]*)"
$script:SemVerPattern = "$script:SemVerNumber\.$script:SemVerNumber\.$script:SemVerNumber(?:-$script:SemVerIdentifier(?:\.$script:SemVerIdentifier)*)?"

function Get-Timestamp {
    [DateTimeOffset]::UtcNow.ToString('o')
}

function Write-ReleaseJson {
    param(
        [string]$Path,
        $Value
    )

    $full = [IO.Path]::GetFullPath($Path)
    $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full))
    $temporaryPath = "$full.tmp"
    $json = $Value | ConvertTo-Json -Depth 100

    Set-Content -LiteralPath $temporaryPath -Value ($json + "`n") -NoNewline -Encoding utf8NoBOM
    # Replace the complete journal only after its temporary file is written.
    [IO.File]::Move($temporaryPath, $full, $true)
}

function Get-ByteDigest {
    param(
        [byte[]]$Bytes
    )

    'sha256:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Get-JsonBytes {
    param(
        $Value
    )

    $json = $Value | ConvertTo-Json -Depth 100 -Compress
    ,([Text.Encoding]::UTF8.GetBytes($json))
}

function Sort-ReleaseTags {
    param(
        $Tags
    )

    $sorted = [string[]]@($Tags)
    [Array]::Sort($sorted, [StringComparer]::Ordinal)

    $sorted | Where-Object { $_ -cne 'latest' }
    if ($sorted -ccontains 'latest') {
        'latest'
    }
}

function Test-JsonEqual {
    param(
        $Left,
        $Right
    )

    # Normalize property order recursively: JSON object order is not identity.
    function ConvertTo-Canonical {
        param(
            $Value
        )

        if ($Value -is [Collections.IDictionary]) {
            $result = [Collections.Specialized.OrderedDictionary]::new([StringComparer]::Ordinal)
            foreach ($key in @($Value.Keys | Sort-Object -CaseSensitive)) {
                $result[$key] = ConvertTo-Canonical $Value[$key]
            }
            return $result
        }
        if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
            return ,@($Value | ForEach-Object { ConvertTo-Canonical $_ })
        }
        return $Value
    }
    $leftJson = ConvertTo-Canonical $Left | ConvertTo-Json -Depth 100 -Compress
    $rightJson = ConvertTo-Canonical $Right | ConvertTo-Json -Depth 100 -Compress
    return $leftJson -ceq $rightJson
}

function Invoke-ReleaseProcess {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [int]$TimeoutSeconds = 1200
    )

    $info = [Diagnostics.ProcessStartInfo]::new($FilePath)
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($argument in $Arguments) {
        $info.ArgumentList.Add($argument)
    }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $info
    $memory = [IO.MemoryStream]::new()

    try {
        if (!$process.Start()) {
            throw 'Process could not start.'
        }
        $stdout = $process.StandardOutput.BaseStream.CopyToAsync($memory)
        $stderr = $process.StandardError.ReadToEndAsync()

        if (!$process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw 'Process timed out.'
        }

        $stdout.GetAwaiter().GetResult()
        $errorText = $stderr.GetAwaiter().GetResult()
        return @{
            ExitCode = $process.ExitCode
            ErrorText = $errorText
            Bytes = $memory.ToArray()
            Text = [Text.Encoding]::UTF8.GetString($memory.ToArray())
        }
    } finally {
        $memory.Dispose()
        $process.Dispose()
    }
}

function Invoke-Skopeo {
    param(
        [string[]]$Arguments,
        [string]$Operation
    )

    try {
        $result = Invoke-ReleaseProcess 'skopeo' $Arguments
    } catch {
        throw "Skopeo $Operation could not complete."
    }
    if ($result.ExitCode -ne 0) {
        throw "Skopeo $Operation failed."
    }
    return ,$result.Bytes
}

function Invoke-ReleaseHttp {
    param(
        [string]$Uri,
        [hashtable]$Headers = @{},
        [string]$Method = 'GET',
        [switch]$NoRedirects,
        [int]$TimeoutSeconds = 60,
        [int]$MaxBytes = 0
    )

    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)

    try {
        $requestHeaders = $Headers.Clone()

        for ($redirect = 0; $redirect -le 10; $redirect++) {
            $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method), $Uri)
            foreach ($key in $requestHeaders.Keys) {
                $null = $request.Headers.TryAddWithoutValidation($key, [string]$requestHeaders[$key])
            }

            $response = $null
            try {
                $response = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
                $status = [int]$response.StatusCode

                if ($status -in @(301, 302, 303, 307, 308) -and !$NoRedirects) {
                    $target = [Uri]::new([Uri]$Uri, $response.Headers.Location)
                    if ($target.Scheme -cne 'https') {
                        throw 'Refused a non-HTTPS redirect.'
                    }
                    $Uri = $target.AbsoluteUri
                    $requestHeaders.Remove('Authorization')
                    continue
                }
                if (!$response.IsSuccessStatusCode) {
                    $error = [InvalidOperationException]::new("Registry/Hub HTTP $status")
                    $error.Data['StatusCode'] = $status
                    throw $error
                }

                $headersOut = @{}
                foreach ($header in $response.Headers) {
                    $headersOut[$header.Key] = $header.Value -join ', '
                }

                $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                $memory = [IO.MemoryStream]::new()

                try {
                    $buffer = [byte[]]::new(8192)
                    while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                        $memory.Write($buffer, 0, $read)
                        if ($MaxBytes -gt 0 -and $memory.Length -gt $MaxBytes) {
                            throw 'Response exceeds the permitted size.'
                        }
                    }
                    return @{
                        StatusCode = $status
                        Headers = $headersOut
                        Bytes = $memory.ToArray()
                    }
                } finally {
                    $memory.Dispose()
                    $stream.Dispose()
                }
            } finally {
                if ($response) {
                    $response.Dispose()
                }
                $request.Dispose()
            }
        }
        throw 'Too many HTTP redirects.'
    } finally {
        $client.Dispose()
    }
}

function ConvertFrom-ResponseJson {
    param(
        $Response
    )

    [Text.Encoding]::UTF8.GetString($Response.Bytes) | ConvertFrom-Json -AsHashtable
}

function Get-DockerTagNames {
    param(
        [string]$Repository
    )

    $prefix = "https://hub.docker.com/v2/repositories/$Repository/tags"
    $url = "$prefix`?page_size=100"
    $visited = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $tags = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)

    while ($url) {
        if (!$visited.Add($url) -or !($url.StartsWith("$prefix`?", [StringComparison]::Ordinal) -or $url.StartsWith("$prefix/?", [StringComparison]::Ordinal))) {
            throw 'Unexpected Hub pagination URL.'
        }
        $page = ConvertFrom-ResponseJson (Invoke-ReleaseHttp $url -TimeoutSeconds 45)
        foreach ($item in $page.results) {
            if ($item.name -cnotmatch '\A[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}\z') {
                throw 'Unexpected Docker tag syntax.'
            }
            $null = $tags.Add($item.name)
        }
        $url = $page.next
    }
    Sort-ReleaseTags $tags
}

function New-Registry {
    param(
        [string]$Repository
    )

    @{
        Repository = $Repository
        Token = $null
        TokenExpiry = [DateTimeOffset]::MinValue
        Manifests = @{}
        Configs = @{}
        CheckedBlobs = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    }
}

function Get-RegistryAuthorization {
    param(
        $Registry
    )

    if ([DateTimeOffset]::UtcNow -ge $Registry.TokenExpiry) {
        $headers = @{}
        if ([bool]$env:DOCKER_HUB_USER -ne [bool]$env:DOCKER_HUB_TOKEN) {
            throw 'Both Docker credential variables are required together.'
        }
        if ($env:DOCKER_HUB_USER) {
            $headers.Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($env:DOCKER_HUB_USER):$($env:DOCKER_HUB_TOKEN)"))
        }

        $scope = [Uri]::EscapeDataString("repository:$($Registry.Repository):pull")
        $data = ConvertFrom-ResponseJson (Invoke-ReleaseHttp "https://auth.docker.io/token?service=registry.docker.io&scope=$scope" $headers -NoRedirects -TimeoutSeconds 45)
        $Registry.Token = if ($data.token) {
            $data.token
        } else {
            $data.access_token
        }
        $expiry = if ($data.ContainsKey('expires_in')) {
            [int]$data.expires_in
        } else {
            60
        }
        $Registry.TokenExpiry = [DateTimeOffset]::UtcNow.AddSeconds([Math]::Max(1, $expiry - 15))
    }
    'Bearer ' + $Registry.Token
}

function Invoke-RegistryRequest {
    param(
        $Registry,
        [string]$Resource,
        [string]$Method = 'GET',
        [int]$MaxBytes = 0
    )

    if ($Registry.Request) {
        return & $Registry.Request $Resource $Method $MaxBytes
    }
    Invoke-ReleaseHttp "https://registry-1.docker.io/v2/$($Registry.Repository)/$Resource" @{
        Authorization = Get-RegistryAuthorization $Registry
        Accept = $script:ManifestAccept
    } $Method -MaxBytes $MaxBytes
}

function Get-RegistryDigest {
    param(
        $Registry,
        [string]$Tag
    )

    $response = Invoke-RegistryRequest $Registry "manifests/$Tag" 'HEAD'
    $digest = $response.Headers['Docker-Content-Digest']
    if ($digest -cnotmatch '\Asha256:[a-f0-9]{64}\z') {
        throw 'Registry did not provide a valid manifest digest.'
    }
    $digest
}

function Get-RegistryManifest {
    param(
        $Registry,
        [string]$Reference
    )

    if (!$Reference.StartsWith('sha256:', [StringComparison]::Ordinal)) {
        $Reference = Get-RegistryDigest $Registry $Reference
    }
    if ($Registry.Manifests.ContainsKey($Reference)) {
        return $Registry.Manifests[$Reference]
    }
    $response = Invoke-RegistryRequest $Registry "manifests/$Reference"
    $digest = Get-ByteDigest $response.Bytes
    $header = $response.Headers['Docker-Content-Digest']
    if ($header -and $header -cne $digest) {
        throw 'Registry manifest header and body digest disagree.'
    }
    if ($Reference -cne $digest) {
        throw 'Returned manifest differs from requested digest.'
    }
    $data = ConvertFrom-ResponseJson $response
    if ($data.schemaVersion -ne 2) {
        throw 'Unsupported historical manifest schema.'
    }

    $result = @{
        Digest = $digest
        Data = $data
    }
    $Registry.Manifests[$digest] = $result
    $result
}

function Get-RegistryConfig {
    param(
        $Registry,
        [string]$Digest
    )

    if (!$Registry.Configs.ContainsKey($Digest)) {
        $response = Invoke-RegistryRequest $Registry "blobs/$Digest" 'GET' (2 * 1024 * 1024)
        if ($response.Bytes.Length -gt 2 * 1024 * 1024 -or (Get-ByteDigest $response.Bytes) -cne $Digest) {
            throw 'Config blob digest/size verification failed.'
        }
        $Registry.Configs[$Digest] = ConvertFrom-ResponseJson $response
    }
    $Registry.Configs[$Digest]
}

function Test-RegistryBlob {
    param(
        $Registry,
        [string]$Digest
    )

    if (!$Registry.CheckedBlobs.Contains($Digest)) {
        $response = Invoke-RegistryRequest $Registry "blobs/$Digest" 'HEAD'
        if ($response.StatusCode -ne 200) {
            throw 'Referenced blob is unavailable.'
        }
        $null = $Registry.CheckedBlobs.Add($Digest)
    }
}

function Get-RegistryDescription {
    param(
        $Registry,
        [string]$Reference,
        [switch]$CheckBlobs
    )

    $root = (Get-RegistryManifest $Registry $Reference).Digest
    $manifests = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $blobs = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $platforms = @{}
    $attestations = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)


    function Visit-Manifest {
        param(
            [string]$Digest,
            $Descriptor
        )

        $manifest = Get-RegistryManifest $Registry $Digest
        if (!$manifests.Add($manifest.Digest)) {
            return
        }
        $data = $manifest.Data
        if ($data.ContainsKey('manifests')) {
            foreach ($child in $data.manifests) {
                Visit-Manifest $child.digest $child
            }
            return
        }
        $config = $data.config.digest
        $null = $blobs.Add($config)
        foreach ($layer in $data.layers) {
            $null = $blobs.Add($layer.digest)
        }
        if ($Descriptor -and $Descriptor.annotations -and $Descriptor.annotations['vnd.docker.reference.type'] -ceq 'attestation-manifest') {
            $null = $attestations.Add($manifest.Digest)
        }
        else {
            $platform = if ($Descriptor -and $Descriptor.platform) {
                $Descriptor.platform
            } else {
                $configuration = Get-RegistryConfig $Registry $config
                $selected = [ordered]@{}
                foreach ($key in @('architecture', 'os', 'os.features', 'os.version', 'variant')) {
                    if ($configuration.ContainsKey($key)) {
                        $selected[$key] = $configuration[$key]
                    }
                }
                $selected
            }
            $orderedPlatform = [ordered]@{}
            foreach ($key in @($platform.Keys | Sort-Object -CaseSensitive)) {
                $orderedPlatform[$key] = $platform[$key]
            }
            $platforms[($orderedPlatform | ConvertTo-Json -Depth 20 -Compress)] = $platform
        }
    }
    Visit-Manifest $root $null

    if ($CheckBlobs) {
        foreach ($blob in @($blobs | Sort-Object -CaseSensitive)) {
            Test-RegistryBlob $Registry $blob
        }
    }
    @{
        digest = $root
        manifests = @($manifests | Sort-Object -CaseSensitive)
        blobs = @($blobs | Sort-Object -CaseSensitive)
        platforms = @($platforms.Keys | Sort-Object -CaseSensitive | ForEach-Object {
            $platforms[$_]
        })
        attestations = @($attestations | Sort-Object -CaseSensitive)
    }
}

function Get-ExistingDigest {
    param(
        $Registry,
        [string]$Tag
    )

    try {
        Get-RegistryDigest $Registry $Tag
    }
    catch {
        if ($_.Exception.Data['StatusCode'] -eq 404) {
            return $null
        }
        throw
    }
}

function New-PrivateAuthFile {
    param(
        [string]$Directory,
        [string]$User,
        [string]$Secret
    )

    $null = [IO.Directory]::CreateDirectory($Directory)
    $path = Join-Path $Directory 'auth.json'
    # Create exclusively and restrict access before writing credential bytes.
    $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        if (!$IsWindows) {
            [IO.File]::SetUnixFileMode($path, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite)
        }
        $auth = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${User}:$Secret"))
        $bytes = Get-JsonBytes @{
            auths = @{
                'docker.io' = @{
                    auth = $auth
                }
            }
        }
        $stream.Write($bytes, 0, $bytes.Length)
    } finally {
        $stream.Dispose()
    }
    $path
}
