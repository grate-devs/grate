#!/usr/bin/env python3
"""Exercise real Skopeo digest preservation with local OCI layouts only.

No registry is contacted, no image is published, and no credential is used.
Requires skopeo on PATH. Includes amd64/arm64 manifests and an attestation.
"""

import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


def write_blob(root, value, media_type):
    raw = json.dumps(value, separators=(",", ":")).encode()
    digest = hashlib.sha256(raw).hexdigest()
    path = root / "blobs" / "sha256" / digest
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(raw)
    return {"mediaType": media_type, "digest": "sha256:" + digest, "size": len(raw)}


def fixture(root):
    root.mkdir()
    (root / "oci-layout").write_text('{"imageLayoutVersion":"1.0.0"}')
    descriptors = []
    for arch in ("amd64", "arm64"):
        config = write_blob(root, {"architecture": arch, "os": "linux",
                                   "rootfs": {"type": "layers", "diff_ids": []}},
                            "application/vnd.oci.image.config.v1+json")
        manifest = write_blob(root, {"schemaVersion": 2,
                                    "mediaType": "application/vnd.oci.image.manifest.v1+json",
                                    "config": config, "layers": []},
                              "application/vnd.oci.image.manifest.v1+json")
        manifest["platform"] = {"architecture": arch, "os": "linux"}
        descriptors.append(manifest)
    config = write_blob(root, {"architecture": "unknown", "os": "unknown",
                              "rootfs": {"type": "layers", "diff_ids": []}},
                        "application/vnd.oci.image.config.v1+json")
    statement = write_blob(root, {"_type": "https://in-toto.io/Statement/v0.1", "predicate": {}},
                           "application/vnd.in-toto+json")
    attestation = write_blob(root, {"schemaVersion": 2,
                                   "mediaType": "application/vnd.oci.image.manifest.v1+json",
                                   "config": config, "layers": [statement]},
                             "application/vnd.oci.image.manifest.v1+json")
    attestation.update(platform={"architecture": "unknown", "os": "unknown"}, annotations={
        "vnd.docker.reference.type": "attestation-manifest",
        "vnd.docker.reference.digest": descriptors[0]["digest"],
    })
    descriptors.append(attestation)
    index = write_blob(root, {"schemaVersion": 2,
                             "mediaType": "application/vnd.oci.image.index.v1+json",
                             "manifests": descriptors}, "application/vnd.oci.image.index.v1+json")
    index["annotations"] = {"org.opencontainers.image.ref.name": "3.0.0"}
    (root / "index.json").write_text(json.dumps({"schemaVersion": 2, "manifests": [index]}))
    return index["digest"]


def main():
    with tempfile.TemporaryDirectory(prefix="grate offline OCI copy ") as directory:
        root = Path(directory)
        source, destination = root / "canonical", root / "compatibility"
        expected = fixture(source)
        version = subprocess.run(["skopeo", "--version"], check=True, capture_output=True, text=True).stdout.strip()
        subprocess.run(["skopeo", "copy", "--all", "--preserve-digests",
                        f"oci:{source}:3.0.0", f"oci:{destination}:3.0.0"],
                       check=True, capture_output=True, timeout=60)
        raw = subprocess.run(["skopeo", "inspect", "--raw", f"oci:{destination}:3.0.0"],
                             check=True, capture_output=True, timeout=30).stdout
        actual = "sha256:" + hashlib.sha256(raw).hexdigest()
        assert actual == expected, (expected, actual)
        for blob in (source / "blobs" / "sha256").iterdir():
            copied = destination / "blobs" / "sha256" / blob.name
            assert copied.read_bytes() == blob.read_bytes(), blob.name
        assert len(json.loads(raw)["manifests"]) == 3
        print(json.dumps({"status": "verified", "tool": version, "digest": actual,
                          "platforms": ["linux/amd64", "linux/arm64"], "attestations": 1,
                          "registry_publication": False}, indent=2))


if __name__ == "__main__":
    main()
