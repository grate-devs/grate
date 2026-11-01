# Disposable WinGet REST source

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

The launcher requires PowerShell 7, Python 3.9+, an elevated disposable GitHub-hosted
Windows runner, `GITHUB_ACTIONS=true`, and `RUNNER_ENVIRONMENT=github-hosted`. It
creates a one-day certificate covering DNS `localhost` and IP `127.0.0.1`, trusts its public certificate in
`LocalMachine\Root`, exports its key to a unique temporary directory, and launches
Python. The source URL uses `https://127.0.0.1:8765`, matching the listening address
and certificate IP SAN without DNS/IPv6 fallback. Readiness requests bypass proxies
and use ordinary certificate validation with a bounded five-second timeout.

```powershell
$source = $null
try {
    $source = & ./installers/winget/test-source/Start-TestSource.ps1 `
        -Catalog $catalogPath -Assets $assetDirectory -LogDirectory $logDirectory
    winget source add --name GrateMigrationCI --arg $source.Url --type Microsoft.Rest
    if ($LASTEXITCODE -ne 0) { throw 'Cannot add test source.' }
    # Run real winget search/show/install/upgrade/list against this source.
} finally {
    if ($source) {
        winget source remove --name GrateMigrationCI
        & ./installers/winget/test-source/Stop-TestSource.ps1 -State $source
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

```sh
python3 installers/winget/test-source/server.py --catalog /tmp/catalog.json \
  --certificate /tmp/localhost.pem --private-key /tmp/localhost-key.pem \
  --assets /tmp/assets --port 8765
```

## Verification scope

Run protocol checks with Python and OpenSSL (used only to generate a temporary
certificate for the tests):

```sh
python3 -m unittest discover -s installers/winget/test-source -p 'test_*.py' -v
```

These checks make real HTTPS requests and cover both IDs, exact/substring
selection, inclusion/filter semantics, duplicate MSI correlation data, version
filtering, dynamic catalog updates, source identity stability, and asset isolation.
They also verify certificate trust/name rejection and that an incomplete TLS
connection cannot block another request. TLS handshakes run in separate workers
with a ten-second timeout; server logs distinguish TCP acceptance, TLS success or
failure, and HTTP requests. Public certificate metadata and startup errors are
recorded alongside those logs.
They do not establish successful WinGet client negotiation, installation, or
upgrade. Those require the Windows lifecycle workflow.

This fixture is intentionally small: all test installers are available in every
market; fuzzy matching and paginated results are rejected. Normalized name search
only handles grate's simple name and returns all name candidates. The REST request
schema carries the normalized name without a separate publisher value; the
[client serializer](https://github.com/microsoft/winget-cli/blob/master/src/AppInstallerRepositoryCore/Rest/Schema/1_0/Json/SearchRequestSerializer_1_0.cpp)
shows that restriction. A private REST-source result is useful compatibility
evidence, but does not establish identical correlation with the community source's
pre-indexed catalog or upstream acceptance.
