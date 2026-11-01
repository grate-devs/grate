import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import urllib.error

import publish_docker_archive as release


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
        self.checked.append(tag)
        if tag not in self.tags:
            raise urllib.error.HTTPError("https://registry.example", 404, "not found", {}, None)
        return self.tags[tag]


class PublishArchiveTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.archive = self.root / "image.tar"
        self.archive.write_bytes(b"build archive")
        self.authfile = self.root / "canonical-auth.json"
        self.authfile.write_text('{"auths":{"docker.io":{"auth":"OIDC_AUTH"}}}')
        self.report = self.root / "report.json"
        self.destination = FakeRegistry()
        self.commands = []
        self.archive_raw = RAW
        self.reference_raw = {}
        self.fail_copy = None
        self.after_copy = None
        self.journal = []
        self.preflight_tags = ["2.3.4", "latest"]
        env_patch = patch.dict(os.environ, {"DOCKER_HUB_USER": "", "DOCKER_HUB_TOKEN": ""})
        env_patch.start()
        self.addCleanup(env_patch.stop)
        registry_patch = patch.object(release, "Registry", return_value=self.destination)
        self.registry_factory = registry_patch.start()
        self.addCleanup(registry_patch.stop)
        tool_patch = patch("copy_docker_release.subprocess.run", side_effect=self.skopeo)
        tool_patch.start()
        self.addCleanup(tool_patch.stop)

    def skopeo(self, arguments, **kwargs):
        self.commands.append(arguments)
        self.assertTrue(kwargs["capture_output"])
        self.assertGreater(kwargs["timeout"], 0)
        self.assertNotIn("OIDC_AUTH", " ".join(arguments))
        self.assertNotIn("LEGACY_SECRET", " ".join(arguments))
        if arguments[1] == "inspect":
            if arguments[-1].startswith("oci-archive:"):
                self.assertEqual(["skopeo", "inspect", "--raw", f"oci-archive:{self.archive}"], arguments)
                return SimpleNamespace(returncode=0, stdout=self.archive_raw, stderr=b"")
            self.assertEqual(["skopeo", "inspect", "--raw", "--authfile", str(self.authfile)], arguments[:-1])
            tag = arguments[-1].rsplit(":", 1)[1]
            self.assertEqual(f"docker://docker.io/gratedevs/grate:{tag}", arguments[-1])
            self.assertIn(tag, self.destination.tags)
            raw = self.reference_raw.get(tag, RAW if self.destination.tags[tag] == DIGEST else b"changed")
            return SimpleNamespace(returncode=0, stdout=raw, stderr=b"")
        self.assertEqual("copy", arguments[1])
        self.assertEqual([
            "skopeo", "copy", "--all", "--preserve-digests", "--retry-times", "2",
            "--dest-authfile", str(self.authfile), f"oci-archive:{self.archive}",
        ], arguments[:-1])
        self.assertEqual(self.preflight_tags, self.destination.checked)
        tag = arguments[-1].rsplit(":", 1)[1]
        self.assertEqual(f"docker://docker.io/gratedevs/grate:{tag}", arguments[-1])
        state = self.report_data()
        self.assertEqual("copy_started", state["tags"][tag]["status"])
        if tag == "latest":
            version = next(name for name in state["tags"] if name != "latest")
            self.assertEqual("verified", state["tags"][version]["status"])
        self.journal.append(state)
        if self.fail_copy == tag:
            return SimpleNamespace(returncode=1, stdout=b"LEGACY_SECRET", stderr=b"OIDC_AUTH")
        self.destination.tags[tag] = DIGEST
        if self.after_copy:
            self.after_copy(tag)
        return SimpleNamespace(returncode=0, stdout=b"", stderr=b"")

    def run_publish(self, tags=TAGS, digest=DIGEST):
        return release.publish_archive(tags, digest, self.archive, self.authfile, self.report)

    def copies(self):
        return [command for command in self.commands if command[1] == "copy"]

    def report_data(self):
        text = self.report.read_text()
        self.assertNotIn("OIDC_AUTH", text)
        self.assertNotIn("LEGACY_SECRET", text)
        return json.loads(text)

    def test_publishes_exact_archive_with_oidc_preserving_index_before_latest(self):
        result = self.run_publish()
        self.registry_factory.assert_called_once_with("gratedevs/grate")
        self.assertEqual("verified", result["status"])
        self.assertEqual(["2.3.4", "latest"], [copy[-1].rsplit(":", 1)[1] for copy in self.copies()])
        self.assertTrue(all(entry["status"] == "verified" for entry in result["tags"].values()))
        self.assertEqual(result, self.report_data())
        self.assertTrue(self.archive.exists(), "The caller owns the archive.")
        self.assertIn("OIDC_AUTH", self.authfile.read_text(), "The caller owns the authentication file.")

    def test_archive_digest_mismatch_prevents_registry_calls_and_all_writes(self):
        self.archive_raw = b"different build archive"
        with self.assertRaisesRegex(release.CopyError, "archive differs"):
            self.run_publish()
        self.registry_factory.assert_not_called()
        self.assertEqual([], self.copies())
        self.assertEqual("failed", self.report_data()["status"])

    def test_conflicting_version_prevents_all_writes(self):
        self.destination.tags["2.3.4"] = OTHER_DIGEST
        with self.assertRaisesRegex(release.CopyError, "conflicting"):
            self.run_publish()
        self.assertEqual([], self.copies())
        self.assertEqual("failed", self.report_data()["status"])

    def test_matching_version_is_verified_without_overwriting(self):
        self.destination.tags["2.3.4"] = DIGEST
        result = self.run_publish()
        self.assertTrue(result["tags"]["2.3.4"]["already_present"])
        self.assertEqual(["latest"], [copy[-1].rsplit(":", 1)[1] for copy in self.copies()])
        self.assertEqual("verified", self.journal[0]["tags"]["2.3.4"]["status"])

    def test_prerelease_does_not_touch_latest(self):
        self.preflight_tags = ["2.3.4-rc.1"]
        result = self.run_publish("gratedevs/grate:2.3.4-rc.1\nerikbra/grate:2.3.4-rc.1")
        self.assertEqual(["2.3.4-rc.1"], list(result["tags"]))
        self.assertEqual(OTHER_DIGEST, self.destination.tags["latest"])
        self.assertEqual(1, len(self.copies()))

    def test_invalid_tags_and_digest_fail_before_tools_and_registry(self):
        for tags in ("", "gratedevs/grate:2.3.4", TAGS + "\nother/grate:2.3.4",
                     TAGS.replace("2.3.4", "2.3.4-rc.1"), TAGS.replace("2.3.4", "2.3.4;bad")):
            with self.subTest(tags=tags), self.assertRaises(release.CopyError):
                self.run_publish(tags)
        for digest in ("", "sha256:bad", "sha256:" + "A" * 64):
            with self.subTest(digest=digest), self.assertRaises(release.CopyError):
                self.run_publish(digest=digest)
        self.registry_factory.assert_not_called()
        self.assertEqual([], self.commands)

    def test_missing_archive_or_authfile_prevents_tools_and_registry(self):
        self.archive.unlink()
        with self.assertRaisesRegex(release.CopyError, "archive is missing"):
            self.run_publish()
        self.archive.touch()
        self.authfile.unlink()
        with self.assertRaisesRegex(release.CopyError, "authentication file is missing"):
            self.run_publish()
        self.registry_factory.assert_not_called()
        self.assertEqual([], self.commands)

    def test_legacy_credentials_are_rejected_before_any_authentication(self):
        for credentials in ({"DOCKER_HUB_USER": "legacy-user"}, {"DOCKER_HUB_TOKEN": "LEGACY_SECRET"},
                            {"DOCKER_HUB_USER": "legacy-user", "DOCKER_HUB_TOKEN": "LEGACY_SECRET"}):
            with self.subTest(credentials=credentials), patch.dict(os.environ, credentials):
                with self.assertRaisesRegex(release.CopyError, "compatibility Docker credentials"):
                    self.run_publish()
        self.registry_factory.assert_not_called()
        self.assertEqual([], self.commands)

    def test_registry_failure_other_than_404_does_not_allow_writes(self):
        error = urllib.error.HTTPError("https://registry.example", 401, "OIDC_AUTH", {}, None)
        self.addCleanup(error.close)
        with patch.object(self.destination, "resolve_digest", side_effect=error):
            with self.assertRaises(urllib.error.HTTPError):
                self.run_publish()
        self.assertEqual([], self.copies())
        self.assertEqual("failed", self.report_data()["status"])

    def test_copy_failure_preserves_partial_journal_and_redacts_tool_output(self):
        self.fail_copy = "latest"
        with self.assertRaisesRegex(release.CopyError, "canonical copy failed") as failure:
            self.run_publish()
        self.assertNotIn("OIDC_AUTH", str(failure.exception))
        self.assertNotIn("LEGACY_SECRET", str(failure.exception))
        result = self.report_data()
        self.assertEqual("failed", result["status"])
        self.assertEqual("verified", result["tags"]["2.3.4"]["status"])
        self.assertEqual("copy_started", result["tags"]["latest"]["status"])
        self.assertEqual(OTHER_DIGEST, self.destination.tags["latest"])

    def test_wrong_version_readback_keeps_latest_unchanged(self):
        self.reference_raw["2.3.4"] = b"different remote manifest"
        with self.assertRaisesRegex(release.CopyError, "build digest"):
            self.run_publish()
        result = self.report_data()
        self.assertEqual("copied", result["tags"]["2.3.4"]["status"])
        self.assertEqual("pending", result["tags"]["latest"]["status"])
        self.assertEqual(1, len(self.copies()))
        self.assertEqual(OTHER_DIGEST, self.destination.tags["latest"])

    def test_final_version_movement_is_detected(self):
        def move_version(tag):
            if tag == "latest":
                self.destination.tags["2.3.4"] = OTHER_DIGEST
        self.after_copy = move_version
        with self.assertRaisesRegex(release.CopyError, "build digest"):
            self.run_publish()
        self.assertEqual("failed", self.report_data()["status"])

    def test_skopeo_exception_is_redacted(self):
        with patch("copy_docker_release.subprocess.run", side_effect=subprocess.TimeoutExpired("OIDC_AUTH", 1)):
            with self.assertRaisesRegex(release.CopyError, "could not complete") as failure:
                self.run_publish()
        self.assertNotIn("OIDC_AUTH", str(failure.exception))
        self.assertEqual("failed", self.report_data()["status"])

    def test_cli_uses_explicit_artifact_and_env_inputs_without_stdout(self):
        with patch.dict(os.environ, {"DOCKER_TAGS": TAGS, "EXPECTED_DIGEST": DIGEST}), \
             patch.object(release, "publish_archive") as publish, \
             patch("builtins.print") as output, \
             patch("sys.argv", ["publish", "--archive", str(self.archive), "--authfile", str(self.authfile),
                                "--report", str(self.report)]):
            release.main()
        publish.assert_called_once_with(TAGS, DIGEST, self.archive, self.authfile, self.report)
        output.assert_not_called()

    def test_verify_only_validates_local_archive_without_tags_auth_or_registry(self):
        self.authfile.unlink()
        with patch.dict(os.environ, {"EXPECTED_DIGEST": DIGEST, "DOCKER_TAGS": "",
                                     "DOCKER_HUB_TOKEN": "LEGACY_SECRET"}), \
             patch("sys.argv", ["publish", "--verify-only", "--archive", str(self.archive),
                                "--report", str(self.report)]), \
             patch("builtins.print") as output:
            release.main()
        self.registry_factory.assert_not_called()
        self.assertEqual([["skopeo", "inspect", "--raw", f"oci-archive:{self.archive}"]], self.commands)
        self.assertEqual([], self.copies())
        result = self.report_data()
        self.assertEqual("verified", result["status"])
        self.assertEqual(DIGEST, result["digest"])
        output.assert_not_called()

    def test_verify_only_digest_mismatch_fails_without_registry_access(self):
        self.archive_raw = b"different archive manifest"
        with patch.dict(os.environ, {"EXPECTED_DIGEST": DIGEST, "DOCKER_TAGS": ""}), \
             patch("sys.argv", ["publish", "--verify-only", "--archive", str(self.archive),
                                "--report", str(self.report)]):
            with self.assertRaisesRegex(SystemExit, "archive differs"):
                release.main()
        self.registry_factory.assert_not_called()
        self.assertEqual([["skopeo", "inspect", "--raw", f"oci-archive:{self.archive}"]], self.commands)
        self.assertEqual([], self.copies())
        self.assertEqual("failed", self.report_data()["status"])

    def test_verify_only_invalid_digest_fails_before_any_tool_or_registry(self):
        with self.assertRaisesRegex(release.CopyError, "SHA256"):
            release.verify_archive("", self.archive, self.report)
        self.assertEqual([], self.commands)
        self.registry_factory.assert_not_called()
        self.assertEqual("failed", self.report_data()["status"])

    def test_preflight_only_accepts_missing_version_without_authfile_or_writes(self):
        self.authfile.unlink()
        with patch.dict(os.environ, {"EXPECTED_DIGEST": DIGEST, "DOCKER_TAGS": TAGS}), \
             patch("sys.argv", ["publish", "--preflight-only", "--archive", str(self.archive),
                                "--report", str(self.report)]):
            release.main()
        self.registry_factory.assert_called_once_with("gratedevs/grate")
        self.assertEqual(["2.3.4", "latest"], self.destination.checked)
        self.assertEqual([["skopeo", "inspect", "--raw", f"oci-archive:{self.archive}"]], self.commands)
        self.assertEqual([], self.copies())
        self.assertEqual({"latest": OTHER_DIGEST}, self.destination.tags)
        result = self.report_data()
        self.assertEqual("preflight", result["mode"])
        self.assertEqual("verified", result["status"])
        self.assertTrue(all(entry["status"] == "preflight_verified" for entry in result["tags"].values()))
        self.assertFalse(result["tags"]["2.3.4"]["already_present"])

    def test_preflight_only_accepts_matching_version_without_writes(self):
        self.authfile.unlink()
        self.destination.tags["2.3.4"] = DIGEST
        result = release.preflight_release(TAGS, DIGEST, self.archive, self.report)
        self.assertEqual("verified", result["status"])
        self.assertTrue(result["tags"]["2.3.4"]["already_present"])
        self.assertEqual([["skopeo", "inspect", "--raw", f"oci-archive:{self.archive}"]], self.commands)
        self.assertEqual([], self.copies())
        self.assertEqual(OTHER_DIGEST, self.destination.tags["latest"])

    def test_preflight_only_rejects_conflicting_version_without_writes(self):
        self.destination.tags["2.3.4"] = OTHER_DIGEST
        with self.assertRaisesRegex(release.CopyError, "conflicting"):
            release.preflight_release(TAGS, DIGEST, self.archive, self.report)
        self.assertEqual([["skopeo", "inspect", "--raw", f"oci-archive:{self.archive}"]], self.commands)
        self.assertEqual([], self.copies())
        self.assertEqual("failed", self.report_data()["status"])
        self.assertEqual(OTHER_DIGEST, self.destination.tags["2.3.4"])

    def test_preflight_only_rejects_legacy_credentials_before_any_authentication(self):
        with patch.dict(os.environ, {"DOCKER_HUB_TOKEN": "LEGACY_SECRET"}):
            with self.assertRaisesRegex(release.CopyError, "compatibility Docker credentials"):
                release.preflight_release(TAGS, DIGEST, self.archive, self.report)
        self.registry_factory.assert_not_called()
        self.assertEqual([], self.commands)
        self.assertEqual("failed", self.report_data()["status"])

    def test_preflight_only_checks_archive_digest_before_registry_access(self):
        self.archive_raw = b"different archive manifest"
        with self.assertRaisesRegex(release.CopyError, "archive differs"):
            release.preflight_release(TAGS, DIGEST, self.archive, self.report)
        self.registry_factory.assert_not_called()
        self.assertEqual([], self.copies())
        self.assertEqual("failed", self.report_data()["status"])

    def test_read_only_modes_are_mutually_exclusive(self):
        with patch("sys.argv", ["publish", "--verify-only", "--preflight-only",
                                "--archive", str(self.archive), "--report", str(self.report)]), \
             patch("sys.stderr"):
            with self.assertRaises(SystemExit) as failure:
                release.main()
        self.assertEqual(2, failure.exception.code)
        self.registry_factory.assert_not_called()
        self.assertEqual([], self.commands)

    def test_publication_still_requires_an_authfile_argument(self):
        with patch("sys.argv", ["publish", "--archive", str(self.archive), "--report", str(self.report)]), \
             patch.object(release, "publish_archive") as publish, \
             patch("sys.stderr"):
            with self.assertRaises(SystemExit) as failure:
                release.main()
        self.assertEqual(2, failure.exception.code)
        publish.assert_not_called()
        self.assertEqual([], self.commands)
        self.registry_factory.assert_not_called()

    def test_cli_hides_unexpected_registry_errors(self):
        with patch.object(release, "publish_archive", side_effect=RuntimeError("OIDC_AUTH")), \
             patch("sys.argv", ["publish", "--archive", str(self.archive), "--authfile", str(self.authfile),
                                "--report", str(self.report)]):
            with self.assertRaises(SystemExit) as failure:
                release.main()
        self.assertNotIn("OIDC_AUTH", str(failure.exception))
        self.assertIn("redacted report", str(failure.exception))


if __name__ == "__main__":
    unittest.main()
