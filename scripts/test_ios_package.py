import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest

from ios_package import copy_manifest, shipped_files


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.app = self.root / 'Discord.app'
        self.app.mkdir()
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
