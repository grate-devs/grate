# Shared fake registry and Skopeo boundary. No Docker/network is used.

function Reset-PublicationFixture {
    param(
        [string]$PublicationMode = 'canonical'
    )

    $script:Mode = $PublicationMode
    $script:Raw = [Text.Encoding]::UTF8.GetBytes('{"schemaVersion":2,"manifests":[]}')
    $script:Digest = Get-ByteDigest $script:Raw
    $script:OtherDigest = 'sha256:' + ('b' * 64)
    $script:TagsValue = "gratedevs/grate:latest`nerikbra/grate:latest`ngratedevs/grate:2.3.4`nerikbra/grate:2.3.4"

    $script:Directory = New-TestDirectory
    $script:ArchivePath = Join-Path $script:Directory 'archive with spaces.tar'
    $script:AuthPath = Join-Path $script:Directory 'canonical auth.json'
    $script:ReportPath = Join-Path $script:Directory 'report.json'
    Set-Content -LiteralPath $script:ArchivePath -Value 'fixture' -NoNewline -Encoding utf8NoBOM
    Set-Content -LiteralPath $script:AuthPath -Value '{"auths":{"docker.io":{"auth":"OIDC_AUTH"}}}' -NoNewline -Encoding utf8NoBOM

    $script:Destination = @{
        Tags = @{
            latest = $script:OtherDigest
        }
        Checked = [Collections.Generic.List[string]]::new()
    }

    $script:Commands = [Collections.Generic.List[object]]::new()
    $script:Authfiles = [Collections.Generic.List[string]]::new()
    $script:RegistryCalls = [Collections.Generic.List[string]]::new()
    $script:ArchiveRaw = $script:Raw
    $script:ReferenceRaw = @{}

    $script:FailCopy = ''
    $script:FailTool = $false
    $script:FailGraph = $false
    $script:RegistryError = 0
    $script:AfterCopy = $null
    $script:GraphOverrideDigest = $null
}

function New-Registry {
    param(
        [string]$Repository
    )

    $script:RegistryCalls.Add($Repository)
    $script:Destination
}

function Get-RegistryDigest {
    param(
        $Registry,
        [string]$Tag
    )

    $Registry.Checked.Add($Tag)
    if ($script:RegistryError -or !$Registry.Tags.ContainsKey($Tag)) {
        $exception = [InvalidOperationException]::new('OIDC_AUTH')
        $exception.Data['StatusCode'] = if ($script:RegistryError) {
            $script:RegistryError
        } else {
            404
        }
        throw $exception
    }
    $Registry.Tags[$Tag]
}

function Get-RegistryDescription {
    param(
        $Registry,
        [string]$Reference,
        [switch]$CheckBlobs
    )

    if ($script:FailGraph) {
        throw 'SECRET_RESPONSE'
    }
    Assert-True $CheckBlobs.IsPresent 'destination graph must check blobs'

    @{
        digest = $(if ($script:GraphOverrideDigest) {
            $script:GraphOverrideDigest
        } else {
            $Registry.Tags[$Reference]
        })
        manifests = @($script:Digest, 'sha256:attestation')
        blobs = @('sha256:layer')
        platforms = @(
            @{
                os = 'linux'
                architecture = 'amd64'
            }
            @{
                os = 'linux'
                architecture = 'arm64'
            }
        )
        attestations = @('sha256:attestation')
    }
}

