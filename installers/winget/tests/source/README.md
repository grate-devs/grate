# Disposable WinGet sources

The launchers create private loopback sources for real WinGet lifecycle tests.
They run only on disposable Windows CI runners and clean up their temporary TLS
trust and server processes afterwards.

| File or folder | Purpose |
| --- | --- |
| `Start-TestSource.ps1` / `Stop-TestSource.ps1` | Start and clean up the read-only REST source, including its temporary certificate. |
| `server.ps1` / `test_server.ps1` | REST protocol/asset server and HTTPS protocol checks. |
| `SourceServer.ps1` / `SourceTestHelpers.ps1` | Shared HTTPS transport, catalog/search rules, and isolated test setup. |
| `Start-PreIndexedSource.ps1` / `Stop-PreIndexedSource.ps1` | Build, host and clean up a native SQLite source package. |
| `preindexed/` | Catalog conversion, native index API wrapper, static server and focused tests; see its [file guide](preindexed/README.md). |

## REST source

This read-only source serves the actual WinGet REST protocol to `winget.exe` in
disposable Windows CI. Both package identities can exist in one source throughout
an installation/upgrade test. The server does not simulate installation results or
choose a winner when several packages share MSI identity.

The protocol follows Microsoft's [REST API 1.10.0 specification](https://github.com/microsoft/winget-cli-restsource/blob/main/documentation/WinGet-1.10.0.yaml).
It implements `GET /information`, `POST /manifestSearch`, and
`GET /packageManifests/{identifier}?Version={version}`. The optional `/assets/`
endpoint serves files directly inside an explicit asset directory over the same
HTTPS connection. No package mutation endpoints are provided.

## Catalog contract

The UTF-8 JSON catalog contains a fixed `SourceIdentifier` and a `Packages` array
of native REST manifest objects. Each installer must contain all applicable fields;
there is no YAML installer-root inheritance. For example:

```json
{
  "SourceIdentifier": "GrateMigrationCI",
  "Packages": [
    {
      "PackageIdentifier": "erikbra.grate",
      "Versions": [
        {
          "PackageVersion": "2.0.0",
          "DefaultLocale": {
            "PackageLocale": "en-US",
            "Publisher": "erikbra",
            "PackageName": "grate",
            "License": "MIT",
            "ShortDescription": "SQL migration runner"
          },
          "Installers": [
            {
              "Architecture": "x64",
              "InstallerType": "zip",
              "NestedInstallerType": "portable",
              "NestedInstallerFiles": [{"RelativeFilePath": "grate.exe"}],
              "InstallerUrl": "https://github.com/grate-devs/grate/releases/download/2.0.0/grate-win-x64-self-contained-2.0.0.zip",
              "InstallerSha256": "C1F2D4A3834D5A7CAEA1896FE53C64D8FBEE67B8BCE64FE7FCB037858DA2E93B"
            }
          ]
        }
      ]
    }
  ]
}
```

