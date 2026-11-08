# Shared loopback HTTPS transport for the disposable REST and preindexed sources.
# Dot-sourcing defines helpers without binding a port or changing certificate trust.
$ErrorActionPreference = 'Stop'

function Read-SourceCatalog {
    param(
        [string]$Path,
        [string]$SourceIdentifier
    )

    $catalog = [IO.File]::ReadAllText($Path) | ConvertFrom-Json -AsHashtable
    if ($catalog.SourceIdentifier -isnot [string] -or !$catalog.SourceIdentifier) {
        throw 'Catalog requires a nonempty SourceIdentifier.'
    }
    if ($catalog.Packages -isnot [array]) {
        throw 'Catalog requires a Packages array of native REST manifests.'
    }
    if ($SourceIdentifier -and $catalog.SourceIdentifier -cne $SourceIdentifier) {
        throw 'SourceIdentifier must remain unchanged during a lifecycle test.'
    }
    $identifiers = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    foreach ($package in $catalog.Packages) {
        if (!$package.PackageIdentifier) {
            throw 'Missing PackageIdentifier.'
        }
        if (!$identifiers.Add($package.PackageIdentifier)) {
            throw "Duplicate package identifier: $($package.PackageIdentifier)"
        }
        if (!$package.Versions.Count) {
            throw "No versions for $($package.PackageIdentifier)"
        }
        $versions = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)

        foreach ($version in $package.Versions) {
            $versionKey = @($version.PackageVersion, [string]$version.Channel) | ConvertTo-Json -Compress
            if (!$versions.Add($versionKey)) {
                throw "Duplicate version for $($package.PackageIdentifier): $versionKey"
            }

            foreach ($field in @('PackageLocale', 'Publisher', 'PackageName', 'License', 'ShortDescription')) {
                if (!$version.DefaultLocale[$field]) {
                    throw "Missing $field in $($package.PackageIdentifier) $versionKey"
                }
            }
            if (!$version.Installers.Count) {
                throw "No installers for $($package.PackageIdentifier) $versionKey"
            }
        }
    }
    return $catalog
}

function Get-InstallerValues {
    param(
        $Version,
        [string]$Field
    )

    $values = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)

    foreach ($installer in $Version.Installers) {
        if ($installer.Contains($Field) -and $values.Add($installer[$Field])) {
            $installer[$Field]
        }

        foreach ($entry in $installer.AppsAndFeaturesEntries) {
            if ($entry.Contains($Field) -and $values.Add($entry[$Field])) {
                $entry[$Field]
            }
        }
    }
}

function ConvertTo-SourceSearchResult {
    param(
        $Package
    )

    $locale = $Package.Versions[-1].DefaultLocale
    $fieldMappings = @(
        @('ProductCode', 'ProductCodes'),
        @('UpgradeCode', 'UpgradeCodes'),
        @('PackageFamilyName', 'PackageFamilyNames'),
        @('DisplayVersion', 'AppsAndFeaturesEntryVersions')
    )
    $versions = @(foreach ($version in $Package.Versions) {
        $result = @{
            PackageVersion = $version.PackageVersion
            Channel = $(if ($version.Channel) {
                $version.Channel
            } else {
                ''
            })
        }

        foreach ($mapping in $fieldMappings) {
            $values = @(Get-InstallerValues $version $mapping[0])
            if ($values.Count) {
                if ($mapping[0] -ne 'DisplayVersion') {
                    $values = @($values | ForEach-Object {
                        $_.ToLowerInvariant()
                    } | Select-Object -Unique)
                }
                $result[$mapping[1]] = $values
            }
        }
        $result
    })

    return @{
        PackageIdentifier = $Package.PackageIdentifier
        PackageName = $locale.PackageName
        Publisher = $locale.Publisher
        Versions = $versions
    }
}

