#!/usr/bin/env python3
"""Disposable, read-only WinGet REST source for installation/upgrade CI.

Protocol: microsoft/winget-cli-restsource/documentation/WinGet-1.10.0.yaml.
This fixture deliberately serves actual REST manifests, not WinGet command results.
"""

import argparse
import fnmatch
import json
import mimetypes
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import re
import ssl
import sys
from urllib.parse import parse_qs, unquote, urlsplit


def load_catalog(path):
    catalog = json.loads(Path(path).read_text(encoding="utf-8-sig"))
    if not isinstance(catalog.get("SourceIdentifier"), str) or not catalog["SourceIdentifier"]:
        raise ValueError("Catalog requires a nonempty SourceIdentifier.")
    packages = catalog.get("Packages")
    if not isinstance(packages, list):
        raise ValueError("Catalog requires a Packages array of native REST manifests.")
    identifiers = set()
    for package in packages:
        identifier = package["PackageIdentifier"]
        if identifier.casefold() in identifiers:
            raise ValueError(f"Duplicate package identifier: {identifier}")
        identifiers.add(identifier.casefold())
        versions = package["Versions"]
        if not versions:
            raise ValueError(f"No versions for {identifier}")
        keys = set()
        for version in versions:
            key = (version["PackageVersion"], version.get("Channel", ""))
            if key in keys:
                raise ValueError(f"Duplicate version for {identifier}: {key}")
            keys.add(key)
            for field in ("PackageLocale", "Publisher", "PackageName", "License", "ShortDescription"):
                if not version["DefaultLocale"].get(field):
                    raise ValueError(f"Missing {field} in {identifier} {key}")
            if not version.get("Installers"):
                raise ValueError(f"No installers for {identifier} {key}")
    return catalog


def installer_values(version, field):
    values = []
    for installer in version["Installers"]:
        if field in installer:
            values.append(installer[field])
        for entry in installer.get("AppsAndFeaturesEntries", []):
            if field in entry:
                values.append(entry[field])
    return list(dict.fromkeys(values))


def search_result(package):
    locale = package["Versions"][-1]["DefaultLocale"]
    versions = []
    for version in package["Versions"]:
        result = {"PackageVersion": version["PackageVersion"], "Channel": version.get("Channel", "")}
        for field, output in (("ProductCode", "ProductCodes"), ("UpgradeCode", "UpgradeCodes"),
                              ("PackageFamilyName", "PackageFamilyNames"),
                              ("DisplayVersion", "AppsAndFeaturesEntryVersions")):
            values = installer_values(version, field)
            if values:
                result[output] = values
        versions.append(result)
    return {"PackageIdentifier": package["PackageIdentifier"], "PackageName": locale["PackageName"],
            "Publisher": locale["Publisher"], "Versions": versions}


def normalize_name(value):
    # The CI catalog only contains grate. General Windows name normalization is
    # intentionally outside this fixture's scope; do not claim general parity.
    return re.sub(r"[^a-z0-9]", "", value.casefold())


def matches_value(value, request):
    keyword = request.get("KeyWord", "")
    kind = request.get("MatchType", "Exact")
    if kind == "Exact":
        return value == keyword
    value, keyword = value.casefold(), keyword.casefold()
    if kind == "CaseInsensitive":
        return value == keyword
    if kind == "StartsWith":
        return value.startswith(keyword)
    if kind == "Substring":
        return keyword in value
    if kind == "Wildcard":
        return fnmatch.fnmatchcase(value, keyword)
    raise ValueError(f"Unsupported match type: {kind}")


def field_matches(package, item):
    field, request = item["PackageMatchField"], item["RequestMatch"]
    if field == "Market":
        # Test installers have no market restrictions.
        return True
    if field == "PackageIdentifier":
        return matches_value(package["PackageIdentifier"], request)
    values = []
    for version in package["Versions"]:
        locale = version["DefaultLocale"]
        if field in ("PackageName", "Moniker"):
            values.append(locale.get(field, ""))
        elif field == "Tag":
            values.extend(locale.get("Tags", []))
        elif field == "Command":
            for installer in version["Installers"]:
                values.extend(installer.get("Commands", []))
        elif field in ("ProductCode", "UpgradeCode", "PackageFamilyName"):
            values.extend(installer_values(version, field))
        elif field == "HasInstallerType":
            for installer in version["Installers"]:
                values.extend([installer.get("InstallerType", ""), installer.get("NestedInstallerType", "")])
        elif field == "NormalizedPackageNameAndPublisher":
            # The REST request schema carries only KeyWord (the normalized name),
            # not the publisher's additional value. Return name candidates; let
            # the real client decide correlation. Never invent a unique match.
            values.append(normalize_name(locale["PackageName"]))
            for installer in version["Installers"]:
                for entry in installer.get("AppsAndFeaturesEntries", []):
                    values.append(normalize_name(entry.get("DisplayName", locale["PackageName"])))
            request = dict(request, KeyWord=normalize_name(request["KeyWord"]))
        else:
            raise ValueError(f"Unsupported match field: {field}")
    return any(matches_value(value, request) for value in values if value)


