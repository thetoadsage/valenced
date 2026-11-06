"""Read the paired JavaScript bundle and manifest from an iOS package."""

import argparse
import io
import json
from pathlib import Path, PurePosixPath
import subprocess
import tarfile


def shipped_files(package):
    members = subprocess.check_output(['ar', '-t', str(package)], text=True).splitlines()
    data = [name.rstrip('/') for name in members if name.startswith('data.tar')]
    if len(data) != 1:
        raise ValueError('Expected one DEB data archive')
    archive = subprocess.check_output(['ar', '-p', str(package), data[0]])
    result = {}
    with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
        for name in ('valenced.bundle', 'valenced.manifest.json'):
            matches = [m for m in tar.getmembers() if m.isfile() and
                       PurePosixPath(m.name).name == name]
            if len(matches) != 1:
                raise ValueError('Expected one shipped ' + name)
            result[name] = tar.extractfile(matches[0]).read()
    manifest = json.loads(result['valenced.manifest.json'])
    if manifest.get('format') != 1 or not manifest.get('version') or not manifest.get('plugins'):
        raise ValueError('Invalid shipped bundle manifest')
    return result


def copy_manifest(package, app):
    files = shipped_files(package)
    if (app / 'valenced.bundle').read_bytes() != files['valenced.bundle']:
        raise ValueError('Injected bundle does not match the manifest package')
    (app / 'valenced.manifest.json').write_bytes(files['valenced.manifest.json'])


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('package', type=Path)
    parser.add_argument('app', type=Path)
    args = parser.parse_args()
    copy_manifest(args.package, args.app)