function ConvertTo-SourceWildcardRegex {
    param(
        [string]$Pattern
    )

    # WinGet's fixture contract uses shell-style fnmatch: ! negates a bracket
    # class and an unmatched [ is literal. PowerShell wildcard classes differ.
    $regex = [Text.StringBuilder]::new('\A')

    for ($index = 0; $index -lt $Pattern.Length; $index++) {
        $character = $Pattern[$index]

        switch ($character) {
            '*' {
                [void]$regex.Append('.*')
            }
            '?' {
                [void]$regex.Append('.')
            }
            '[' {
                $end = $index + 1
                if ($end -lt $Pattern.Length -and $Pattern[$end] -eq '!') {
                    $end++
                }
                if ($end -lt $Pattern.Length -and $Pattern[$end] -eq ']') {
                    $end++
                }

                while ($end -lt $Pattern.Length -and $Pattern[$end] -ne ']') {
                    $end++
                }
                if ($end -eq $Pattern.Length) {
                    [void]$regex.Append('\[')
                }
                else {
                    $class = $Pattern.Substring($index + 1, $end - $index - 1)
                    $negated = $class.StartsWith('!')
                    if ($negated) {
                        $class = $class.Substring(1)
                    }
                    $members = [Text.StringBuilder]::new()

                    for ($position = 0; $position -lt $class.Length; $position++) {
                        $first = [int]$class[$position]
                        if ($position + 2 -lt $class.Length -and $class[$position + 1] -eq '-') {
                            $last = [int]$class[$position + 2]
                            # Shell matching discards reversed ranges instead of
                            # treating them as a malformed regular expression.
                            if ($first -le $last) {
                                [void]$members.Append(('\u{0:x4}-\u{1:x4}' -f $first, $last))
                            }
                            $position += 2
                        } else {
                            [void]$members.Append(('\u{0:x4}' -f $first))
                        }
                    }
                    if (!$members.Length) {
                        [void]$regex.Append($(if ($negated) {
                            '.'
                        } else {
                            '(?!)'
                        }))
                    }
                    else {
                        [void]$regex.Append('['+$(if ($negated) {
                            '^'
                        })+$members.ToString()+']')
                    }
                    $index = $end
                }
            }
            default {
                [void]$regex.Append([regex]::Escape([string]$character))
            }
        }
    }
    [void]$regex.Append('\z')
    return $regex.ToString()
}

