import io
import json
from pathlib import Path
import plistlib
import tarfile
import tempfile
import unittest

from ios_package import copy_manifest, enable_file_sharing, shipped_files


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.app = self.root / 'Discord.app'
        self.app.mkdir()
        self.info = {'CFBundleIdentifier': 'com.hammerandchisel.discord',
                     'CFBundleVersion': '120481', 'UnrelatedSetting': {'keep': [1, 'value']}}
        (self.app / 'Info.plist').write_bytes(plistlib.dumps(self.info, fmt=plistlib.FMT_BINARY))
        self.bundle = b'paired bytecode'
        self.manifest = json.dumps({'format': 1, 'version': '1.3.0',
                                    'plugins': [{'id': 'valenced.recovery'}]}).encode()

    def package(self, manifest=True, duplicate=False):
        data = self.root / 'data.tar.gz'
        with tarfile.open(data, 'w:gz') as tar:
            files = {'valenced.bundle': self.bundle}
            if manifest:
                files['valenced.manifest.json'] = self.manifest
            for name, content in files.items():
                entry = tarfile.TarInfo('var/jb/Library/MobileSubstrate/DynamicLibraries/' + name)
                entry.size = len(content)
                tar.addfile(entry, io.BytesIO(content))
                if duplicate and name.endswith('.json'):
                    tar.addfile(entry, io.BytesIO(content))
        (self.root / 'debian-binary').write_text('2.0\n')
        package = self.root / 'test.deb'
        with package.open('wb') as archive:
            archive.write(b'!<arch>\n')
            for name in ('debian-binary', 'data.tar.gz'):
                content = (self.root / name).read_bytes()
                header = f'{name:<16}{0:<12}{0:<6}{0:<6}{"100644":<8}{len(content):<10}`\n'
                archive.write(header.encode() + content + (b'\n' if len(content) % 2 else b''))
        return package

    def test_copies_loose_manifest_from_matching_package(self):
        (self.app / 'valenced.bundle').write_bytes(self.bundle)
        copy_manifest(self.package(), self.app)
        self.assertEqual((self.app / 'valenced.manifest.json').read_bytes(), self.manifest)
        self.assertEqual(plistlib.loads((self.app / 'Info.plist').read_bytes()),
                         {**self.info, 'UIFileSharingEnabled': True,
                          'LSSupportsOpeningDocumentsInPlace': True})

    def test_enables_files_flags_without_other_plist_changes(self):
        for fmt in (plistlib.FMT_BINARY, plistlib.FMT_XML):
            with self.subTest(format=fmt):
                original = {**self.info, 'UIFileSharingEnabled': False,
                            'LSSupportsOpeningDocumentsInPlace': False}
                path = self.app / 'Info.plist'
                path.write_bytes(plistlib.dumps(original, fmt=fmt))
                enable_file_sharing(self.app)
                first = path.read_bytes()
                info = plistlib.loads(first)
                self.assertIs(info.pop('UIFileSharingEnabled'), True)
                self.assertIs(info.pop('LSSupportsOpeningDocumentsInPlace'), True)
                self.assertEqual(info, self.info)
                self.assertEqual(first.startswith(b'bplist00'), fmt == plistlib.FMT_BINARY)
                enable_file_sharing(self.app)
                self.assertEqual(path.read_bytes(), first)

    def test_rejects_stale_injected_bundle(self):
        (self.app / 'valenced.bundle').write_bytes(b'stale')
        with self.assertRaisesRegex(ValueError, 'does not match'):
            copy_manifest(self.package(), self.app)
        self.assertFalse((self.app / 'valenced.manifest.json').exists())

    def test_rejects_missing_manifest(self):
        with self.assertRaisesRegex(ValueError, 'Expected one shipped'):
            shipped_files(self.package(manifest=False))

    def test_rejects_duplicate_manifest(self):
        with self.assertRaisesRegex(ValueError, 'Expected one shipped'):
            shipped_files(self.package(duplicate=True))

    def test_rejects_invalid_manifest(self):
        self.manifest = b'{"format":2}'
        with self.assertRaisesRegex(ValueError, 'Invalid shipped'):
            shipped_files(self.package())


if __name__ == '__main__':
    unittest.main()
