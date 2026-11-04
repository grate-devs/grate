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

    def test_windows_analysis_keeps_all_detected_languages_and_its_check_name(self):
        job = self.jobs['analyze']
        self.assertEqual('Analyze Code Security', job['name'])
        self.assertEqual('windows-latest', job['runs-on'])
        init = action_step(job, 'init')
        self.assertIsNotNone(init)
        self.assertNotIn('languages', init.get('with', {}),
                         'Keep language autodetection, including Windows MSI C++')

    def test_csharp_autobuild_remains_between_initialization_and_analysis(self):
        job = self.jobs['analyze']
        init = action_step(job, 'init')
        autobuild = action_step(job, 'autobuild')
        analyze = action_step(job, 'analyze')
        self.assertIsNotNone(init)
        self.assertIsNotNone(autobuild)
        self.assertIsNotNone(analyze)
        self.assertLess(job['steps'].index(init), job['steps'].index(autobuild))
        self.assertLess(job['steps'].index(autobuild), job['steps'].index(analyze))

    def test_real_native_msi_compiler_runs_between_initialization_and_analysis(self):
        job = self.jobs['analyze']
        script = 'installers/msi/native/Build-UpgradeActions.ps1'
        self.assertTrue((ROOT / script).is_file())
        build = next((step for step in job['steps'] if script in step.get('run', '')), None)
        self.assertIsNotNone(build, 'Extract the actual MSI compiler invocation, not portable policy tests')
        self.assertEqual('pwsh', build['shell'])
        self.assertIn('-Architecture x64', build['run'])
        self.assertIn('-OutputDirectory "$env:RUNNER_TEMP/', build['run'])
        init = action_step(job, 'init')
        analyze = action_step(job, 'analyze')
        self.assertIsNotNone(init)
        self.assertIsNotNone(analyze)
        self.assertLess(job['steps'].index(init), job['steps'].index(build))
        self.assertLess(job['steps'].index(build), job['steps'].index(analyze))

    def test_analysis_cannot_silently_skip_or_ignore_compilation_failures(self):
        job = self.jobs['analyze']
        self.assertEqual('write', job['permissions']['security-events'])
        self.assertNotIn('if', job)
        self.assertFalse(job.get('continue-on-error', False))
        for step in job['steps']:
            self.assertNotIn('if', step)
            self.assertFalse(step.get('continue-on-error', False))
            self.assertNotIn('|| true', step.get('run', ''))
        # The invoked helper propagates compiler failures to its PowerShell caller.
        builder = (ROOT / 'installers/msi/native/Build-UpgradeActions.ps1').read_text()
        self.assertIn("$ErrorActionPreference = 'Stop'", builder)
        self.assertIn('if ($LASTEXITCODE -ne 0', builder)


if __name__ == '__main__':
    unittest.main()
