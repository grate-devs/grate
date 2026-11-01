import os
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import resolve_release_context as release


SHA = "a" * 40


class ReleaseContextTests(unittest.TestCase):
    def setUp(self):
        self.env = {"EVENT_NAME": "push", "GITVERSION_SEMVER": "2.3.4-alpha.12",
                    "GITHUB_SHA": SHA, "GITHUB_REPOSITORY": "grate-devs/grate"}
        self.reader = Mock(return_value={"isDraft": False, "isPrerelease": False})

    def resolve(self, **values):
        return release.resolve_context(self.env | values, release_reader=self.reader)

    def release_event(self, **values):
        return self.resolve(EVENT_NAME="release", RELEASE_ACTION="published", RELEASE_DRAFT="false",
                            RELEASE_TAG=values.pop("RELEASE_TAG", "2.3.4"),
                            RELEASE_PRERELEASE=values.pop("RELEASE_PRERELEASE", "false"), **values)

    def test_commit_build_uses_metadata_free_gitversion_and_exact_commit(self):
        context = self.resolve(GITVERSION_FULL_SEMVER="2.3.4-alpha.12+15")
        self.assertEqual({"checkout_ref": SHA, "core_version": "2.3.4", "version": "2.3.4-alpha.12",
                          "publish": "false", "prerelease": "true", "release_tag": ""}, context)
        self.reader.assert_not_called()

    def test_push_and_pull_request_ignore_manual_and_release_publish_inputs(self):
        for event in ("push", "pull_request", "pull_request_target", "schedule"):
            with self.subTest(event=event):
                context = self.resolve(EVENT_NAME=event, MANUAL_TAG="9.9.9", MANUAL_PUBLISH="true",
                                       RELEASE_TAG="8.8.8", RELEASE_PRERELEASE="false",
                                       RELEASE_ACTION="published", RELEASE_DRAFT="false")
                self.assertEqual("false", context["publish"])
                self.assertEqual("2.3.4-alpha.12", context["version"])
                self.assertEqual(SHA, context["checkout_ref"])
                self.assertEqual("", context["release_tag"])
        self.reader.assert_not_called()

    def test_published_stable_release_enables_publishing_with_tag_checkout(self):
        context = self.release_event()
        self.assertEqual({"checkout_ref": "2.3.4", "core_version": "2.3.4", "version": "2.3.4",
                          "publish": "true", "prerelease": "false", "release_tag": "2.3.4"}, context)
        self.reader.assert_not_called()

    def test_published_prerelease_preserves_full_version_and_flag(self):
        context = self.release_event(RELEASE_TAG="2.3.4-rc.1", RELEASE_PRERELEASE="true")
        self.assertEqual("2.3.4-rc.1", context["version"])
        self.assertEqual("2.3.4", context["core_version"])
        self.assertEqual("true", context["prerelease"])
        self.assertEqual("true", context["publish"])

    def test_unpublished_or_draft_release_events_are_rejected(self):
        for values in ({"RELEASE_ACTION": "created"}, {"RELEASE_ACTION": "released"},
                       {"RELEASE_ACTION": "prereleased"}, {"RELEASE_ACTION": ""},
                       {"RELEASE_DRAFT": "true"}, {"RELEASE_DRAFT": ""}, {"RELEASE_DRAFT": "False"}):
            with self.subTest(values=values), self.assertRaises(release.ContextError):
                release.resolve_context(self.env | {
                    "EVENT_NAME": "release", "RELEASE_ACTION": "published", "RELEASE_DRAFT": "false",
                    "RELEASE_TAG": "2.3.4", "RELEASE_PRERELEASE": "false",
                } | values, release_reader=self.reader)
        self.reader.assert_not_called()

    def test_release_event_requires_tag_and_explicit_valid_prerelease_boolean(self):
        for values in ({"RELEASE_TAG": ""}, {"RELEASE_PRERELEASE": ""},
                       {"RELEASE_PRERELEASE": "True"}, {"RELEASE_PRERELEASE": "0"}):
            with self.subTest(values=values), self.assertRaises(release.ContextError):
                self.release_event(**values)

    def test_release_prerelease_flag_must_match_tag_suffix(self):
        for version, flag in (("2.3.4", "true"), ("2.3.4-rc.1", "false")):
            with self.subTest(version=version), self.assertRaisesRegex(release.ContextError, "disagree"):
                self.release_event(RELEASE_TAG=version, RELEASE_PRERELEASE=flag)

    def test_manual_without_tag_and_publish_false_builds_current_commit(self):
        for flag in ("false", ""):
            with self.subTest(flag=flag):
                context = self.resolve(EVENT_NAME="workflow_dispatch", MANUAL_PUBLISH=flag)
                self.assertEqual("false", context["publish"])
                self.assertEqual(SHA, context["checkout_ref"])
                self.assertEqual("2.3.4-alpha.12", context["version"])
        self.reader.assert_not_called()

    def test_manual_tag_dry_run_derives_prerelease_without_reading_release_metadata(self):
        for version, flag in (("2.3.4", "false"), ("2.3.4-rc.1", "true")):
            with self.subTest(version=version):
                context = self.resolve(EVENT_NAME="workflow_dispatch", MANUAL_PUBLISH="false", MANUAL_TAG=version)
                self.assertEqual(version, context["checkout_ref"])
                self.assertEqual(version, context["release_tag"])
                self.assertEqual("false", context["publish"])
                self.assertEqual(flag, context["prerelease"])
        self.reader.assert_not_called()

    def test_manual_publish_requires_tag(self):
        with self.assertRaisesRegex(release.ContextError, "MANUAL_TAG"):
            self.resolve(EVENT_NAME="workflow_dispatch", MANUAL_PUBLISH="true")
        self.reader.assert_not_called()

    def test_manual_publish_accepts_existing_non_draft_stable_or_prerelease(self):
        for version, prerelease in (("2.3.4", False), ("2.3.4-rc.1", True)):
            with self.subTest(version=version):
                self.reader.return_value = {"isDraft": False, "isPrerelease": prerelease}
                context = self.resolve(EVENT_NAME="workflow_dispatch", MANUAL_PUBLISH="true", MANUAL_TAG=version)
                self.assertEqual("true", context["publish"])
                self.assertEqual(str(prerelease).lower(), context["prerelease"])
                self.reader.assert_called_with(version, "grate-devs/grate")

    def test_manual_publish_rejects_draft_missing_or_malformed_release_metadata(self):
        for metadata in ({"isDraft": True, "isPrerelease": False}, {}, None, [],
                         {"isDraft": False}, {"isPrerelease": False},
                         {"isDraft": "false", "isPrerelease": False},
                         {"isDraft": False, "isPrerelease": 0}):
            with self.subTest(metadata=metadata), self.assertRaises(release.ContextError):
                self.reader.return_value = metadata
                self.resolve(EVENT_NAME="workflow_dispatch", MANUAL_PUBLISH="true", MANUAL_TAG="2.3.4")

    def test_manual_publish_hides_release_lookup_failure_details(self):
        self.reader.side_effect = RuntimeError("SECRET_RESPONSE")
        with self.assertRaises(release.ContextError) as error:
            self.resolve(EVENT_NAME="workflow_dispatch", MANUAL_PUBLISH="true", MANUAL_TAG="2.3.4")
        self.assertNotIn("SECRET_RESPONSE", str(error.exception))

    def test_manual_publish_prerelease_setting_must_match_version(self):
        for version, flag in (("2.3.4", True), ("2.3.4-rc.1", False)):
            self.reader.return_value = {"isDraft": False, "isPrerelease": flag}
            with self.subTest(version=version), self.assertRaisesRegex(release.ContextError, "disagree"):
                self.resolve(EVENT_NAME="workflow_dispatch", MANUAL_PUBLISH="true", MANUAL_TAG=version)

    def test_manual_publish_rejects_invalid_boolean_and_repository_before_lookup(self):
        for values in ({"MANUAL_PUBLISH": "True"}, {"MANUAL_PUBLISH": "1"},
                       {"GITHUB_REPOSITORY": ""}, {"GITHUB_REPOSITORY": "bad\nrepository"}):
            with self.subTest(values=values), self.assertRaises(release.ContextError):
                release.resolve_context(self.env | {"EVENT_NAME": "workflow_dispatch", "MANUAL_PUBLISH": "true",
                                                   "MANUAL_TAG": "2.3.4"} | values, release_reader=self.reader)
        self.reader.assert_not_called()

    def test_missing_invalid_or_injected_versions_are_rejected_before_metadata_lookup(self):
        for version in ("", "latest", "v2.3.4", "2.3", "02.3.4", "2.03.4", "2.3.04",
                        "2.3.4-01", "2.3.4-rc.01", "2.3.4-", "2.3.4-rc..1",
                        "2.3.4+build.1", "2.3.4-rc.1+build.1", "2.3.4\npublish=true", "2.3.4;echo secret"):
            with self.subTest(version=version), self.assertRaises(release.ContextError):
                self.resolve(GITVERSION_SEMVER=version)
            if version:
                with self.subTest(tag=version), self.assertRaises(release.ContextError):
                    self.resolve(EVENT_NAME="workflow_dispatch", MANUAL_TAG=version, MANUAL_PUBLISH="true")
        self.reader.assert_not_called()

    def test_valid_prerelease_identifier_boundaries(self):
        for version in ("0.0.0", "2.3.4-0", "2.3.4-01a", "2.3.4-rc.0", "2.3.4--"):
            with self.subTest(version=version):
                self.assertEqual(version, self.resolve(GITVERSION_SEMVER=version)["version"])

    def test_nonrelease_requires_valid_commit_identity(self):
        for sha in ("", "main", "a" * 39, "a" * 41, SHA + "\npublish=true"):
            with self.subTest(sha=sha), self.assertRaisesRegex(release.ContextError, "GITHUB_SHA"):
                self.resolve(GITHUB_SHA=sha)
        self.assertEqual("b" * 64, self.resolve(GITHUB_SHA="b" * 64)["checkout_ref"])

    def test_gh_invocation_only_reads_requested_release_metadata(self):
        process = SimpleNamespace(returncode=0, stdout='{"isDraft":false,"isPrerelease":true}')
        with patch.object(release.subprocess, "run", return_value=process) as run:
            metadata = release.read_release("2.3.4-rc.1", "grate-devs/grate")
        self.assertEqual({"isDraft": False, "isPrerelease": True}, metadata)
        run.assert_called_once_with([
            "gh", "release", "view", "2.3.4-rc.1", "--repo", "grate-devs/grate",
            "--json", "isDraft,isPrerelease",
        ], capture_output=True, text=True, timeout=45)

    def test_gh_failure_and_invalid_json_are_redacted(self):
        for result in (SimpleNamespace(returncode=1, stdout="SECRET_RESPONSE"),
                       SimpleNamespace(returncode=0, stdout="SECRET_RESPONSE")):
            with self.subTest(result=result), patch.object(release.subprocess, "run", return_value=result):
                with self.assertRaises(release.ContextError) as error:
                    release.read_release("2.3.4", "grate-devs/grate")
                self.assertNotIn("SECRET_RESPONSE", str(error.exception))
        with patch.object(release.subprocess, "run", side_effect=subprocess.TimeoutExpired("SECRET_COMMAND", 45)):
            with self.assertRaises(release.ContextError) as error:
                release.read_release("2.3.4", "grate-devs/grate")
        self.assertNotIn("SECRET_COMMAND", str(error.exception))

    def test_cli_appends_outputs_and_summary_without_any_external_commands_for_dry_run(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            summary = Path(directory) / "summary"
            output.write_text("retained=existing\n")
            env = self.env | {"GITHUB_OUTPUT": str(output), "GITHUB_STEP_SUMMARY": str(summary)}
            with patch.dict(os.environ, env, clear=True), patch.object(release.subprocess, "run") as run:
                release.main()
            run.assert_not_called()
            values = dict(line.split("=", 1) for line in output.read_text().splitlines())
            self.assertEqual("existing", values.pop("retained"))
            self.assertEqual(self.resolve(), values)
            self.assertIn("- Publish: `false`", summary.read_text())
            self.assertIn("- Checkout ref: `" + SHA + "`", summary.read_text())

    def test_cli_validation_failure_does_not_write_outputs_or_summary(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            summary = Path(directory) / "summary"
            output.write_text("retained=existing\n")
            env = self.env | {"GITVERSION_SEMVER": "SECRET_INVALID_VERSION", "GITHUB_OUTPUT": str(output),
                              "GITHUB_STEP_SUMMARY": str(summary)}
            with patch.dict(os.environ, env, clear=True), self.assertRaises(SystemExit) as error:
                release.main()
            self.assertNotIn("SECRET_INVALID_VERSION", str(error.exception))
            self.assertEqual("retained=existing\n", output.read_text())
            self.assertFalse(summary.exists())

    def test_cli_requires_output_path_before_release_lookup(self):
        with patch.dict(os.environ, self.env, clear=True), patch.object(release, "resolve_context") as resolve:
            with self.assertRaisesRegex(SystemExit, "GITHUB_OUTPUT"):
                release.main()
        resolve.assert_not_called()


if __name__ == "__main__":
    unittest.main()