function Invoke-ReleaseProcess {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [int]$TimeoutSeconds = 1200
    )

    Assert-Equal 'skopeo' $FilePath
    Assert-True ($TimeoutSeconds -gt 0)
    Assert-True (!(($Arguments -join ' ').Contains('LEGACY_SECRET'))) 'secret must not be on command line'
    $script:Commands.Add(@($Arguments))

    if ($script:FailTool) {
        throw 'OIDC_AUTH'
    }

    if ($Arguments[0] -ceq 'inspect') {
        Assert-True ($Arguments -contains '--raw')
        if ($Arguments[-1].StartsWith('oci-archive:')) {
            return @{
                ExitCode = 0
                Bytes = $script:ArchiveRaw
            }
        }
        Assert-Equal $script:AuthPath $Arguments[[Array]::IndexOf($Arguments, '--authfile') + 1]

        $reference = $Arguments[-1]
        if ($script:ReferenceRaw.ContainsKey($reference)) {
            $bytes = $script:ReferenceRaw[$reference]
        } elseif ($script:Mode -ceq 'canonical') {
            $tag = $reference.Substring($reference.LastIndexOf(':') + 1)
            $bytes = if ($script:Destination.Tags[$tag] -ceq $script:Digest) {
                $script:Raw
            } else {
                [Text.Encoding]::UTF8.GetBytes('moved')
            }
        } else {
            $bytes = $script:Raw
        }

        return @{
            ExitCode = 0
            Bytes = $bytes
        }
    }

    Assert-Equal 'copy' $Arguments[0]
    Assert-True ($Arguments -contains '--all')
    Assert-True ($Arguments -contains '--preserve-digests')

    $tag = $Arguments[-1].Substring($Arguments[-1].LastIndexOf(':') + 1)
    $journal = Get-PublicationReport
    Assert-Equal 'copy_started' $journal.tags[$tag].status
    if ($tag -ceq 'latest') {
        Assert-Equal 'verified' $journal.tags['2.3.4'].status
    }

    $destAuth = $Arguments[[Array]::IndexOf($Arguments, '--dest-authfile') + 1]
    if ($script:Mode -ceq 'canonical') {
        Assert-Equal $script:AuthPath $destAuth
        Assert-Equal "oci-archive:$script:ArchivePath" $Arguments[-2]
        Assert-Equal "docker://docker.io/gratedevs/grate:$tag" $Arguments[-1]
        Assert-True (!($Arguments -contains '--src-authfile'))
    } else {
        Assert-Equal $script:AuthPath $Arguments[[Array]::IndexOf($Arguments, '--src-authfile') + 1]
        Assert-True ($destAuth -cne $script:AuthPath)
        $script:Authfiles.Add($destAuth)
        if (!$IsWindows) {
            Assert-Equal ([IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite) ([IO.File]::GetUnixFileMode($destAuth))
        }

        $auth = (Get-Content -LiteralPath $destAuth -Raw | ConvertFrom-Json -AsHashtable).auths['docker.io'].auth
        Assert-Equal 'legacy-user:LEGACY_SECRET' ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($auth)))
        Assert-Equal "docker://docker.io/gratedevs/grate@$script:Digest" $Arguments[-2]
        Assert-Equal "docker://docker.io/erikbra/grate:$tag" $Arguments[-1]
    }

    if ($script:FailCopy -ceq $tag) {
        return @{
            ExitCode = 1
            Bytes = [Text.Encoding]::UTF8.GetBytes('LEGACY_SECRET OIDC_AUTH')
        }
    }
    $script:Destination.Tags[$tag] = $script:Digest
    if ($script:AfterCopy) {
        & $script:AfterCopy $tag
    }

    @{
        ExitCode = 0
        Bytes = [byte[]]@()
    }
}

function Get-PublicationCopies {
    $script:Commands | Where-Object { $_[0] -ceq 'copy' } | ForEach-Object { ,$_ }
}

function Get-PublicationReport {
    $text = Get-Content -LiteralPath $script:ReportPath -Raw
    Assert-True ($text -notmatch 'LEGACY_SECRET|OIDC_AUTH|SECRET_RESPONSE') 'journal must redact secrets'
    $text | ConvertFrom-Json -AsHashtable
}

function Invoke-Publication {
    param(
        [string]$Value = $script:TagsValue,
        [string]$BuildDigest = $script:Digest,
        [string]$User = 'legacy-user',
        [string]$Secret = 'LEGACY_SECRET'
    )

    if ($script:Mode -ceq 'canonical') {
        Publish-DockerArchive $Value $BuildDigest $script:ArchivePath $script:AuthPath $script:ReportPath
    }
    else {
        Copy-DockerRelease $Value $BuildDigest $script:AuthPath $script:ReportPath $User $Secret
    }
}

function Invoke-PublicationCase {
    param(
        [string]$Name,
        [string]$PublicationMode,
        [scriptblock]$Action
    )

    Invoke-Test $Name {
        Reset-PublicationFixture $PublicationMode
        try {
            & $Action
        } finally {
            [IO.Directory]::Delete($script:Directory, $true)
        }
    }
}
