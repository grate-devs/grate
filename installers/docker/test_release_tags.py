from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import release_tags


class ReleaseTagsTests(unittest.TestCase):
    def test_stable_release_updates_both_version_and_latest(self):
        self.assertEqual([
            "gratedevs/grate:2.3.4", "gratedevs/grate:latest",
            "erikbra/grate:2.3.4", "erikbra/grate:latest",
        ], release_tags.image_tags("2.3.4"))

    def test_optional_v_prefix_is_removed_from_image_tags(self):
        self.assertEqual(release_tags.image_tags("2.3.4"), release_tags.image_tags("v2.3.4"))

    def test_prerelease_versions_never_update_latest(self):
        for version in ("2.3.4-alpha", "v2.3.4-rc.1", "2.3.4-0", "2.3.4-01a"):
            with self.subTest(version=version):
                normalized = version.removeprefix("v")
                self.assertEqual([
                    f"gratedevs/grate:{normalized}", f"erikbra/grate:{normalized}",
                ], release_tags.image_tags(version))

    def test_github_prerelease_flag_suppresses_latest_for_stable_version(self):
        self.assertEqual([
            "gratedevs/grate:2.3.4", "erikbra/grate:2.3.4",
        ], release_tags.image_tags("2.3.4", prerelease=True))

    def test_invalid_versions_and_output_injection_are_rejected(self):
        for version in (
            "", "latest", "V2.3.4", "2.3", "02.3.4", "2.03.4", "2.3.04",
            "2.3.4-01", "2.3.4-rc.01", "2.3.4-", "2.3.4-rc..1",
            "2.3.4+build.1", "2.3.4-rc.1+build.2", " 2.3.4", "2.3.4 ",
            "2.3.4\nlatest", "2.3.4\ntags<<EOF\nother/repository:latest\nEOF",
            "2.3.4;echo injected", "$(echo 2.3.4)", "2.3.4/other", "2.3.4-æ",
            "2.3.4-" + "a" * 123,
        ):
            with self.subTest(version=version), self.assertRaises(ValueError):
                release_tags.image_tags(version)

    def test_docker_maximum_tag_length_is_accepted(self):
        version = "2.3.4-" + "a" * 122
        self.assertEqual(128, len(release_tags.normalize_version(version)))

    def test_cli_appends_valid_github_outputs_and_prints_same_tags(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "github-output"
            output.write_text("existing=retained\n", encoding="utf-8")
            result = self.run_cli("v2.3.4", "--prerelease", "--github-output", str(output))
            self.assertEqual(0, result.returncode, result.stderr)
            tags = "gratedevs/grate:2.3.4\nerikbra/grate:2.3.4\n"
            self.assertEqual(tags, result.stdout)
            self.assertEqual(
                "existing=retained\nversion=2.3.4\nis-prerelease=true\n"
                f"tags<<GRATE_DOCKER_TAGS\n{tags}GRATE_DOCKER_TAGS\n"
                "canonical-tags<<GRATE_DOCKER_TAGS\ngratedevs/grate:2.3.4\nGRATE_DOCKER_TAGS\n"
                "compatibility-tags<<GRATE_DOCKER_TAGS\nerikbra/grate:2.3.4\nGRATE_DOCKER_TAGS\n",
                output.read_text(encoding="utf-8"),
            )

    def test_stable_cli_separates_both_identities_without_losing_latest(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "github-output"
            result = self.run_cli("2.3.4", "--github-output", str(output))
            self.assertEqual(0, result.returncode, result.stderr)
            contents = output.read_text(encoding="utf-8")
            self.assertIn("canonical-tags<<GRATE_DOCKER_TAGS\ngratedevs/grate:2.3.4\n"
                          "gratedevs/grate:latest\nGRATE_DOCKER_TAGS\n", contents)
            self.assertIn("compatibility-tags<<GRATE_DOCKER_TAGS\nerikbra/grate:2.3.4\n"
                          "erikbra/grate:latest\nGRATE_DOCKER_TAGS\n", contents)

    def test_cli_rejects_invalid_version_before_writing_outputs(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "github-output"
            result = self.run_cli("latest", "--github-output", str(output))
            self.assertNotEqual(0, result.returncode)
            self.assertEqual("", result.stdout)
            self.assertFalse(output.exists())

    @staticmethod
    def run_cli(*arguments):
        return subprocess.run(
            [sys.executable, str(Path(release_tags.__file__)), *arguments],
            check=False, capture_output=True, text=True,
        )


if __name__ == "__main__":
    unittest.main()
