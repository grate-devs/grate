import base64
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import urllib.error

import copy_docker_release as release


RAW = b'{"schemaVersion":2,"manifests":[]}'
DIGEST = "sha256:" + hashlib.sha256(RAW).hexdigest()
OTHER_DIGEST = "sha256:" + "b" * 64
TAGS = "\n".join(("gratedevs/grate:latest", "erikbra/grate:latest",
                  "gratedevs/grate:2.3.4", "erikbra/grate:2.3.4"))


class FakeRegistry:
    def __init__(self):
        self.tags = {"latest": OTHER_DIGEST}
        self.checked = []

    def resolve_digest(self, tag):
        if tag not in self.tags:
            raise urllib.error.HTTPError("https://registry.example", 404, "not found", {}, None)
        return self.tags[tag]

    def describe(self, tag, check_blobs=False):
        self.checked.append((tag, check_blobs))
        return {"digest": self.resolve_digest(tag), "manifests": [DIGEST, "sha256:attestation"],
                "blobs": ["sha256:layer"],
                "platforms": [{"os": "linux", "architecture": "amd64"},
                              {"os": "linux", "architecture": "arm64"}],
                "attestations": ["sha256:attestation"]}


class CopyReleaseTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.authfile = self.root / "canonical-auth.json"
        self.authfile.write_text('{"auths":{"docker.io":{"auth":"OIDC_AUTH"}}}')
        self.report = self.root / "report.json"
        self.destination = FakeRegistry()
        self.commands = []
        self.destination_authfiles = []
        self.source_references = {}
        self.copy_failure = None
        self.after_copy = None
        registry_patch = patch.object(release, "Registry", return_value=self.destination)
        self.registry_factory = registry_patch.start()
        self.addCleanup(registry_patch.stop)
        tool_patch = patch.object(release.subprocess, "run", side_effect=self.skopeo)
        tool_patch.start()
        self.addCleanup(tool_patch.stop)

    def skopeo(self, arguments, **kwargs):
        self.commands.append(arguments)
        self.assertTrue(kwargs["capture_output"])
        self.assertGreater(kwargs["timeout"], 0)
        self.assertNotIn("LEGACY_SECRET", " ".join(arguments))
        if arguments[1] == "inspect":
            self.assertIn("--raw", arguments)
            self.assertEqual(str(self.authfile), arguments[arguments.index("--authfile") + 1])
            raw = self.source_references.get(arguments[-1], RAW)
            return SimpleNamespace(returncode=0, stdout=raw, stderr=b"")
        self.assertEqual("copy", arguments[1])
        self.assertIn("--all", arguments)
        self.assertIn("--preserve-digests", arguments)
        self.assertEqual(str(self.authfile), arguments[arguments.index("--src-authfile") + 1])
        destination_authfile = Path(arguments[arguments.index("--dest-authfile") + 1])
        self.destination_authfiles.append(destination_authfile)
        self.assertNotEqual(self.authfile, destination_authfile)
        self.assertEqual(0o600, destination_authfile.stat().st_mode & 0o777)
        auth = json.loads(destination_authfile.read_text())["auths"]["docker.io"]["auth"]
        self.assertEqual("legacy-user:LEGACY_SECRET", base64.b64decode(auth).decode())
        self.assertEqual(f"docker://docker.io/gratedevs/grate@{DIGEST}", arguments[-2])
        self.assertTrue(arguments[-1].startswith("docker://docker.io/erikbra/grate:"))
        if self.copy_failure is not None:
            return SimpleNamespace(returncode=1, stdout=b"LEGACY_SECRET", stderr=b"OIDC_AUTH")
        tag = arguments[-1].rsplit(":", 1)[1]
        self.destination.tags[tag] = DIGEST
        if self.after_copy:
            self.after_copy(tag)
        return SimpleNamespace(returncode=0, stdout=b"", stderr=b"")

    def run_copy(self, tags=TAGS, digest=DIGEST, user="legacy-user", secret="LEGACY_SECRET"):
        return release.copy_release(tags, digest, self.authfile, self.report, user, secret)

    def copies(self):
        return [command for command in self.commands if command[1] == "copy"]

    def report_data(self):
        text = self.report.read_text()
        self.assertNotIn("LEGACY_SECRET", text)
        self.assertNotIn("OIDC_AUTH", text)
        return json.loads(text)

    def test_copy_preserves_digest_all_platforms_and_attestations_with_separate_credentials(self):
        result = self.run_copy()
        self.assertEqual("verified", result["status"])
        self.registry_factory.assert_called_once_with("erikbra/grate")
        self.assertEqual(["2.3.4", "latest"], [copy[-1].rsplit(":", 1)[1] for copy in self.copies()])
        self.assertEqual([("2.3.4", True), ("latest", True)], self.destination.checked)
        self.assertEqual(["sha256:attestation"], result["tags"]["latest"]["attestations"])
        self.assertEqual(2, len(result["tags"]["latest"]["platforms"]))
        self.assertTrue(all(not path.exists() for path in self.destination_authfiles))
        self.assertTrue(self.authfile.exists(), "The caller owns the canonical credential file.")
        self.assertEqual(result, self.report_data())

    def test_prerelease_copies_version_only(self):
        result = self.run_copy("gratedevs/grate:2.3.4-rc.1\nerikbra/grate:2.3.4-rc.1")
        self.assertEqual(["2.3.4-rc.1"], list(result["tags"]))
        self.assertEqual(OTHER_DIGEST, self.destination.tags["latest"])

    def test_matching_existing_version_is_verified_without_copying_it(self):
        self.destination.tags["2.3.4"] = DIGEST
        result = self.run_copy()
        self.assertTrue(result["tags"]["2.3.4"]["already_present"])
        self.assertEqual(1, len(self.copies()))
        self.assertTrue(self.copies()[0][-1].endswith(":latest"))

    def test_conflicting_existing_version_fails_before_any_copy(self):
        self.destination.tags["2.3.4"] = OTHER_DIGEST
        with self.assertRaisesRegex(release.CopyError, "conflicting"):
            self.run_copy()
        self.assertEqual([], self.copies())
        self.assertEqual("failed", self.report_data()["status"])

    def test_invalid_inputs_fail_before_any_registry_call_or_copy(self):
        for tags in (
            "", "gratedevs/grate:2.3.4", TAGS + "\nother/grate:2.3.4",
            TAGS.replace("erikbra/grate:2.3.4", "erikbra/grate:2.3.5"),
            TAGS + "\nerikbra/grate:2.3.4", "gratedevs/grate:latest\nerikbra/grate:latest",
            TAGS + "\ngratedevs/grate:2.3.5\nerikbra/grate:2.3.5",
            TAGS.replace("2.3.4", "2.3.4-rc.1"),
            TAGS.replace("2.3.4", "other"), TAGS.replace("2.3.4", "2.3.4;echo injected"),
        ):
            with self.subTest(tags=tags), self.assertRaises(release.CopyError):
                self.run_copy(tags)
            self.assertEqual("failed", self.report_data()["status"])
        for digest in ("", "sha256:bad", "sha256:" + "A" * 64, DIGEST + "\nmalicious"):
            with self.subTest(digest=digest), self.assertRaises(release.CopyError):
                self.run_copy(digest=digest)
        self.registry_factory.assert_not_called()
        self.assertEqual([], self.commands)

    def test_missing_credentials_or_source_authfile_fail_before_registry_calls(self):
        for user, secret in (("", "token"), ("user", "")):
            with self.subTest(user=user), self.assertRaises(release.CopyError):
                self.run_copy(user=user, secret=secret)
        self.authfile.unlink()
        with self.assertRaisesRegex(release.CopyError, "missing"):
            self.run_copy()
        self.registry_factory.assert_not_called()

    def test_source_immutable_digest_or_tag_mismatch_prevents_all_copies(self):
        for reference in (f"@{DIGEST}", ":2.3.4", ":latest"):
            with self.subTest(reference=reference):
                self.source_references = {f"docker://docker.io/gratedevs/grate{reference}": b"different raw image"}
                with self.assertRaisesRegex(release.CopyError, "build digest"):
                    self.run_copy()
                self.assertEqual([], self.copies())
                self.assertEqual("failed", self.report_data()["status"])

    def test_copy_failure_records_attempt_and_keeps_latest_unchanged(self):
        self.copy_failure = True
        with self.assertRaisesRegex(release.CopyError, "compatibility copy failed") as failure:
            self.run_copy()
        self.assertNotIn("LEGACY_SECRET", str(failure.exception))
        result = self.report_data()
        self.assertEqual("failed", result["status"])
        self.assertEqual("copy_started", result["tags"]["2.3.4"]["status"])
        self.assertEqual("pending", result["tags"]["latest"]["status"])
        self.assertEqual(OTHER_DIGEST, self.destination.tags["latest"])
        self.assertTrue(all(not path.exists() for path in self.destination_authfiles))

    def test_destination_graph_failure_keeps_latest_unchanged_and_records_copy(self):
        with patch.object(self.destination, "describe", side_effect=RuntimeError("SECRET_RESPONSE")):
            with self.assertRaises(RuntimeError):
                self.run_copy()
        result = self.report_data()
        self.assertNotIn("SECRET_RESPONSE", self.report.read_text())
        self.assertEqual("copied", result["tags"]["2.3.4"]["status"])
        self.assertEqual("pending", result["tags"]["latest"]["status"])
        self.assertEqual(1, len(self.copies()))
        self.assertEqual(OTHER_DIGEST, self.destination.tags["latest"])
        self.assertTrue(all(not path.exists() for path in self.destination_authfiles))

    def test_destination_wrong_digest_is_not_reported_as_verified(self):
        self.after_copy = lambda tag: self.destination.tags.update({tag: OTHER_DIGEST})
        with self.assertRaisesRegex(release.CopyError, "Compatibility manifest"):
            self.run_copy()
        self.assertEqual("failed", self.report_data()["status"])
        self.assertEqual(1, len(self.copies()))

    def test_final_source_movement_is_detected(self):
        def move_source(tag):
            if tag == "latest":
                self.source_references["docker://docker.io/gratedevs/grate:latest"] = b"changed"
        self.after_copy = move_source
        with self.assertRaisesRegex(release.CopyError, "build digest"):
            self.run_copy()
        self.assertEqual("failed", self.report_data()["status"])
        self.assertTrue(all(not path.exists() for path in self.destination_authfiles))

    def test_final_destination_movement_is_detected(self):
        def move_destination(tag):
            if tag == "latest":
                self.destination.tags["2.3.4"] = OTHER_DIGEST
        self.after_copy = move_destination
        with self.assertRaisesRegex(release.CopyError, "changed during copying"):
            self.run_copy()
        self.assertEqual("failed", self.report_data()["status"])

    def test_skopeo_exception_is_redacted(self):
        with patch.object(release.subprocess, "run", side_effect=subprocess.TimeoutExpired("SECRET_COMMAND", 1)):
            with self.assertRaisesRegex(release.CopyError, "could not complete") as failure:
                self.run_copy()
        self.assertNotIn("SECRET_COMMAND", str(failure.exception))
        self.assertNotIn("SECRET_COMMAND", self.report.read_text())

    def test_cli_hides_unexpected_registry_errors(self):
        with patch.object(release, "copy_release", side_effect=RuntimeError("SECRET_RESPONSE")), \
             patch("sys.argv", ["copy", "--source-authfile", str(self.authfile), "--report", str(self.report)]):
            with self.assertRaises(SystemExit) as failure:
                release.main()
        self.assertNotIn("SECRET_RESPONSE", str(failure.exception))
        self.assertIn("redacted report", str(failure.exception))


if __name__ == "__main__":
    unittest.main()
