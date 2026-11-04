#!/usr/bin/env python3
"""Check OIDC and legacy repository grants without uploading registry content."""

import argparse
import base64
import json
import os
from pathlib import Path
import time
import urllib.error
import urllib.parse
import urllib.request


class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def canonical_authorization(path):
    auths = json.loads(Path(path).read_text(encoding="utf-8"))["auths"]
    for host in ("https://index.docker.io/v1/", "docker.io", "registry-1.docker.io"):
        entry = auths.get(host, {})
        if "auth" in entry:
            encoded = entry["auth"]
            user, password = base64.b64decode(encoded, validate=True).decode().split(":", 1)
            if user != "gratedevs" or not password:
                raise ValueError("Expected organization-owned Docker login")
            return "Basic " + encoded
    raise ValueError("Docker Hub inline login is unavailable")


def grants(repository, authorization, opener):
    query = urllib.parse.urlencode({
        "service": "registry.docker.io", "scope": f"repository:{repository}:pull,push",
    })
    request = urllib.request.Request("https://auth.docker.io/token?" + query,
                                     headers={"Authorization": authorization}, method="GET")
    with opener.open(request, timeout=30) as response:
        data = json.load(response)
    token = data.get("token") or data.get("access_token")
    parts = token.split(".")
    if len(parts) != 3:
        raise ValueError("Unexpected token format")
    payload = parts[1] + "=" * (-len(parts[1]) % 4)
    claims = json.loads(base64.urlsafe_b64decode(payload))
    if claims.get("aud") != "registry.docker.io" or claims.get("exp", 0) <= time.time():
        raise ValueError("Unexpected audience or expired token")
    actions = set()
    for grant in claims.get("access", []):
        if grant.get("type") == "repository" and grant.get("name") == repository:
            actions.update(grant.get("actions", []))
    return actions


def check(canonical_auth, legacy_auth, request_grants=grants):
    opener = urllib.request.build_opener(NoRedirects())
    results = []
    for identity, repository, authorization, require_push in (
            ("organization_oidc", "gratedevs/grate", canonical_auth, True),
            ("organization_oidc", "erikbra/grate", canonical_auth, False),
            ("legacy_token", "erikbra/grate", legacy_auth, True)):
        result = {"identity": identity, "repository": repository}
        try:
            actions = request_grants(repository, authorization, opener)
            passed = {"pull", "push"} <= actions if require_push else "push" not in actions
            result.update(pull="pull" in actions, push="push" in actions,
                          status="verified" if passed else "unexpected_grants")
        except urllib.error.HTTPError as error:
            # A denial is meaningful for the negative boundary, but only after
            # the positive canonical check has independently established login.
            passed = not require_push and error.code in (401, 403)
            result.update(status="verified_denial" if passed else f"token_endpoint_http_{error.code}")
            error.close()
        except Exception:
            result.update(status="token_request_or_response_invalid")
        results.append(result)
    return {"status": "verified" if all(r["status"] in ("verified", "verified_denial")
                                         for r in results) else "failed", "grants": results}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--canonical-authfile", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    try:
        canonical = canonical_authorization(args.canonical_authfile)
        user, token = os.environ.get("DOCKER_HUB_USER"), os.environ.get("DOCKER_HUB_TOKEN")
        if user != "erikbra" or not token:
            raise ValueError("Legacy credential must belong to erikbra")
        legacy = "Basic " + base64.b64encode(f"{user}:{token}".encode()).decode()
        result = check(canonical, legacy)
    except Exception:
        # Configuration errors may include credential-bearing file contents.
        result = {"status": "failed", "grants": [], "error": "publishing_identity_configuration_invalid"}
    args.report.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2))
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as output:
            output.write("## Docker identity grant check (no image publication)\n\n")
            output.write(f"Result: {result['status']}\n\n")
            for grant in result["grants"]:
                output.write(f"- {grant['identity']} → `{grant['repository']}`: {grant['status']}\n")
    return 0 if result["status"] == "verified" else 1


if __name__ == "__main__":
    raise SystemExit(main())
