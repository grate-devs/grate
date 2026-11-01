"""Protocol fixture checks; Windows CI separately exercises the actual WinGet client."""

import copy
import json
from pathlib import Path
import shutil
import socket
import ssl
import subprocess
import tempfile
import threading
import unittest
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from server import TestSource, load_catalog


PRODUCT_CODE = "{E281998A-D8A2-4926-AAA3-066EFA4B2E74}"
UPGRADE_CODE = "{98CF60F4-3F43-4ACE-B364-ADBCD893A144}"


def version(number):
    return {
        "PackageVersion": number,
        "DefaultLocale": {"PackageLocale": "en-US", "Publisher": "erikbra", "PackageName": "grate",
                          "License": "MIT", "ShortDescription": "SQL migration runner"},
        "Installers": [{"Architecture": "x64", "InstallerType": "wix", "Scope": "user",
                        "InstallerUrl": "https://example.invalid/grate.msi", "InstallerSha256": "A" * 64,
                        "ProductCode": PRODUCT_CODE,
                        "AppsAndFeaturesEntries": [{"DisplayName": "grate", "Publisher": "erikbra",
                                                   "ProductCode": PRODUCT_CODE, "UpgradeCode": UPGRADE_CODE}]}]
    }


def catalog():
    return {"SourceIdentifier": "GrateMigrationCI", "Packages": [
        {"PackageIdentifier": "erikbra.grate", "Versions": [version("2.0.0"), version("2.1.6")]},
        {"PackageIdentifier": "grate-devs.grate", "Versions": [version("2.1.6")]}
    ]}


def selector(field, keyword, kind="Exact"):
    return {"PackageMatchField": field, "RequestMatch": {"KeyWord": keyword, "MatchType": kind}}


class SourceProtocolTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not shutil.which("openssl"):
            raise RuntimeError("The HTTPS protocol tests require openssl to generate a temporary localhost certificate.")
        cls.temporary = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temporary.name)
        certificate, key = cls.root / "cert.pem", cls.root / "key.pem"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                        "-keyout", str(key), "-out", str(certificate), "-subj", "/CN=localhost",
                        "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1"], check=True, capture_output=True)
        cls.context = ssl.create_default_context(cafile=str(certificate))
        cls.certificate, cls.key = certificate, key

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()

    def setUp(self):
        self.test_directory = tempfile.TemporaryDirectory(dir=self.root)
        self.directory = Path(self.test_directory.name)
        self.path = self.directory / "catalog.json"
        self.write_catalog(catalog())
        self.assets = self.directory / "assets"
        self.assets.mkdir()
        (self.assets / "candidate.zip").write_bytes(b"test candidate asset")
        self.server = TestSource(("127.0.0.1", 0), self.path, self.assets)
        self.server.enable_https(self.certificate, self.key)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f"https://127.0.0.1:{self.server.server_port}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.test_directory.cleanup()

    def write_catalog(self, value):
        replacement = self.path.with_suffix(".new")
        replacement.write_text(json.dumps(value), encoding="utf-8")
        replacement.replace(self.path)

    def request(self, path, payload=None, method=None):
        body = json.dumps(payload).encode() if payload is not None else None
        request = Request(self.url + path, data=body, method=method,
                          headers={"Content-Type": "application/json", "Version": "1.10.0"})
        return urlopen(request, context=self.context, timeout=3)

    def search(self, payload):
        with self.request("/manifestSearch", payload) as response:
            return json.load(response)["Data"]

    def test_both_identities_remain_distinct_in_the_same_source(self):
        with self.request("/information") as response:
            information = json.load(response)["Data"]
        self.assertEqual("GrateMigrationCI", information["SourceIdentifier"])
        self.assertEqual(["1.10.0"], information["ServerSupportedVersions"])
        packages = self.search({"Query": {"KeyWord": "grate", "MatchType": "Substring"}})
        self.assertEqual(["erikbra.grate", "grate-devs.grate"], [p["PackageIdentifier"] for p in packages])
        self.assertEqual(["2.0.0", "2.1.6"], [v["PackageVersion"] for v in packages[0]["Versions"]])

    def test_incomplete_tls_connection_does_not_block_other_requests(self):
        # The old listening-socket TLS wrapper blocked inside accept while this
        # first connection sent no ClientHello, timing out every HTTPS client.
        with socket.create_connection(("127.0.0.1", self.server.server_port), timeout=3):
            with self.request("/information") as response:
                self.assertEqual("GrateMigrationCI", json.load(response)["Data"]["SourceIdentifier"])

    def test_https_requires_certificate_name_and_trust_validation(self):
        request = Request(self.url + "/information")
        with self.assertRaises(URLError) as error:
            urlopen(request, context=ssl.create_default_context(), timeout=3)
        self.assertIsInstance(error.exception.reason, ssl.SSLCertVerificationError)
        with socket.create_connection(("127.0.0.1", self.server.server_port), timeout=3) as connection:
            with self.assertRaises(ssl.SSLCertVerificationError):
                self.context.wrap_socket(connection, server_hostname="wrong-host.invalid")

    def test_exact_identifier_does_not_match_the_other_package(self):
        packages = self.search({"Filters": [selector("PackageIdentifier", "grate-devs.grate")]})
        self.assertEqual(["grate-devs.grate"], [p["PackageIdentifier"] for p in packages])
        self.assertEqual([], self.search({"Filters": [selector("PackageIdentifier", "GRATE-DEVS.GRATE")]}))
        self.assertEqual(1, len(self.search({"Filters": [selector("PackageIdentifier", "GRATE-DEVS.GRATE", "CaseInsensitive")]})))

    def test_inclusions_are_or_and_filters_are_and(self):
        packages = self.search({"Inclusions": [selector("PackageIdentifier", "missing.package"),
                                               selector("PackageIdentifier", "erikbra.grate")],
                                "Filters": [selector("PackageName", "grate"), selector("Market", "NO")]})
        self.assertEqual(["erikbra.grate"], [p["PackageIdentifier"] for p in packages])
        self.assertEqual([], self.search({"Filters": [selector("PackageIdentifier", "erikbra.grate"),
                                                      selector("PackageName", "different")]}))

    def test_msi_collision_is_returned_without_selecting_a_winner(self):
        for field, value, output in (("ProductCode", PRODUCT_CODE, "ProductCodes"),
                                     ("UpgradeCode", UPGRADE_CODE, "UpgradeCodes")):
            with self.subTest(field=field):
                packages = self.search({"Inclusions": [selector(field, value)]})
                self.assertEqual(2, len(packages))
                self.assertEqual([value.casefold()], packages[0]["Versions"][0][output])
        self.assertEqual(2, len(self.search({"Inclusions": [selector("NormalizedPackageNameAndPublisher", "grate")]})))

    def test_captured_lowercase_exact_product_code_matches_uppercase_msi_metadata(self):
        # Captured from WinGet v1.29.380's native ARM64 installed-package search.
        # Test the ProductCode without the name fallback so a GUID case defect
        # cannot be hidden by another inclusion matching the package name.
        request = {"Inclusions": [{"PackageMatchField": "ProductCode", "RequestMatch": {
            "KeyWord": "{e281998a-d8a2-4926-aaa3-066efa4b2e74}", "MatchType": "Exact"}}]}
        packages = self.search(request)
        self.assertEqual(["erikbra.grate", "grate-devs.grate"], [p["PackageIdentifier"] for p in packages])
        self.assertEqual(["{e281998a-d8a2-4926-aaa3-066efa4b2e74}"], packages[0]["Versions"][0]["ProductCodes"])
        with self.request("/packageManifests/erikbra.grate?Version=2.0.0") as response:
            installer = json.load(response)["Data"]["Versions"][0]["Installers"][0]
        self.assertEqual(PRODUCT_CODE, installer["ProductCode"])

    def test_reference_matching_is_case_insensitive_without_broadening_ordinary_exact(self):
        for field, value in (("ProductCode", PRODUCT_CODE), ("UpgradeCode", UPGRADE_CODE)):
            for kind in ("Inclusions", "Filters"):
                with self.subTest(field=field, kind=kind):
                    packages = self.search({kind: [selector(field, value.lower())]})
                    self.assertEqual(2, len(packages))
                    self.assertEqual([], self.search({kind: [selector(field, "{00000000-0000-0000-0000-000000000000}")]}))
        updated = catalog()
        for package in updated["Packages"]:
            for item in package["Versions"]:
                item["Installers"][0]["PackageFamilyName"] = "Publisher.Grate_abC123"
        self.write_catalog(updated)
        packages = self.search({"Filters": [selector("PackageFamilyName", "publisher.grate_abc123")]})
        self.assertEqual(2, len(packages))
        self.assertEqual(["publisher.grate_abc123"], packages[0]["Versions"][0]["PackageFamilyNames"])
        self.assertEqual([], self.search({"Filters": [selector("PackageIdentifier", "ERIKBRA.GRATE")]}))
        self.assertEqual([], self.search({"Filters": [selector("PackageName", "GRATE")]}))

    def test_version_filter_and_installer_metadata_are_not_lost(self):
        with self.request("/packageManifests/erikbra.grate?Version=2.0.0") as response:
            package = json.load(response)["Data"]
        self.assertEqual([version("2.0.0")], package["Versions"])
        with self.assertRaises(HTTPError) as error:
            self.request("/packageManifests/erikbra.grate?Version=9.9.9")
        self.assertEqual(404, error.exception.code)
        error.exception.close()

    def test_catalog_reload_adds_an_upgrade_without_changing_source(self):
        updated = catalog()
        updated["Packages"][1]["Versions"].append(version("2.1.7"))
        self.write_catalog(updated)
        packages = self.search({"Filters": [selector("PackageIdentifier", "grate-devs.grate")]})
        self.assertEqual(["2.1.6", "2.1.7"], [v["PackageVersion"] for v in packages[0]["Versions"]])
        with self.request("/information") as response:
            self.assertEqual("GrateMigrationCI", json.load(response)["Data"]["SourceIdentifier"])
        updated["SourceIdentifier"] = "ChangedIdentity"
        self.write_catalog(updated)
        with self.assertRaises(HTTPError) as error:
            self.request("/packageManifests/grate-devs.grate")
        self.assertEqual(500, error.exception.code)
        error.exception.close()

    def test_asset_download_head_and_path_confinement(self):
        with self.request("/assets/candidate.zip") as response:
            self.assertEqual(b"test candidate asset", response.read())
        with self.request("/assets/candidate.zip", method="HEAD") as response:
            self.assertEqual("20", response.headers["Content-Length"])
            self.assertEqual(b"", response.read())
        for path in ("/assets/../catalog.json", "/assets/%2e%2e/catalog.json", "/assets/missing.zip"):
            with self.subTest(path=path), self.assertRaises(HTTPError) as error:
                self.request(path)
            self.assertEqual(404, error.exception.code)
            error.exception.close()

    def test_invalid_request_is_not_treated_as_empty_success(self):
        with self.assertRaises(HTTPError) as error:
            self.search({"Filters": [selector("NotASupportedField", "grate")]})
        self.assertEqual(400, error.exception.code)
        error.exception.close()
        with self.assertRaises(HTTPError) as error:
            self.search({"MaximumResults": 1, "FetchAllManifests": True})
        self.assertEqual(400, error.exception.code)
        error.exception.close()

    def test_duplicate_versions_and_identifiers_are_rejected(self):
        for duplicate in ("version", "identifier"):
            invalid = catalog()
            if duplicate == "version":
                invalid["Packages"][0]["Versions"].append(version("2.0.0"))
            else:
                invalid["Packages"].append(copy.deepcopy(invalid["Packages"][0]))
            self.write_catalog(invalid)
            with self.subTest(duplicate=duplicate), self.assertRaisesRegex(ValueError, "Duplicate"):
                load_catalog(self.path)


if __name__ == "__main__":
    unittest.main()
