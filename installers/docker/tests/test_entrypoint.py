import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ENTRYPOINT = Path(__file__).resolve().parents[1] / 'entrypoint.sh'


class EntrypointTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='grate entrypoint ')
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        executable = self.root / 'grate'
        executable.write_text(
            f'#!{sys.executable}\nimport json, sys\nprint(json.dumps(sys.argv[1:]))\n',
            encoding='utf-8',
        )
        executable.chmod(0o700)
        self.environment = os.environ.copy()
        for name in ('DATABASE_TYPE', 'VERSION', 'CREATE_DATABASE', 'ENVIRONMENT', 'TRANSACTION'):
            self.environment.pop(name, None)
        self.environment['APP_CONNSTRING'] = 'Data Source=/output/database with spaces.db'

    def invoke(self, *arguments):
        return subprocess.run(
            ['/bin/sh', str(ENTRYPOINT), *arguments], cwd=self.root,
            env=self.environment, capture_output=True, text=True, timeout=10,
        )

    def test_unset_or_empty_database_type_uses_the_compiled_default(self):
        for value in (None, ''):
            with self.subTest(value=value):
                if value is not None:
                    self.environment['DATABASE_TYPE'] = value
                result = self.invoke()
                self.assertEqual(0, result.returncode, result.stderr)
                arguments = json.loads(result.stdout)
                self.assertFalse(any(item.startswith('--databasetype') for item in arguments))
                self.assertIn('--version=1.0.0', arguments)
                self.assertIn('--createdatabase=true', arguments)
                self.assertIn('--environment=LOCAL', arguments)
                self.assertIn('--transaction=false', arguments)

    def test_environment_and_extra_arguments_preserve_values_and_order(self):
        self.environment.update({
            'DATABASE_TYPE': 'sqlite', 'VERSION': 'pilot 1',
            'CREATE_DATABASE': 'false', 'ENVIRONMENT': 'PoC local', 'TRANSACTION': 'true',
        })
        extra = ['--databasetype=mariadb', '--folders', 'up=ddl with spaces']
        result = self.invoke(*extra)
        self.assertEqual(0, result.returncode, result.stderr)
        arguments = json.loads(result.stdout)
        self.assertIn('--connstring=Data Source=/output/database with spaces.db', arguments)
        self.assertIn('--version=pilot 1', arguments)
        self.assertIn('--createdatabase=false', arguments)
        self.assertIn('--environment=PoC local', arguments)
        self.assertIn('--transaction=true', arguments)
        self.assertEqual(['--databasetype=sqlite', *extra], arguments[-4:])

    def test_missing_connection_string_fails_before_launching_grate(self):
        self.environment.pop('APP_CONNSTRING')
        result = self.invoke()
        self.assertNotEqual(0, result.returncode)
        self.assertEqual('', result.stdout)
        self.assertIn('APP_CONNSTRING', result.stderr)


if __name__ == '__main__':
    unittest.main()