def search(packages, request):
    results = []
    for package in packages:
        selectors = []
        if request.get("Query"):
            query = request["Query"]
            selectors.extend(field_matches(package, {"PackageMatchField": field, "RequestMatch": query})
                             for field in ("PackageIdentifier", "PackageName", "Moniker", "Command", "Tag"))
        selectors.extend(field_matches(package, item) for item in request.get("Inclusions", []))
        if selectors and not any(selectors):
            continue
        if all(field_matches(package, item) for item in request.get("Filters", [])):
            results.append(search_result(package))
    maximum = request.get("MaximumResults", 0)
    if maximum and len(results) > maximum:
        # No pagination is needed for two packages, but silently truncating would
        # hide a collision from the client and make the migration test misleading.
        raise ValueError("MaximumResults would truncate the test catalog.")
    return results


class TestSource(ThreadingHTTPServer):
    def __init__(self, address, catalog_path, assets_path=None):
        self.catalog_path = Path(catalog_path)
        self.source_identifier = load_catalog(self.catalog_path)["SourceIdentifier"]
        self.assets_path = Path(assets_path).resolve() if assets_path else None
        self.ssl_context = None
        super().__init__(address, Handler)

    def enable_https(self, certificate, private_key):
        self.ssl_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.ssl_context.minimum_version = ssl.TLSVersion.TLSv1_2
        self.ssl_context.set_alpn_protocols(["http/1.1"])
        self.ssl_context.load_cert_chain(certificate, private_key)

    def process_request_thread(self, request, client_address):
        # Handshake after thread dispatch, never in the single accept loop. A
        # connection probe or canceled TLS negotiation must not stall all future
        # requests, even though this fixture only listens on loopback.
        if self.ssl_context:
            print(f"TCP accepted {client_address}", file=sys.stderr, flush=True)
            try:
                request.settimeout(10)
                request = self.ssl_context.wrap_socket(request, server_side=True)
                print(f"TLS ready {client_address}: {request.version()}", file=sys.stderr, flush=True)
                request.settimeout(30)
            except (OSError, ssl.SSLError) as error:
                print(f"TLS failed {client_address}: {error}", file=sys.stderr, flush=True)
                self.shutdown_request(request)
                return
        super().process_request_thread(request, client_address)

    def catalog(self):
        catalog = load_catalog(self.catalog_path)
        if catalog["SourceIdentifier"] != self.source_identifier:
            raise ValueError("SourceIdentifier must remain unchanged during a lifecycle test.")
        return catalog


class Handler(BaseHTTPRequestHandler):
    def respond(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        parsed = urlsplit(self.path)
        try:
            if parsed.path == "/information":
                return self.respond(200, {"Data": {"SourceIdentifier": self.server.source_identifier,
                                                   "ServerSupportedVersions": ["1.10.0"]}})
            if parsed.path.startswith("/assets/") and self.server.assets_path:
                return self.serve_asset(unquote(parsed.path[len("/assets/"):]))
            if parsed.path.startswith("/packageManifests/"):
                identifier = unquote(parsed.path[len("/packageManifests/"):])
                query = {key.casefold(): value[0] for key, value in parse_qs(parsed.query).items()}
                for package in self.server.catalog()["Packages"]:
                    if package["PackageIdentifier"].casefold() != identifier.casefold():
                        continue
                    versions = [version for version in package["Versions"]
                                if (not query.get("version") or version["PackageVersion"] == query["version"])
                                and (not query.get("channel") or version.get("Channel", "") == query["channel"])]
                    if versions:
                        return self.respond(200, {"Data": dict(package, Versions=versions)})
                return self.respond(404, {"code": "NotFound", "message": "Package/version not found."})
            self.respond(404, {"code": "NotFound", "message": "Unknown endpoint."})
        except (ValueError, KeyError, TypeError, OSError) as error:
            self.respond(500, {"code": "InvalidCatalog", "message": str(error)})

    def serve_asset(self, name):
        path = (self.server.assets_path / name).resolve()
        if path.parent != self.server.assets_path or not path.is_file():
            return self.respond(404, {"code": "NotFound", "message": "Asset not found."})
        self.send_response(200)
        self.send_header("Content-Type", mimetypes.guess_type(path.name)[0] or "application/octet-stream")
        self.send_header("Content-Length", str(path.stat().st_size))
        self.end_headers()
        if self.command == "HEAD":
            return
        with path.open("rb") as asset:
            while block := asset.read(1024 * 1024):
                self.wfile.write(block)

    def do_POST(self):
        if urlsplit(self.path).path != "/manifestSearch":
            return self.respond(404, {"code": "NotFound", "message": "Unknown endpoint."})
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length > 1024 * 1024:
                raise ValueError("Search body exceeds 1 MiB.")
            request = json.loads(self.rfile.read(length))
            self.log_message("search %s", json.dumps(request))
            self.respond(200, {"Data": search(self.server.catalog()["Packages"], request)})
        except (ValueError, KeyError, TypeError) as error:
            self.respond(400, {"code": "InvalidRequest", "message": str(error)})
        except OSError as error:
            self.respond(500, {"code": "InvalidCatalog", "message": str(error)})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=Path, required=True)
    parser.add_argument("--certificate", type=Path, required=True)
    parser.add_argument("--private-key", type=Path, required=True)
    parser.add_argument("--assets", type=Path)
    parser.add_argument("--port", type=int, default=8765)
    args = parser.parse_args()
    with TestSource(("127.0.0.1", args.port), args.catalog, args.assets) as server:
        server.enable_https(args.certificate, args.private_key)
        print(f"Serving {server.source_identifier} at https://127.0.0.1:{server.server_port}", flush=True)
        server.serve_forever()


if __name__ == "__main__":
    main()
