import importlib.util
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

spec = importlib.util.spec_from_file_location('preindexed_server', Path(__file__).with_name('server.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class StaticSourcePaths(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve() / 'source'
        self.assets = Path(self.temp.name).resolve() / 'assets'
        self.root.mkdir()
        self.assets.mkdir()
        self.handler = module.Handler.__new__(module.Handler)
        self.handler.server = SimpleNamespace(root=self.root, assets=self.assets)

    def test_both_index_formats_are_served_without_rewriting(self):
        for filename in ('source.msix', 'source2.msix'):
            self.assertEqual(str(self.root / filename), self.handler.translate_path('/' + filename))

    def test_v2_package_version_data_keeps_its_nested_relative_path(self):
        path = '/packages/g/grate-devs.grate/123456/version.zip'
        self.assertEqual(str(self.root / path.lstrip('/')), self.handler.translate_path(path))

    def test_payload_remains_in_original_asset_directory(self):
        self.assertEqual(str(self.assets / 'grate-2.1.7.msi'), self.handler.translate_path('/assets/grate-2.1.7.msi'))

    def test_traversal_and_windows_drive_paths_are_rejected(self):
        for path in ('/../secret.pem', '/%2e%2e/secret.pem', '/assets/../secret.pem',
                     '/assets/subdir/payload.msi', '/C:/secret.pem', '/..%5csecret.pem', '/x%00y'):
            with self.subTest(path=path):
                self.assertEqual(str(self.root / '__invalid__'), self.handler.translate_path(path))

    def test_asset_symlink_cannot_expose_outside_file(self):
        external = Path(self.temp.name) / 'secret.pem'
        external.write_text('test-only secret')
        try:
            (self.assets / 'grate.msi').symlink_to(external)
        except OSError:
            self.skipTest('Symlink creation unavailable on this host')
        self.assertEqual(str(self.root / '__invalid__'), self.handler.translate_path('/assets/grate.msi'))


if __name__ == '__main__':
    unittest.main()
