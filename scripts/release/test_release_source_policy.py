"""Keep executable release sources in the workflow event's ref/security context."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[2]


class ReleaseSourcePolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.jobs = yaml.safe_load((ROOT / '.github/workflows/build.yml').read_text())['jobs']
        cls.tag_check = next(step for step in cls.jobs['set-version-number']['steps']
                             if step.get('name') == 'Verify release tag identifies the event commit')

    def test_all_checkouts_and_source_provenance_use_immutable_event_sha(self):
        checkouts = []
        for name, job in self.jobs.items():
            for step in job.get('steps', []):
                if step.get('uses', '').startswith('actions/checkout@') and 'repository' not in step.get('with', {}):
                    checkouts.append(name)
                    self.assertEqual('${{ github.sha }}', step['with']['ref'], name)
                if 'SOURCE_COMMIT' in step.get('env', {}):
                    self.assertEqual('${{ github.sha }}', step['env']['SOURCE_COMMIT'], name)
                if 'labels' in step.get('with', {}):
                    self.assertIn('org.opencontainers.image.revision=${{ github.sha }}', step['with']['labels'])
        self.assertGreater(len(checkouts), 10)
        self.assertNotIn('checkout-ref', self.jobs['set-version-number']['outputs'])

    def test_build_and_publish_jobs_depend_on_source_validation(self):
        for name, job in self.jobs.items():
            if name == 'set-version-number':
                continue
            needs = job.get('needs', [])
            if isinstance(needs, str):
                needs = [needs]
            # release-ready depends on the builders, which each require source validation.
            self.assertTrue('set-version-number' in needs or name == 'release-ready', name)
            if name != 'release-ready':
                self.assertNotIn('always()', job.get('if', ''), name)

    def test_tag_verification_accepts_annotated_and_lightweight_tags_and_rejects_other_commits(self):
        with tempfile.TemporaryDirectory() as directory:
            def git(*arguments):
                return subprocess.run(['git', *arguments], cwd=directory, check=True,
                                      capture_output=True, text=True).stdout.strip()

            git('init', '--quiet')
            git('-c', 'user.name=Source policy test', '-c', 'user.email=test@example.invalid',
                'commit', '--quiet', '--allow-empty', '-m', 'event commit')
            event_sha = git('rev-parse', 'HEAD')
            git('tag', '2.3.4')
            git('-c', 'user.name=Source policy test', '-c', 'user.email=test@example.invalid',
                'tag', '-a', '2.3.4-rc.1', '-m', 'annotated tag')
            git('-c', 'user.name=Source policy test', '-c', 'user.email=test@example.invalid',
                'commit', '--quiet', '--allow-empty', '-m', 'different commit')
            git('tag', '9.9.9')
            for tag, expected in (('', 0), ('2.3.4', 0), ('2.3.4-rc.1', 0),
                                  ('9.9.9', 1), ('8.8.8', 1)):
                with self.subTest(tag=tag):
                    result = subprocess.run(['bash', '-c', self.tag_check['run']], cwd=directory,
                                            env=os.environ | {'RELEASE_TAG': tag, 'GITHUB_SHA': event_sha},
                                            capture_output=True, text=True)
                    if expected == 0:
                        self.assertEqual(0, result.returncode, result.stderr)
                    else:
                        self.assertNotEqual(0, result.returncode)
            git('tag', '--force', '2.3.4')
            moved = subprocess.run(['bash', '-c', self.tag_check['run']], cwd=directory,
                                   env=os.environ | {'RELEASE_TAG': '2.3.4', 'GITHUB_SHA': event_sha},
                                   capture_output=True, text=True)
            self.assertNotEqual(0, moved.returncode)
            self.assertIn('Release tag must identify the workflow event commit.', moved.stdout)
            self.assertEqual(git('rev-parse', 'HEAD'), git('rev-parse', '9.9.9'))


if __name__ == '__main__':
    unittest.main()
