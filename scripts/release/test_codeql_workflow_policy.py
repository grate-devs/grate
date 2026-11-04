"""Keep every CodeQL language on a runner that can extract its real source."""
from pathlib import Path
import unittest

import yaml


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / '.github/workflows/ci.yml'


def action_step(job, action):
    return next((step for step in job.get('steps', [])
                 if step.get('uses', '').startswith(f'github/codeql-action/{action}@')), None)


class CodeqlWorkflowPolicyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.jobs = yaml.safe_load(WORKFLOW.read_text())['jobs']

    def test_linux_analysis_keeps_actions_csharp_and_python_without_windows_cpp(self):
        job = self.jobs['analyze']
        self.assertEqual('Analyze Code Security', job['name'])
        self.assertEqual('ubuntu-latest', job['runs-on'])
        init = action_step(job, 'init')
        self.assertIsNotNone(init)
        languages = {language.strip() for language in init.get('with', {}).get('languages', '').split(',')}
        self.assertEqual({'actions', 'csharp', 'python'}, languages)
        autobuild = action_step(job, 'autobuild')
        analyze = action_step(job, 'analyze')
        self.assertIsNotNone(autobuild)
        self.assertIsNotNone(analyze)
        self.assertLess(job['steps'].index(init), job['steps'].index(autobuild))
        self.assertLess(job['steps'].index(autobuild), job['steps'].index(analyze))

    def native_job(self):
        job = self.jobs.get('analyze-native')
        self.assertIsNotNone(job, 'Windows MSI C++ must have its own CodeQL analysis')
        return job

    def test_native_analysis_uses_windows_and_manual_cpp_extraction(self):
        job = self.native_job()
        self.assertEqual('windows-latest', job['runs-on'])
        init = action_step(job, 'init')
        self.assertIsNotNone(init)
        self.assertEqual('c-cpp', init['with']['languages'])
        self.assertEqual('manual', init['with']['build-mode'])
        self.assertIsNone(action_step(job, 'autobuild'))

    def test_native_analysis_builds_both_real_msi_variants_before_analyzing(self):
        job = self.native_job()
        script = 'installers/msi/native/Build-UpgradeActions.ps1'
        self.assertTrue((ROOT / script).is_file())
        build = next((step for step in job['steps'] if script in step.get('run', '')), None)
        self.assertIsNotNone(build, 'Extract the actual MSI compiler invocation, not portable policy tests')
        self.assertEqual('pwsh', build['shell'])
        self.assertIn("foreach ($architecture in @('x64', 'arm64'))", build['run'])
        self.assertIn('-Architecture $architecture', build['run'])
        self.assertIn('-OutputDirectory (Join-Path $env:RUNNER_TEMP "codeql-native-$architecture")', build['run'])
        init = action_step(job, 'init')
        analyze = action_step(job, 'analyze')
        self.assertIsNotNone(analyze)
        self.assertLess(job['steps'].index(init), job['steps'].index(build))
        self.assertLess(job['steps'].index(build), job['steps'].index(analyze))

    def test_analysis_cannot_silently_skip_or_ignore_compilation_failures(self):
        for name, job in (('analyze', self.jobs['analyze']), ('analyze-native', self.native_job())):
            with self.subTest(job=name):
                self.assertEqual('write', job['permissions']['security-events'])
                self.assertNotIn('if', job)
                self.assertFalse(job.get('continue-on-error', False))
                for step in job['steps']:
                    self.assertNotIn('if', step)
                    self.assertFalse(step.get('continue-on-error', False))
                    self.assertNotIn('|| true', step.get('run', ''))
        build = next(step for step in self.native_job()['steps'] if 'run' in step)
        self.assertIn("$ErrorActionPreference = 'Stop'", build['run'])


if __name__ == '__main__':
    unittest.main()
