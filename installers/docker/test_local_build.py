import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[2]


class LocalBuildTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="grate local Docker test ")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.events = self.root / "docker-events.jsonl"
        self.environment = os.environ.copy()
        self.environment.update({
            "PATH": str(self.root) + os.pathsep + self.environment["PATH"],
            "GRATE_TEST_DOCKER_EVENTS": str(self.events),
            "GRATE_TEST_VERSION": "2.3.4",
        })
        # Shadow both external tools. These tests never call a Docker daemon or
        # discover a real GitVersion installation on the test host.
        self.executable("docker", '''import json
import os
import sys
with open(os.environ["GRATE_TEST_DOCKER_EVENTS"], "a", encoding="utf-8") as events:
    events.write(json.dumps({"args": sys.argv[1:], "cwd": os.getcwd()}) + "\\n")
if sys.argv[1:] == ["buildx", "ls"]:
    print("multiarch-builder")
elif sys.argv[1:3] not in (["buildx", "use"], ["buildx", "build"]):
    sys.exit(17)
''')
        self.executable("dotnet", '''import os
import sys
if sys.argv[1:] == ["tool", "list", "-g"]:
    print("gitversion.tool")
elif sys.argv[1:] == ["gitversion", "/showvariable", "SemVer"]:
    print(os.environ["GRATE_TEST_VERSION"])
else:
    sys.exit(17)
''')

    def executable(self, name, body):
        path = self.root / name
        path.write_text(f"#!{sys.executable}\n{body}", encoding="utf-8")
        path.chmod(0o700)

    def run_script(self, *arguments):
        return subprocess.run(
            ["/bin/bash", str(REPOSITORY / "build-docker-local.sh"), *arguments],
            cwd=self.root, env=self.environment, check=False,
            capture_output=True, text=True, timeout=20,
        )

    def docker_events(self):
        return [json.loads(line) for line in self.events.read_text(encoding="utf-8").splitlines()] \
            if self.events.exists() else []

    def build_arguments(self):
        builds = [event for event in self.docker_events() if event["args"][:2] == ["buildx", "build"]]
        self.assertEqual(1, len(builds))
        return builds[0]["args"]

    @staticmethod
    def values(arguments, option):
        return [arguments[index + 1] for index, item in enumerate(arguments) if item == option]

    def test_stable_build_tags_both_names_and_latest_without_publishing(self):
        result = self.run_script()
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        arguments = self.build_arguments()
        self.assertEqual([
            "gratedevs/grate:2.3.4", "gratedevs/grate:latest",
            "erikbra/grate:2.3.4", "erikbra/grate:latest",
        ], self.values(arguments, "--tag"))
        self.assertEqual(["VERSION=2.3.4"], self.values(arguments, "--build-arg"))
        self.assertEqual(["linux/amd64,linux/arm64"], self.values(arguments, "--platform"))
        self.assertNotIn("--load", arguments)
        self.assertNotIn("--push", arguments)

    def test_prerelease_keeps_exact_version_and_does_not_tag_latest(self):
        self.environment["GRATE_TEST_VERSION"] = "2.3.4-rc.1"
        result = self.run_script("--arm64")
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        arguments = self.build_arguments()
        self.assertEqual([
            "gratedevs/grate:2.3.4-rc.1", "erikbra/grate:2.3.4-rc.1",
        ], self.values(arguments, "--tag"))
        self.assertEqual(["VERSION=2.3.4-rc.1"], self.values(arguments, "--build-arg"))
        self.assertEqual(["linux/arm64"], self.values(arguments, "--platform"))
        self.assertIn("--load", arguments)
        self.assertNotIn("--push", arguments)

    def test_outside_repository_invocation_uses_repository_context(self):
        result = self.run_script("--platform", "linux/amd64")
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertTrue(self.docker_events())
        self.assertTrue(all(Path(event["cwd"]) == REPOSITORY for event in self.docker_events()))
        arguments = self.build_arguments()
        self.assertEqual(["./installers/docker/Dockerfile"], self.values(arguments, "--file"))
        self.assertEqual(".", arguments[-1])
        self.assertEqual(["linux/amd64"], self.values(arguments, "--platform"))
        self.assertIn("--load", arguments)

    def test_multiplatform_load_fails_before_invoking_docker(self):
        result = self.run_script("--load")
        self.assertNotEqual(0, result.returncode)
        self.assertIn("--load requires a single platform", result.stderr)
        self.assertEqual([], self.docker_events())

    def test_missing_platform_value_fails_clearly_before_invoking_docker(self):
        for arguments in [("--platform",), ("--platform", "--load")]:
            with self.subTest(arguments=arguments):
                result = self.run_script(*arguments)
                self.assertNotEqual(0, result.returncode)
                self.assertIn("--platform requires a value", result.stderr)
                self.assertEqual([], self.docker_events())


if __name__ == "__main__":
    unittest.main()
