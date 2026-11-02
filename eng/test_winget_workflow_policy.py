"""Prevent the release workflow from bypassing WinGet's migration boundary."""
from pathlib import Path
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]


class WinGetWorkflowPolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.jobs = yaml.safe_load((ROOT / '.github/workflows/build.yml').read_text())['jobs']

    def test_candidates_require_published_stable_assets_and_same_source(self):
        job = self.jobs['prepare-winget']
        self.assertTrue({'set-version-number', 'release-ready', 'publish-github-release'} <= set(job['needs']))
        self.assertEqual("${{ needs.set-version-number.outputs.is-release == 'true' && needs.set-version-number.outputs.is-prerelease != 'true' }}", job['if'])
        checkout = next(step for step in job['steps'] if step.get('uses', '').startswith('actions/checkout@'))
        self.assertEqual('${{ needs.set-version-number.outputs.checkout-ref }}', checkout['with']['ref'])
        self.assertIs(False, checkout['with']['persist-credentials'])
        run_step = next(step for step in job['steps'] if 'Create-Installer.ps1' in step.get('run', ''))
        self.assertEqual('${{ needs.set-version-number.outputs.semVer }}', run_step['env']['VERSION'])
        self.assertEqual('${{ needs.set-version-number.outputs.release-tag }}', run_step['env']['RELEASE_TAG'])
        self.assertIn('-PrepareMigration', run_step['run'])

    def test_no_automatic_winget_submission_or_publishing_credentials(self):
        self.assertNotIn('publish-winget', self.jobs)
        job = self.jobs['prepare-winget']
        self.assertEqual({'contents': 'read'}, job['permissions'])
        self.assertNotIn('environment', job)
        text = yaml.safe_dump(job)
        self.assertNotRegex(text, r'secrets\.|WINGET_GH_PAT|--submit|\bgh pr create\b')
        self.assertNotRegex(text, r'(?<!\S)-s(?!\S)')
        commands = '\n'.join(step.get('run', '') for step in job['steps'])
        self.assertNotRegex(commands, r'(?i)wingetcreate(?:\.exe)?\s+(?:submit|new)\b')
        self.assertIn('winget-create/releases/download/v1.12.13.0/wingetcreate.exe', commands)
        self.assertIn('24042BD37915805615E6CF969AC57C6439124C3FE85823327F5F3FB24BD9FFEA', commands)
        self.assertIn('validate --manifest', commands)
        self.assertIn('Initialize-LifecycleRunner.ps1', commands)
        self.assertNotIn('--ignore-warnings', commands)
        upload = next(step for step in job['steps'] if step.get('uses', '').startswith('actions/upload-artifact@'))
        self.assertRegex(upload['uses'], r'@[0-9a-f]{40}$')
        self.assertEqual('error', upload['with']['if-no-files-found'])

    def test_both_actual_msi_assets_are_verified_before_release_gate(self):
        job = self.jobs['build-msi']
        self.assertEqual({'win-x64', 'win-arm64'}, set(job['strategy']['matrix']['arch']))
        steps = job['steps']
        check = next(i for i, step in enumerate(steps) if 'Test-InstallerMetadata.Tests.ps1' in step.get('run', ''))
        upload = next(i for i, step in enumerate(steps) if step.get('uses', '').startswith('actions/upload-artifact@'))
        self.assertLess(check, upload)
        self.assertIn('-MsiPath $name', steps[check]['run'])
        self.assertIn('-ExpectedVersion', steps[check]['run'])
        self.assertIn('-ExpectedArchitecture', steps[check]['run'])
        commands = '\n'.join(step.get('run', '') for step in steps)
        for contract in ('Test-CreateInstaller.Tests.ps1', 'Test-InstallerCorrelation.Tests.ps1',
                         'Test-InstallerAuthoring.Tests.ps1', 'Test-InstallerIdentity.Tests.ps1'):
            self.assertIn(contract, commands)
        self.assertIn('build-msi', self.jobs['release-ready']['needs'])
        gate = '\n'.join(step.get('run', '') for step in self.jobs['release-ready']['steps'])
        self.assertIn('.result == "success"', gate)


if __name__ == '__main__':
    unittest.main()
