import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('embed_safari', ROOT / 'build/embed-safari-extension.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class SafariPackagingTests(unittest.TestCase):
    def fixture(self, directory):
        app = Path(directory) / 'TicketClient.app'
        (app / 'Contents').mkdir(parents=True)
        info = {'CFBundleIdentifier': 'org.example.ticketclient', 'CFBundleName': 'TicketClient',
                'CFBundleShortVersionString': '2.3.4', 'CFBundleVersion': '56'}
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        resources = Path(directory) / 'web'
        resources.mkdir()
        manifest = {'manifest_version': 3, 'name': 'Ticket Links', 'version': '1.2.3',
                    'key': 'chromium-key', 'update_url': 'https://example.invalid/update.xml'}
        (resources / 'manifest.json').write_text(json.dumps(manifest))
        (resources / 'content.js').write_text('globalThis.ticketLinksReady = true;\n')
        return app, resources

    def test_embedded_extension_has_universal_executable_and_host_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            app, resources = self.fixture(directory)
            extension = module.embed(app, resources)
            self.assertEqual(extension, app / 'Contents/PlugIns/TicketLinks.appex')
            info = plistlib.loads((extension / 'Contents/Info.plist').read_bytes())
            self.assertEqual(info['CFBundleIdentifier'], 'org.example.ticketclient.SafariExtension')
            self.assertEqual(info['CFBundleShortVersionString'], '2.3.4')
            self.assertEqual(info['CFBundleVersion'], '56')
            self.assertEqual(info['NSExtension']['NSExtensionPointIdentifier'], 'com.apple.Safari.web-extension')
            executable = extension / 'Contents/MacOS/TicketLinks'
            architectures = subprocess.check_output(['xcrun', 'lipo', '-archs', str(executable)], text=True)
            self.assertEqual(set(architectures.split()), {'arm64', 'x86_64'})
            header = subprocess.check_output(['otool', '-hv', str(executable)], text=True)
            self.assertIn('EXECUTE', header)
            manifest = json.loads((extension / 'Contents/Resources/manifest.json').read_text())
            self.assertNotIn('key', manifest)
            self.assertNotIn('update_url', manifest)
            self.assertEqual((extension / 'Contents/Resources/content.js').read_bytes(),
                             (resources / 'content.js').read_bytes())
            self.assertEqual(list(Path(directory).glob('*.app')), [app])

    def test_invalid_manifest_does_not_create_a_partial_extension(self):
        with tempfile.TemporaryDirectory() as directory:
            app, resources = self.fixture(directory)
            (resources / 'manifest.json').write_text('{"manifest_version": 2}')
            with self.assertRaisesRegex(ValueError, 'Manifest V3'):
                module.embed(app, resources)
            self.assertFalse((app / 'Contents/PlugIns').exists())

    def test_resources_cannot_escape_through_a_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            app, resources = self.fixture(directory)
            (resources / 'outside').symlink_to(app / 'Contents/Info.plist')
            with self.assertRaisesRegex(ValueError, 'symbolic links'):
                module.embed(app, resources)


if __name__ == '__main__':
    unittest.main()