function Test-SourceValue {
    param(
        [string]$Value,
        $Request
    )

    $keyword = [string]$Request.KeyWord
    $kind = if ($Request.MatchType) {
        $Request.MatchType
    } else {
        'Exact'
    }

    switch -CaseSensitive ($kind) {
        'Exact' {
            return $Value -ceq $keyword
        }
        'CaseInsensitive' {
            return $Value.Equals($keyword, [StringComparison]::OrdinalIgnoreCase)
        }
        'StartsWith' {
            return $Value.StartsWith($keyword, [StringComparison]::OrdinalIgnoreCase)
        }
        'Substring' {
            return $Value.Contains($keyword, [StringComparison]::OrdinalIgnoreCase)
        }
        'Wildcard' {
            $options = [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
                [Text.RegularExpressions.RegexOptions]::CultureInvariant -bor
                [Text.RegularExpressions.RegexOptions]::Singleline
            return [regex]::IsMatch($Value, (ConvertTo-SourceWildcardRegex $keyword), $options)
        }
        default {
            throw "Unsupported match type: $kind"
        }
    }
}

function Test-SourceField {
    param(
        $Package,
        $Item
    )

    $field = $Item.PackageMatchField
    $request = $Item.RequestMatch
    if ($field -cin @('ProductCode', 'UpgradeCode', 'PackageFamilyName') -and (!$request.MatchType -or $request.MatchType -ceq 'Exact')) {
        $request = $request.Clone()
        $request.MatchType = 'CaseInsensitive'
    }
    if ($field -ceq 'Market') {
        return $true
    }
    if ($field -ceq 'PackageIdentifier') {
        return Test-SourceValue $Package.PackageIdentifier $request
    }
    $values = @(foreach ($version in $Package.Versions) {
        switch -CaseSensitive ($field) {
            {
                $_ -cin @('PackageName', 'Moniker')
            } {
                $version.DefaultLocale[$field]
                break
            }
            'Tag' {
                $version.DefaultLocale.Tags
                break
            }
            'Command' {
                foreach ($installer in $version.Installers) {
                    $installer.Commands
                }
                break
            }
            {
                $_ -cin @('ProductCode', 'UpgradeCode', 'PackageFamilyName')
            } {
                Get-InstallerValues $version $field
                break
            }
            'HasInstallerType' {
                foreach ($installer in $version.Installers) {
                    $installer.InstallerType
                    $installer.NestedInstallerType
                }
                break
            }
            default {
                throw "Unsupported match field: $field"
            }
        }
    })

    foreach ($value in $values) {
        if ($value -and (Test-SourceValue $value $request)) {
            return $true
        }
    }
    return $false
}

function Find-SourcePackages {
    param(
        $Packages,
        $Request
    )

    foreach ($item in @($Request.Inclusions) + @($Request.Filters)) {
        if ($item.PackageMatchField -ceq 'NormalizedPackageNameAndPublisher') {
            throw 'Unsupported match field: NormalizedPackageNameAndPublisher'
        }
    }
    $results = @(foreach ($package in $Packages) {
        $selectors = @(if ($Request.Query) {
            foreach ($field in @('PackageIdentifier', 'PackageName', 'Moniker', 'Command', 'Tag')) {
                Test-SourceField $package @{
                    PackageMatchField = $field
                    RequestMatch = $Request.Query
                }
            }
        }

        foreach ($item in $Request.Inclusions) {
            Test-SourceField $package $item
        })
        if ($selectors.Count -and $true -notin $selectors) {
            continue
        }
        $matches = $true

        foreach ($item in $Request.Filters) {
            if (!(Test-SourceField $package $item)) {
                $matches = $false
                break
            }
        }
        if ($matches) {
            ConvertTo-SourceSearchResult $package
        }
    })
    if ($Request.MaximumResults -and $results.Count -gt $Request.MaximumResults) {
        throw 'MaximumResults would truncate the test catalog.'
    }
    return ,$results
}

function Get-SourceFilePath {
    param(
        [string]$Root,
        [string]$Assets,
        [string]$RequestPath,
        [switch]$Preindexed
    )

    $decoded = [Uri]::UnescapeDataString(($RequestPath -split '\?', 2)[0])
    $parts = @($decoded.TrimStart('/') -split '/' | Where-Object {
        $_ -and $_ -ne '.'
    })
    if ($parts -contains '..' -or $decoded.Contains('\') -or $decoded.Contains(':') -or $decoded.Contains([char]0)) {
        return $null
    }
    if ($parts.Count -and $parts[0] -ceq 'assets') {
        if (!$Assets -or $parts.Count -ne 2) {
            return $null
        }
        $directory = [IO.Path]::GetFullPath($Assets)
        $relative = $parts[1]
    } elseif ($Preindexed) {
        $directory = [IO.Path]::GetFullPath($Root)
        $relative = $parts -join [IO.Path]::DirectorySeparatorChar
    } else {
        return $null
    }
    # Follow links at every component, not only at the final filename. A nested
    # source index path must never escape through a linked parent directory.
    $candidate = $directory

    foreach ($part in ($relative -split '[/\\]')) {
        if (!$part) {
            continue
        }
        $candidate = Join-Path $candidate $part
        $item = Get-Item -LiteralPath $candidate -Force -ErrorAction SilentlyContinue
        if ($item -and $item.LinkTarget) {
            $candidate = $item.ResolveLinkTarget($true).FullName
        }
    }
    $candidate = [IO.Path]::GetFullPath($candidate)
    $comparison = if ($IsWindows) {
        [StringComparison]::OrdinalIgnoreCase
    } else {
        [StringComparison]::Ordinal
    }
    if (!$candidate.StartsWith($directory.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar, $comparison)) {
        return $null
    }
    return $candidate
}

function New-SourceJsonResponse {
    param(
        [int]$Status,
        $Payload
    )

    return @{
        Status = $Status
        ContentType = 'application/json'
        Body = [Text.Encoding]::UTF8.GetBytes(($Payload | ConvertTo-Json -Depth 100 -Compress))
        NoStore = $true
    }
}

function Get-SourceContentType {
    param(
        [string]$Path
    )

    switch ([IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '.zip' {
            return 'application/zip'
        }
        '.json' {
            return 'application/json'
        }
        '.msi' {
            return 'application/x-msdownload'
        }
        '.yaml' {
            return 'application/yaml'
        }
        '.yml' {
            return 'application/yaml'
        }
        '.png' {
            return 'image/png'
        }
        '.txt' {
            return 'text/plain'
        }
        '.xml' {
            return 'text/xml'
        }
        '.html' {
            return 'text/html'
        }
        default {
            return 'application/octet-stream'
        }
    }
}

function Get-SourceResponse {
    param(
        $Settings,
        [string]$Method,
        [string]$Target,
        [byte[]]$Body
    )

    $path, $query = $Target -split '\?', 2
    if ($Settings.Preindexed) {
        if ($Method -notin @('GET', 'HEAD')) {
            return New-SourceJsonResponse 501 @{
                code = 'NotImplemented'
            }
        }
        $file = Get-SourceFilePath $Settings.Root $Settings.Assets $Target -Preindexed
        if ($file -and [IO.File]::Exists($file)) {
            return @{
                Status = 200
                ContentType = (Get-SourceContentType $file)
                File = $file
            }
        }
        return New-SourceJsonResponse 404 @{
            code = 'NotFound'
            message = 'Asset not found.'
        }
    }
    if ($Method -eq 'POST') {
        if ($path -cne '/manifestSearch') {
            return New-SourceJsonResponse 404 @{
                code = 'NotFound'
                message = 'Unknown endpoint.'
            }
        }

        try {
            if ($Body.Length -gt 1MB) {
                throw 'Search body exceeds 1 MiB.'
            }
            $request = [Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            if ($request -isnot [Collections.IDictionary]) {
                throw 'Search request must be a JSON object.'
            }
            $catalog = Read-SourceCatalog $Settings.Catalog $Settings.SourceIdentifier
            return New-SourceJsonResponse 200 @{
                Data = (Find-SourcePackages $catalog.Packages $request)
            }
        } catch {
            $errorKind = 'InvalidRequest'
            $status = 400
            $exception = $_.Exception

            while ($exception) {
                if ($exception -is [IO.IOException] -or $exception -is [UnauthorizedAccessException]) {
                    $errorKind = 'InvalidCatalog'
                    $status = 500
                    break
                }
                $exception = $exception.InnerException
            }
            return New-SourceJsonResponse $status @{
                code = $errorKind
                message = $_.Exception.Message
            }
        }
    }
    if ($Method -notin @('GET', 'HEAD')) {
        return New-SourceJsonResponse 501 @{
            code = 'NotImplemented'
        }
    }

    try {
        if ($path -ceq '/information') {
            return New-SourceJsonResponse 200 @{
                Data = @{
                    SourceIdentifier = $Settings.SourceIdentifier
                    ServerSupportedVersions = @('1.10.0')
                    UnsupportedPackageMatchFields = @('NormalizedPackageNameAndPublisher')
                }
            }
        }
        if ($path.StartsWith('/assets/', [StringComparison]::Ordinal) -and $Settings.Assets) {
            $file = Get-SourceFilePath '' $Settings.Assets $Target
            if ($file -and [IO.File]::Exists($file)) {
                return @{
                    Status = 200
                    ContentType = (Get-SourceContentType $file)
                    File = $file
                }
            }
            return New-SourceJsonResponse 404 @{
                code = 'NotFound'
                message = 'Asset not found.'
            }
        }
        if ($path.StartsWith('/packageManifests/', [StringComparison]::Ordinal)) {
            $identifier = [Uri]::UnescapeDataString($path.Substring('/packageManifests/'.Length))
            $filters = @{}

            foreach ($pair in ($query -split '&')) {
                if (!$pair) {
                    continue
                }
                $key, $value = $pair -split '=', 2
                $key = [Uri]::UnescapeDataString($key).ToLowerInvariant()
                if (!$filters.ContainsKey($key)) {
                    $filters[$key] = [Uri]::UnescapeDataString(($value -replace '\+', ' '))
                }
            }
            $catalog = Read-SourceCatalog $Settings.Catalog $Settings.SourceIdentifier

            foreach ($package in $catalog.Packages) {
                if ($package.PackageIdentifier -ine $identifier) {
                    continue
                }
                $versions = @($package.Versions | Where-Object {
                    (!$filters.version -or $_.PackageVersion -ceq $filters.version) -and
                        (!$filters.channel -or [string]$_.Channel -ceq $filters.channel)
                })
                if ($versions.Count) {
                    $result = $package.Clone()
                    $result.Versions = $versions
                    return New-SourceJsonResponse 200 @{
                        Data = $result
                    }
                }
            }
            return New-SourceJsonResponse 404 @{
                code = 'NotFound'
                message = 'Package/version not found.'
            }
        }
        return New-SourceJsonResponse 404 @{
            code = 'NotFound'
            message = 'Unknown endpoint.'
        }
    } catch {
        return New-SourceJsonResponse 500 @{
            code = 'InvalidCatalog'
            message = $_.Exception.Message
        }
    }
}

function Invoke-SourceConnection {
    param(
        $Client,
        $Certificate,
        $Settings
    )

    $stream = $null

    try {
        [Console]::Error.WriteLine("TCP accepted $($Client.Client.RemoteEndPoint)")
        $Client.ReceiveTimeout = 30000
        $Client.SendTimeout = 30000

        $stream = [Net.Security.SslStream]::new($Client.GetStream(), $false)
        $options = [Net.Security.SslServerAuthenticationOptions]::new()
        $options.ServerCertificate = $Certificate
        $options.EnabledSslProtocols = [Security.Authentication.SslProtocols]::Tls12 -bor [Security.Authentication.SslProtocols]::Tls13
        $options.ApplicationProtocols = [Collections.Generic.List[Net.Security.SslApplicationProtocol]]::new()
        $options.ApplicationProtocols.Add([Net.Security.SslApplicationProtocol]::Http11)
        $timeout = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(10))

        try {
            $stream.AuthenticateAsServerAsync($options, $timeout.Token).GetAwaiter().GetResult()
        } finally {
            $timeout.Dispose()
        }
        [Console]::Error.WriteLine("TLS ready: $($stream.SslProtocol)")
        $stream.ReadTimeout = 30000
        $stream.WriteTimeout = 30000

        # Read headers as bytes: StreamReader can buffer part of a binary body.
        $header = [Collections.Generic.List[byte]]::new()

        while ($header.Count -lt 64KB) {
            $next = $stream.ReadByte()
            if ($next -lt 0) {
                return
            }
            $header.Add([byte]$next)
            $headerLength = $header.Count
            if ($headerLength -ge 4 -and
                $header[$headerLength - 4] -eq 13 -and $header[$headerLength - 3] -eq 10 -and
                $header[$headerLength - 2] -eq 13 -and $header[$headerLength - 1] -eq 10) {
                break
            }
        }
        if ($header.Count -ge 64KB) {
            return
        }
        $lines = [Text.Encoding]::ASCII.GetString($header.ToArray()) -split "`r`n"
        $method, $target, $protocol = $lines[0] -split ' ', 3
        if (!$target -or $protocol -notmatch '^HTTP/1\.[01]$') {
            return
        }
        $length = 0

        foreach ($line in $lines[1..($lines.Length - 1)]) {
            if ($line -match '^Content-Length:\s*(.+)$') {
                if (![int]::TryParse($Matches[1], [ref]$length) -or $length -lt 0) {
                    return
                }
            }
        }
        if ($length -gt 1MB) {
            $response = New-SourceJsonResponse 400 @{
                code = 'InvalidRequest'
                message = 'Search body exceeds 1 MiB.'
            }
        }
        else {
            $body = [byte[]]::new($length)
            $offset = 0

            while ($offset -lt $length) {
                $read = $stream.Read($body, $offset, $length - $offset)
                if (!$read) {
                    return
                }
                $offset += $read
            }
            $response = Get-SourceResponse $Settings $method $target $body
        }
        [Console]::Error.WriteLine("$method $target -> $($response.Status)")
        $file = $null

        try {
            if ($response.File) {
                $file = [IO.File]::OpenRead($response.File)
                $size = $file.Length
            } else {
                $size = $response.Body.Length
            }
            $reason = switch ($response.Status) {
                200 {
                    'OK'
                }
                400 {
                    'Bad Request'
                }
                404 {
                    'Not Found'
                }
                500 {
                    'Internal Server Error'
                }
                default {
                    'Not Implemented'
                }
            }
            $headers = "HTTP/1.1 $($response.Status) $reason`r`n" +
                "Content-Type: $($response.ContentType)`r`n" +
                "Content-Length: $size`r`n" +
                "Connection: close`r`n"
            if ($response.NoStore) {
                $headers += "Cache-Control: no-store`r`n"
            }
            $bytes = [Text.Encoding]::ASCII.GetBytes($headers + "`r`n")
            $stream.Write($bytes)
            if ($method -ne 'HEAD') {
                if ($file) {
                    $file.CopyTo($stream)
                } else {
                    $stream.Write($response.Body)
                }
            }
            $stream.Flush()
        } finally {
            if ($file) {
                $file.Dispose()
            }
        }
    } catch {
        [Console]::Error.WriteLine("HTTPS request failed: $($_.Exception.Message)")
    }
    finally {
        if ($stream) {
            $stream.Dispose()
        }
        $Client.Dispose()
    }
}

function Start-SourceServer {
    param(
        $Settings,
        [string]$Certificate,
        [string]$PrivateKey,
        [int]$Port = 8765
    )

    $pem = [Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromPemFile($Certificate, $PrivateKey)
    # Importing a PFX gives Schannel a usable private key on Windows as well.
    $cert = [Security.Cryptography.X509Certificates.X509Certificate2]::new($pem.Export([Security.Cryptography.X509Certificates.X509ContentType]::Pkcs12))
    $pem.Dispose()

    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Port)
    $pool = [RunspaceFactory]::CreateRunspacePool(1, 16)
    $pool.Open()
    $workers = [Collections.Generic.List[object]]::new()
    $connectionScript = @'
param(
    $helper,
    $client,
    $certificate,
    $settings
)

. $helper
Invoke-SourceConnection $client $certificate $settings
'@

    try {
        $listener.Start()
        [Console]::WriteLine("Serving source at https://127.0.0.1:$($listener.LocalEndpoint.Port)")

        while ($true) {
            $client = $listener.AcceptTcpClient()

            for ($index = $workers.Count - 1; $index -ge 0; $index--) {
                if ($workers[$index].Result.IsCompleted) {
                    try {
                        $null = $workers[$index].Shell.EndInvoke($workers[$index].Result)
                    } finally {
                        $workers[$index].Shell.Dispose()
                        $workers.RemoveAt($index)
                    }
                }
            }
            $shell = [PowerShell]::Create()
            $shell.RunspacePool = $pool
            $null = $shell.AddScript($connectionScript)
            $null = $shell.AddArgument($PSCommandPath)
            $null = $shell.AddArgument($client)
            $null = $shell.AddArgument($cert)
            $null = $shell.AddArgument($Settings)
            $workers.Add(@{
                Shell = $shell
                Result = $shell.BeginInvoke()
            })
        }
    } finally {
        $listener.Stop()

        foreach ($worker in $workers) {
            $worker.Shell.Stop()
            $worker.Shell.Dispose()
        }
        $pool.Dispose()
        $cert.Dispose()
    }
}
