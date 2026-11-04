import unittest
from unittest.mock import Mock

from verify_docker_release import verify


class ReleaseVerificationTests(unittest.TestCase):
    digest = "sha256:" + "a" * 64
    tags = ["gratedevs/grate:3.0.0", "gratedevs/grate:latest",
            "erikbra/grate:3.0.0", "erikbra/grate:latest"]

    def test_every_tag_is_read_and_compared_to_build_digest(self):
        registry = Mock()
        registry.manifest.return_value = (self.digest, {})
        factory = Mock(return_value=registry)
        result = verify(self.tags, self.digest, factory)
        self.assertEqual("verified", result["status"])
        self.assertEqual(self.tags, [r["tag"] for r in result["tags"]])
        self.assertEqual(4, registry.manifest.call_count)
        self.assertEqual(["gratedevs/grate", "erikbra/grate"],
                         [call.args[0] for call in factory.call_args_list])

    def test_matching_repositories_with_wrong_digest_still_fail(self):
        registry = Mock()
        registry.manifest.return_value = ("sha256:" + "b" * 64, {})
        result = verify(self.tags, self.digest, lambda _: registry)
        self.assertEqual("failed", result["status"])
        self.assertTrue(all(r["status"] == "digest_mismatch" for r in result["tags"]))

    def test_partial_failure_checks_remaining_tags_and_redacts_exception(self):
        registry = Mock()
        registry.manifest.side_effect = [RuntimeError("sensitive response"),
                                        (self.digest, {}), (self.digest, {}), (self.digest, {})]
        result = verify(self.tags, self.digest, lambda _: registry)
        self.assertEqual("failed", result["status"])
        self.assertEqual("unavailable_or_invalid_manifest", result["tags"][0]["status"])
        self.assertEqual(3, sum(r["status"] == "verified" for r in result["tags"]))
        self.assertNotIn("sensitive", str(result))

    def test_failed_push_without_output_digest_records_every_current_tag_but_never_passes(self):
        registry = Mock()
        registry.manifest.return_value = (self.digest, {})
        result = verify(self.tags, None, lambda _: registry)
        self.assertEqual("failed", result["status"])
        self.assertEqual(4, registry.manifest.call_count)
        self.assertTrue(all(r["status"] == "observed_without_build_digest" for r in result["tags"]))

    def test_invalid_input_never_contacts_registry(self):
        factory = Mock()
        for tags, digest in [([], self.digest), (self.tags, ""),
                             (["another/repo:3.0.0"], self.digest),
                             (["gratedevs/grate:bad\ntag"], self.digest)]:
            with self.subTest(tags=tags, digest=digest):
                with self.assertRaises(ValueError):
                    verify(tags, digest, factory)
        factory.assert_not_called()


if __name__ == "__main__":
    unittest.main()
