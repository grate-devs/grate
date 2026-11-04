import copy
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import migrate_docker_tags as migration


def image(digest, architectures=("amd64",)):
    return {"digest": digest, "manifests": [digest], "blobs": ["sha256:blob"],
            "platforms": [{"os": "linux", "architecture": arch} for arch in architectures],
            "attestations": []}


class FakeRegistry:
    def __init__(self, tags):
        self.tags = copy.deepcopy(tags)
        self.blob_checks = []

    def manifest(self, tag):
        return self.tags[tag]["digest"], {}

    def resolve_digest(self, tag):
        return self.tags[tag]["digest"]

    def describe(self, tag, check_blobs=False):
        if check_blobs:
            self.blob_checks.append(tag)
        return copy.deepcopy(self.tags[tag])


class CopyTests(unittest.TestCase):
    def setUp(self):
        self.tags = {"1.8.0": image("sha256:old"),
                     "2.1.6": image("sha256:new", ("amd64", "arm64")),
                     "latest": image("sha256:new", ("amd64", "arm64"))}
        self.source = FakeRegistry(self.tags)
        self.destination = FakeRegistry({})
        self.plan = {"source": migration.SOURCE, "destination": migration.DESTINATION,
                     "tags": copy.deepcopy(self.tags)}
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.report = Path(self.directory.name) / "result.json"
        self.copy_calls = []
        patcher = patch.object(migration, "tag_names", side_effect=lambda repository:
                               list(self.source.tags if repository == migration.SOURCE else self.destination.tags))
        patcher.start()
        self.addCleanup(patcher.stop)

    def copy_image(self, digest, tag):
        self.copy_calls.append((digest, tag))
        self.destination.tags[tag] = copy.deepcopy(self.tags[tag])

    def run_copy(self, copy_image=None):
        return migration.copy_and_verify(self.plan, self.source, self.destination,
                                         self.report, copy_image or self.copy_image)

    def test_copies_frozen_digests_and_verifies_latest_last(self):
        result = self.run_copy()
        self.assertEqual([(self.tags[tag]["digest"], tag) for tag in self.tags], self.copy_calls)
        self.assertEqual("latest", self.destination.blob_checks[-1])
        self.assertEqual("verified", result["status"])
        self.assertEqual(self.tags["2.1.6"]["platforms"], result["tags"]["2.1.6"]["platforms"])

    def test_conflict_in_later_tag_prevents_all_writes(self):
        self.destination.tags["2.1.6"] = image("sha256:different")
        with self.assertRaisesRegex(migration.MigrationError, "conflicting"):
            self.run_copy()
        self.assertEqual([], self.copy_calls)

    def test_source_movement_prevents_writes(self):
        self.source.tags["latest"] = image("sha256:moved")
        with self.assertRaisesRegex(migration.MigrationError, "moved"):
            self.run_copy()
        self.assertEqual([], self.copy_calls)

    def test_matching_existing_tags_are_verified_without_recopying(self):
        self.destination.tags = copy.deepcopy(self.tags)
        result = self.run_copy()
        self.assertEqual([], self.copy_calls)
        self.assertEqual(set(self.tags), set(self.destination.blob_checks))
        self.assertTrue(all(tag["action"] == "already_present" for tag in result["tags"].values()))

    def test_matching_root_digest_does_not_hide_missing_platform(self):
        def incomplete_copy(digest, tag):
            self.copy_image(digest, tag)
            if tag == "2.1.6":
                self.destination.tags[tag]["platforms"] = []
        with self.assertRaisesRegex(migration.MigrationError, "mismatch"):
            self.run_copy(incomplete_copy)
        report = json.loads(self.report.read_text())
        self.assertEqual("failed", report["status"])
        self.assertNotIn("2.1.6", report["tags"])
        self.assertNotIn("latest", self.destination.tags)

    def test_final_source_change_is_not_reported_as_success(self):
        def moving_copy(digest, tag):
            self.copy_image(digest, tag)
            if tag == "latest":
                self.source.tags["latest"] = image("sha256:moved")
        with self.assertRaisesRegex(migration.MigrationError, "moved"):
            self.run_copy(moving_copy)
        self.assertEqual("failed", json.loads(self.report.read_text())["status"])

    def test_copy_uses_private_temporary_authfile_and_immutable_source(self):
        plan_path = Path(self.directory.name) / "plan.json"
        plan_path.write_text(json.dumps(self.plan))
        auth_paths = []
        def run_tool(arguments, **kwargs):
            authfile = Path(arguments[arguments.index("--authfile") + 1])
            auth_paths.append(authfile)
            self.assertEqual(0o600, authfile.stat().st_mode & 0o777)
            self.assertIn("auth", json.loads(authfile.read_text())["auths"]["docker.io"])
            self.assertNotIn("FAKE_TOKEN", " ".join(arguments))
            self.assertIn("--all", arguments)
            self.assertIn("--preserve-digests", arguments)
            self.assertIn("@sha256:", arguments[-2])
            self.assertTrue(arguments[-1].startswith("docker://docker.io/gratedevs/grate:"))
            tag = arguments[-1].split(":")[-1]
            self.copy_image(self.tags[tag]["digest"], tag)
            return SimpleNamespace(returncode=0)
        with patch.object(migration, "Registry", side_effect=[self.source, self.destination]), \
             patch.object(migration.shutil, "which", return_value="/usr/bin/skopeo"), \
             patch.object(migration.os, "getenv", side_effect=lambda name: "FAKE_TOKEN"), \
             patch.object(migration.subprocess, "run", side_effect=run_tool), \
             patch("sys.argv", ["migrate", "--plan", str(plan_path), "--copy", "--report-dir", self.directory.name]):
            migration.main()
        self.assertEqual(3, len(auth_paths))
        self.assertTrue(all(not path.exists() for path in auth_paths))


class ManifestTests(unittest.TestCase):
    def test_single_manifest_gets_platform_from_config(self):
        registry = migration.Registry(migration.SOURCE)
        manifest = {"schemaVersion": 2, "config": {"digest": "sha256:config"},
                    "layers": [{"digest": "sha256:layer"}]}
        with patch.object(registry, "manifest", return_value=("sha256:root", manifest)), \
             patch.object(registry, "config", return_value={"os": "linux", "architecture": "amd64"}), \
             patch.object(registry, "check_blob") as check:
            result = registry.describe("1.8.0", check_blobs=True)
        self.assertEqual([{"os": "linux", "architecture": "amd64"}], result["platforms"])
        self.assertEqual(2, check.call_count)

    def test_index_keeps_attestations_separate_from_runnable_platforms(self):
        registry = migration.Registry(migration.SOURCE)
        index = {"schemaVersion": 2, "manifests": [
            {"digest": "sha256:amd64", "platform": {"os": "linux", "architecture": "amd64"}},
            {"digest": "sha256:attestation", "platform": {"os": "unknown", "architecture": "unknown"},
             "annotations": {"vnd.docker.reference.type": "attestation-manifest"}},
        ]}
        manifest = {"schemaVersion": 2, "config": {"digest": "sha256:config"}, "layers": []}
        def lookup(reference):
            return ("sha256:index", index) if reference in ("tag", "sha256:index") else (reference, manifest)
        with patch.object(registry, "manifest", side_effect=lookup):
            result = registry.describe("tag")
        self.assertEqual([{"os": "linux", "architecture": "amd64"}], result["platforms"])
        self.assertEqual(["sha256:attestation"], result["attestations"])
        self.assertEqual(3, len(result["manifests"]))


if __name__ == "__main__":
    unittest.main()
