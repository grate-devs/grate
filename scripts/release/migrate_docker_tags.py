#!/usr/bin/env python3
"""Snapshot, copy, and verify grate's Docker history without rebuilding images."""

import argparse
import base64
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request


SOURCE = "erikbra/grate"
DESTINATION = "gratedevs/grate"
ACCEPT = ", ".join((
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
))


class MigrationError(Exception):
    pass


class SafeRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not newurl.startswith("https://"):
            raise MigrationError("Refused a non-HTTPS redirect")
        redirected = super().redirect_request(req, fp, code, msg, headers, newurl)
        if redirected is not None:
            redirected.remove_header("Authorization")
        return redirected


class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def timestamp():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.replace(path)


def tag_names(repository):
    prefix = f"https://hub.docker.com/v2/repositories/{repository}/tags"
    url = prefix + "?page_size=100"
    tags, visited = set(), set()
    while url:
        if url in visited or not (url.startswith(prefix + "?") or url.startswith(prefix + "/?")):
            raise MigrationError("Unexpected Hub pagination URL")
        visited.add(url)
        with urllib.request.urlopen(url, timeout=45) as response:
            page = json.load(response)
        for item in page["results"]:
            tag = item["name"]
            if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}", tag):
                raise MigrationError("Unexpected Docker tag syntax")
            tags.add(tag)
        url = page.get("next")
    return sorted(tags, key=lambda tag: (tag == "latest", tag))


class Registry:
    def __init__(self, repository):
        self.repository = repository
        self.token = None
        self.token_expiry = 0
        self.manifests = {}
        self.configs = {}
        self.checked_blobs = set()
        self.opener = urllib.request.build_opener(SafeRedirects())

    def authorization(self):
        if time.monotonic() >= self.token_expiry:
            query = urllib.parse.urlencode({
                "service": "registry.docker.io",
                "scope": f"repository:{self.repository}:pull",
            })
            headers = {}
            user, secret = os.getenv("DOCKER_HUB_USER"), os.getenv("DOCKER_HUB_TOKEN")
            if bool(user) != bool(secret):
                raise MigrationError("Both Docker credential variables are required together")
            if user:
                basic = base64.b64encode(f"{user}:{secret}".encode()).decode()
                headers["Authorization"] = "Basic " + basic
            request = urllib.request.Request("https://auth.docker.io/token?" + query, headers=headers)
            opener = urllib.request.build_opener(NoRedirects())
            with opener.open(request, timeout=45) as response:
                data = json.load(response)
            self.token = data.get("token") or data["access_token"]
            self.token_expiry = time.monotonic() + max(1, data.get("expires_in", 60) - 15)
        return "Bearer " + self.token

    def request(self, resource, method="GET"):
        request = urllib.request.Request(
            f"https://registry-1.docker.io/v2/{self.repository}/{resource}",
            headers={"Authorization": self.authorization(), "Accept": ACCEPT}, method=method,
        )
        return self.opener.open(request, timeout=60)

    def manifest(self, reference):
        if not reference.startswith("sha256:"):
            reference = self.resolve_digest(reference)
        if reference in self.manifests:
            return self.manifests[reference]
        with self.request("manifests/" + reference) as response:
            raw = response.read()
            digest = "sha256:" + hashlib.sha256(raw).hexdigest()
            if response.headers.get("Docker-Content-Digest", digest) != digest:
                raise MigrationError("Registry manifest header and body digest disagree")
        if reference.startswith("sha256:") and reference != digest:
            raise MigrationError("Returned manifest differs from requested digest")
        data = json.loads(raw)
        if data.get("schemaVersion") != 2:
            raise MigrationError("Unsupported historical manifest schema")
        result = (digest, data)
        # Cache immutable digests only; tags must be resolved afresh on final checks.
        self.manifests[digest] = result
        return result

    def resolve_digest(self, tag):
        with self.request("manifests/" + tag, "HEAD") as response:
            digest = response.headers.get("Docker-Content-Digest", "")
        if not re.fullmatch(r"sha256:[a-f0-9]{64}", digest):
            raise MigrationError("Registry did not provide a valid manifest digest")
        return digest

    def config(self, digest):
        if digest not in self.configs:
            with self.request("blobs/" + digest) as response:
                raw = response.read(2 * 1024 * 1024 + 1)
            if len(raw) > 2 * 1024 * 1024 or "sha256:" + hashlib.sha256(raw).hexdigest() != digest:
                raise MigrationError("Config blob digest/size verification failed")
            self.configs[digest] = json.loads(raw)
        return self.configs[digest]

    def check_blob(self, digest):
        if digest not in self.checked_blobs:
            with self.request("blobs/" + digest, "HEAD") as response:
                if response.status != 200:
                    raise MigrationError("Referenced blob is unavailable")
            self.checked_blobs.add(digest)

    def describe(self, reference, check_blobs=False):
        root, _ = self.manifest(reference)
        manifests, blobs, platforms, attestations = set(), set(), set(), set()

        def visit(digest, descriptor=None):
            actual, data = self.manifest(digest)
            if actual in manifests:
                return
            manifests.add(actual)
            if "manifests" in data:
                for child in data["manifests"]:
                    visit(child["digest"], child)
                return
            config = data["config"]["digest"]
            blobs.add(config)
            blobs.update(layer["digest"] for layer in data.get("layers", []))
            descriptor = descriptor or {}
            annotations = descriptor.get("annotations", {})
            platform = descriptor.get("platform") or {
                key: value for key, value in self.config(config).items()
                if key in ("os", "architecture", "variant", "os.version", "os.features")
            }
            if annotations.get("vnd.docker.reference.type") == "attestation-manifest":
                attestations.add(actual)
            else:
                platforms.add(json.dumps(platform, sort_keys=True))

        visit(root)
        if check_blobs:
            for blob in sorted(blobs):
                self.check_blob(blob)
        return {
            "digest": root,
            "manifests": sorted(manifests),
            "blobs": sorted(blobs),
            "platforms": [json.loads(platform) for platform in sorted(platforms)],
            "attestations": sorted(attestations),
        }