Add `grate-devs.grate` as another package. MSI installers retain their actual
ProductCode, UpgradeCode, scope, and AppsAndFeaturesEntries. Search responses
include product/upgrade codes from every version and installer, including codes in
AppsAndFeaturesEntries, so duplicate identity is exposed to the client.
Windows reference fields (`ProductCode`, `UpgradeCode`, and `PackageFamilyName`)
match case-insensitively even in an `Exact` correlation request. Search-response
reference arrays use folded case, while downloaded manifest metadata keeps its
authored values. This follows the Windows identity semantics used by the current
[client match resolver](https://github.com/microsoft/winget-cli/blob/master/src/AppInstallerRepositoryCore/MatchCriteriaResolver.cpp)
and the [composite source](https://github.com/microsoft/winget-cli/blob/master/src/AppInstallerRepositoryCore/CompositeSource.cpp),
which folds reference strings before constructing its correlation requests.
Ordinary package-ID and package-name `Exact` searches remain case-sensitive.
This is an explicit fixture policy: the reference REST server's general predicate
implementation applies raw case-sensitive `Exact` matching. A Windows lifecycle
result must therefore retain its client-version and source-type qualifications.

The server rereads the catalog for every request. Write an updated catalog to a
temporary file and atomically replace the original to expose a later release.
Keep `SourceIdentifier` unchanged: changing it is rejected. The client determines
version ordering; the source returns all configured versions and uses the last
version's default locale for package search display metadata.

## Windows CI startup and cleanup

The launcher requires PowerShell 7, an elevated disposable GitHub-hosted
Windows runner, `GITHUB_ACTIONS=true`, and `RUNNER_ENVIRONMENT=github-hosted`. It
creates a one-day certificate covering DNS `localhost` and IP `127.0.0.1`, trusts its public certificate in
`LocalMachine\Root`, exports its key to a unique temporary directory, and launches
a PowerShell child process. The source URL uses `https://127.0.0.1:8765`, matching the listening address
and certificate IP SAN without DNS/IPv6 fallback. Readiness requests bypass proxies
and use ordinary certificate validation with a bounded five-second timeout.

```powershell
$source = $null
try {
    $source = & ./installers/winget/tests/source/Start-TestSource.ps1 `
        -Catalog $catalogPath -Assets $assetDirectory -LogDirectory $logDirectory
    winget source add --name GrateMigrationCI --arg $source.Url --type Microsoft.Rest
    if ($LASTEXITCODE -ne 0) { throw 'Cannot add test source.' }
    # Run real winget search/show/install/upgrade/list against this source.
} finally {
    if ($source) {
        winget source remove --name GrateMigrationCI
        & ./installers/winget/tests/source/Stop-TestSource.ps1 -State $source
    }
}
```

The returned object contains `Pid`, `Url`, `SourceIdentifier`,
`CertificateThumbprint`, `CertificateDirectory`, and `LogDirectory`. Cleanup stops
the server and removes the certificate from both stores and its temporary key
directory. Source removal and installed-package cleanup belong to the lifecycle
test. Upload the server logs with the test evidence; do not upload temporary keys.

For manual protocol inspection on another host, provide a trusted certificate and
key explicitly. The server always binds only to `127.0.0.1`:

```powershell
pwsh -NoProfile -File installers/winget/tests/source/server.ps1 -Catalog /tmp/catalog.json `
  -Certificate /tmp/localhost.pem -PrivateKey /tmp/localhost-key.pem `
  -Assets /tmp/assets -Port 8765
```

## Verification scope

Run protocol checks with PowerShell 7. The tests create an isolated temporary
certificate with .NET and trust it only in their own HTTPS client:

```powershell
pwsh -NoProfile -File installers/winget/tests/source/test_server.ps1
```

These checks make real HTTPS requests and cover both IDs, exact/substring
selection, inclusion/filter semantics, duplicate MSI correlation data, version
filtering, dynamic catalog updates, source identity stability, and asset isolation.
They also verify certificate trust/name rejection and that an incomplete TLS
connection cannot block another request. TLS handshakes run in separate workers
with a ten-second timeout. The servers log TCP acceptance, TLS success/failure and
HTTP responses to their error logs. Public certificate metadata and startup errors are
recorded alongside those logs.
They do not establish successful WinGet client negotiation, installation, or
upgrade. Those require the Windows lifecycle workflow.

This fixture is intentionally small: all test installers are available in every
market; fuzzy matching and paginated results are rejected. The REST pair-search
request carries a normalized name without a separate publisher value. The source
therefore advertises this unsupported capability in its information response:

```json
{"Data":{"SourceIdentifier":"GrateMigrationCI","ServerSupportedVersions":["1.10.0"],"UnsupportedPackageMatchFields":["NormalizedPackageNameAndPublisher"]}}
```

The [pinned client's REST implementation](https://github.com/microsoft/winget-cli/blob/v1.29.380/src/AppInstallerRepositoryCore/Rest/Schema/1_1/RestInterface_1_1.cpp)
removes unsupported inclusions before submitting a search and rejects unsupported
filters. If a caller nevertheless sends this field, the fixture returns HTTP 400
rather than pretending a name-only comparison also matched the publisher. Searches
for supported product/upgrade codes still return every matching package, including
real strong-identity collisions.

This is an explicit capability limitation, not a claim of identical configuration
with Microsoft's reference server. Its
[API constants](https://github.com/microsoft/winget-cli-restsource/blob/main/src/WinGet.RestSource.Utils/Constants/ApiConstants.cs)
currently omit the unsupported-field announcement as a historical client
compatibility workaround tracked in
[reference-source issue #59](https://github.com/microsoft/winget-cli-restsource/issues/59).
A private REST-source result is useful compatibility
evidence, but does not establish identical correlation with the community source's
pre-indexed catalog or upstream acceptance.
