import base64
import io
import json
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import Mock
import urllib.error

from check_docker_access import canonical_authorization, check, grants


class AccessCheckTests(unittest.TestCase):
    def test_distinct_identities_are_used_and_all_three_boundaries_checked(self):
        request = Mock(side_effect=[{"pull", "push"}, {"pull"}, {"pull", "push"}])
        result = check("canonical", "legacy", request)
        self.assertEqual("verified", result["status"])
        self.assertEqual([("gratedevs/grate", "canonical"), ("erikbra/grate", "canonical"),
                          ("erikbra/grate", "legacy")],
                         [call.args[:2] for call in request.call_args_list])

    def test_http_denial_is_accepted_only_for_organization_to_legacy_boundary(self):
        denial = urllib.error.HTTPError("url", 403, "not logged", {}, None)
        self.addCleanup(denial.close)
        request = Mock(side_effect=[{"pull", "push"}, denial, {"pull", "push"}])
        self.assertEqual("verified", check("canonical", "legacy", request)["status"])
        request = Mock(side_effect=[denial, denial, {"pull", "push"}])
        self.assertEqual("failed", check("canonical", "legacy", request)["status"])

    def test_positive_login_alone_does_not_prove_push_and_excess_access_fails(self):
        for responses in ([{"pull"}, set(), {"pull", "push"}],
                          [{"pull", "push"}, {"push"}, {"pull", "push"}],
                          [{"pull", "push"}, set(), {"push"}]):
            with self.subTest(responses=responses):
                result = check("canonical", "legacy", Mock(side_effect=responses))
                self.assertEqual("failed", result["status"])

    def test_errors_are_redacted_and_remaining_identities_still_checked(self):
        request = Mock(side_effect=[RuntimeError("secret-value"), set(), {"pull", "push"}])
        result = check("canonical", "legacy", request)
        self.assertEqual("failed", result["status"])
        self.assertEqual(3, request.call_count)
        self.assertNotIn("secret-value", str(result))

    def test_canonical_config_cannot_fall_back_to_personal_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.json"
            for user in ("gratedevs", "erikbra"):
                encoded = base64.b64encode(f"{user}:short-lived-secret".encode()).decode()
                path.write_text(json.dumps({"auths": {"https://index.docker.io/v1/": {"auth": encoded}}}))
                if user == "gratedevs":
                    self.assertEqual("Basic " + encoded, canonical_authorization(path))
                else:
                    with self.assertRaises(ValueError):
                        canonical_authorization(path)

    def test_grants_requests_only_auth_endpoint_and_inspects_actual_repository_claims(self):
        payload = {"aud": "registry.docker.io", "exp": time.time() + 60, "access": [
            {"type": "repository", "name": "other/repo", "actions": ["push"]},
            {"type": "repository", "name": "gratedevs/grate", "actions": ["pull"]}]}
        encoded = base64.urlsafe_b64encode(json.dumps(payload).encode()).decode().rstrip("=")
        opener = Mock()
        opener.open.return_value = io.StringIO(json.dumps({"token": f"header.{encoded}.signature"}))
        self.assertEqual({"pull"}, grants("gratedevs/grate", "Basic private", opener))
        request = opener.open.call_args.args[0]
        self.assertEqual("GET", request.method)
        self.assertTrue(request.full_url.startswith("https://auth.docker.io/token?"))
        self.assertEqual("Basic private", request.get_header("Authorization"))


if __name__ == "__main__":
    unittest.main()
