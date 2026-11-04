#!/usr/bin/env python3
"""Exercise dual publication using a disposable loopback-only registry and scratch images.

Requires Docker and Buildx. Creates an isolated builder/network. Never authenticates
to or publishes to Docker Hub. The builder, network, registry container, anonymous
volumes, and temporary build files are removed on exit.
"""

import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import urllib.request
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from release_tags import image_tags


REGISTRY_IMAGE = "registry:3@sha256:d4032d4cc323c1731c707931ecada07a53076eac38e3b61ae57533f170f2c6c3"
ACCEPT = "application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json"


def docker(*arguments):
    return subprocess.run(["docker", *arguments], check=True, text=True,
                          stdout=subprocess.PIPE).stdout.strip()


def main():
    container = "grate-dual-publish-" + uuid.uuid4().hex[:12]
    network = container + "-network"
    builder = container + "-builder"
    registry_address = container + ":5000"
    try:
        docker("network", "create", network)
        docker("run", "--detach", "--name", container, "--network", network,
               "--publish", "127.0.0.1::5000", REGISTRY_IMAGE)
        bindings = json.loads(docker("inspect", container))[0]["NetworkSettings"]["Ports"]["5000/tcp"]
        address = "127.0.0.1:" + bindings[0]["HostPort"]
        with tempfile.TemporaryDirectory(prefix="grate local registry ") as directory:
            root = Path(directory)
            config = root / "buildkitd.toml"
            config.write_text(f'[registry."{registry_address}"]\n  http = true\n', encoding="utf-8")
            docker("buildx", "create", "--name", builder, "--driver", "docker-container",
                   "--driver-opt", "network=" + network, "--buildkitd-config", str(config))
            (root / "Dockerfile").write_text("FROM scratch\nCOPY payload /payload\n", encoding="utf-8")

            def digest(tag):
                repository, reference = tag.split(":", 1)
                request = urllib.request.Request(
                    f"http://{address}/v2/{repository}/manifests/{reference}", headers={"Accept": ACCEPT})
                with urllib.request.urlopen(request, timeout=20) as response:
                    raw = response.read()
                index = json.loads(raw)
                platforms = {(m.get("platform", {}).get("os"), m.get("platform", {}).get("architecture"))
                             for m in index["manifests"]}
                assert {("linux", "amd64"), ("linux", "arm64")} <= platforms, platforms
                return "sha256:" + hashlib.sha256(raw).hexdigest()

            evidence = {}
            for version in ("3.0.0", "3.1.0-rc.1"):
                (root / "payload").write_text(version, encoding="utf-8")
                tags = image_tags(version)
                args = ["buildx", "build", "--builder", builder, "--platform", "linux/amd64,linux/arm64", "--push"]
                for tag in tags:
                    args += ["--tag", f"{registry_address}/{tag}"]
                docker(*args, str(root))
                results = {tag: digest(tag) for tag in tags}
                assert len(set(results.values())) == 1, results
                evidence[version] = results
            stable = evidence["3.0.0"]["gratedevs/grate:latest"]
            assert digest("gratedevs/grate:latest") == stable
            assert digest("erikbra/grate:latest") == stable
            assert evidence["3.1.0-rc.1"]["gratedevs/grate:3.1.0-rc.1"] != stable
            print(json.dumps({"status": "verified", "tags": evidence,
                              "latest_unchanged_after_prerelease": True}, indent=2))
    finally:
        subprocess.run(["docker", "buildx", "rm", "--force", builder],
                       check=False, stdout=subprocess.DEVNULL)
        subprocess.run(["docker", "rm", "--force", "--volumes", container],
                       check=False, stdout=subprocess.DEVNULL)
        subprocess.run(["docker", "network", "rm", network],
                       check=False, stdout=subprocess.DEVNULL)


if __name__ == "__main__":
    main()