def snapshot(source, destination):
    tags = tag_names(SOURCE)
    if not tags:
        raise MigrationError("Source has no tags")
    destination_tags = tag_names(DESTINATION)
    plan = {"source": SOURCE, "destination": DESTINATION, "created_at": timestamp(),
            "tags": {}, "destination_before": {}}
    for tag in tags:
        plan["tags"][tag] = source.describe(tag)
        print(f"Snapshot {tag}: {plan['tags'][tag]['digest']}", flush=True)
    for tag in destination_tags:
        plan["destination_before"][tag] = destination.describe(tag)
    for tag in set(tags).intersection(destination_tags):
        if plan["tags"][tag] != plan["destination_before"][tag]:
            raise MigrationError(f"Destination tag conflicts with source: {tag}")
    return plan


def verify_source(plan, source):
    if set(tag_names(SOURCE)) != set(plan["tags"]):
        raise MigrationError("Source tag inventory changed since the snapshot")
    for tag, expected in plan["tags"].items():
        if source.resolve_digest(tag) != expected["digest"]:
            raise MigrationError(f"Source tag moved since the snapshot: {tag}")


def copy_and_verify(plan, source, destination, report_path, copy_image):
    verify_source(plan, source)
    # Complete the conflict check before writing the first tag.
    existing = set(tag_names(DESTINATION))
    for tag in existing.intersection(plan["tags"]):
        if destination.describe(tag) != plan["tags"][tag]:
            raise MigrationError(f"Refusing to overwrite a conflicting destination tag: {tag}")
    result = {"source": SOURCE, "destination": DESTINATION, "started_at": timestamp(),
              "status": "in_progress", "tags": {}}
    write_json(report_path, result)
    try:
        # Move latest only after every version tag has been copied and verified.
        for tag in sorted(plan["tags"], key=lambda name: (name == "latest", name)):
            expected = plan["tags"][tag]
            if tag not in existing:
                copy_image(expected["digest"], tag)
            actual = destination.describe(tag, check_blobs=True)
            if actual != expected:
                raise MigrationError(f"Destination manifest graph/platform mismatch: {tag}")
            result["tags"][tag] = {"action": "already_present" if tag in existing else "copied",
                                   "verified_at": timestamp(), **actual}
            write_json(report_path, result)
            print(f"Verified {tag}: {actual['digest']}", flush=True)
        verify_source(plan, source)
        # Resolve every destination tag again; Hub's listing can lag registry writes.
        for tag, expected in plan["tags"].items():
            if destination.resolve_digest(tag) != expected["digest"]:
                raise MigrationError(f"Destination tag moved during copying: {tag}")
        result.update(status="verified", completed_at=timestamp())
        write_json(report_path, result)
        return result
    except Exception:
        result.update(status="failed", completed_at=timestamp())
        write_json(report_path, result)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report-dir", type=Path, required=True)
    parser.add_argument("--plan", type=Path, help="Use an existing immutable source snapshot")
    parser.add_argument("--copy", action="store_true", help="Copy the approved snapshot to gratedevs/grate")
    parser.add_argument("--verify", action="store_true", help="Only verify an already copied snapshot")
    args = parser.parse_args()
    if args.copy and args.verify:
        parser.error("Choose --copy or --verify")
    source, destination = Registry(SOURCE), Registry(DESTINATION)
    plan = json.loads(args.plan.read_text()) if args.plan else snapshot(source, destination)
    if plan["source"] != SOURCE or plan["destination"] != DESTINATION:
        raise MigrationError("Unexpected migration endpoints")
    write_json(args.report_dir / "plan.json", plan)
    if not (args.copy or args.verify):
        return
    if args.verify:
        def no_copy(digest, tag):
            raise MigrationError(f"Destination tag is absent: {tag}")
        copy_and_verify(plan, source, destination, args.report_dir / "verification.json", no_copy)
        return
    user, secret = os.getenv("DOCKER_HUB_USER"), os.getenv("DOCKER_HUB_TOKEN")
    if not user or not secret or not shutil.which("skopeo"):
        raise MigrationError("Copy requires both CI credentials and skopeo")
    with tempfile.TemporaryDirectory(prefix="grate-registry-auth-") as directory:
        authfile = Path(directory) / "auth.json"
        auth = base64.b64encode(f"{user}:{secret}".encode()).decode()
        descriptor = os.open(authfile, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, "w") as file:
            json.dump({"auths": {"docker.io": {"auth": auth}}}, file)

        def copy_image(digest, tag):
            process = subprocess.run([
                "skopeo", "copy", "--all", "--preserve-digests", "--retry-times", "2",
                "--authfile", str(authfile),
                f"docker://docker.io/{SOURCE}@{digest}", f"docker://docker.io/{DESTINATION}:{tag}",
            ], capture_output=True, text=True)
            if process.returncode:
                # Keep tool response text out of shared logs; never print auth material.
                raise MigrationError(f"skopeo copy failed for {tag}, exit {process.returncode}")

        copy_and_verify(plan, source, destination, args.report_dir / "copy-result.json", copy_image)


if __name__ == "__main__":
    try:
        main()
    except urllib.error.HTTPError as error:
        raise SystemExit(f"Registry/Hub HTTP {error.code}; migration stopped")
    except MigrationError as error:
        raise SystemExit(str(error))
    except Exception:
        raise SystemExit("Migration stopped after an unexpected error; no credential details logged")
