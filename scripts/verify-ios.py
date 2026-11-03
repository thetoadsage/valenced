#!/usr/bin/env python3
"""Check a clean Discord IPA, or compare a Valenced IPA against its input.

These are packaging/ABI checks. They do not substitute for an iPhone launch test.
"""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import struct
import subprocess
import tempfile
import zipfile

HERMES_MAGIC = bytes.fromhex('c61fbc03c103191f')
MACH_MAGIC = (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf')
FAT_MAGIC = (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf')
DYLIB_COMMANDS = {0xC, 0x80000018, 0x8000001F, 0x80000023}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def macho(data):
    """Read arm64 load commands without executing the image."""
    if data[:4] in FAT_MAGIC:
        is64 = data[:4] == FAT_MAGIC[1]
        count = struct.unpack_from('>I', data, 4)[0]
        for i in range(count):
            offset = 8 + i * (32 if is64 else 20)
            cpu = struct.unpack_from('>I', data, offset)[0]
            if cpu == 0x100000C:
                start, size = struct.unpack_from('>QQ' if is64 else '>II', data, offset + 8)
                return macho(data[start:start + size])
        raise ValueError('Mach-O has no arm64 slice')
    require(data[:4] in MACH_MAGIC, 'Expected a 64-bit Mach-O')
    endian = '<' if data[:4] == MACH_MAGIC[0] else '>'
    cpu, = struct.unpack_from(endian + 'I', data, 4)
    require(cpu == 0x100000C, 'Expected arm64 Mach-O')
    ncmds, sizeofcmds = struct.unpack_from(endian + 'II', data, 16)
    require(32 + sizeofcmds <= len(data), 'Truncated Mach-O load commands')
    result = {'cryptids': [], 'dependencies': [], 'rpaths': []}
    offset = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from(endian + 'II', data, offset)
        require(size >= 8 and offset + size <= 32 + sizeofcmds, 'Invalid Mach-O command')
        if cmd in (0x21, 0x2C):
            result['cryptids'].append(struct.unpack_from(endian + 'I', data, offset + 16)[0])
        if cmd in DYLIB_COMMANDS or cmd == 0x8000001C:
            start = struct.unpack_from(endian + 'I', data, offset + 8)[0]
            value = data[offset + start:offset + size].split(b'\0')[0].decode()
            result['rpaths' if cmd == 0x8000001C else 'dependencies'].append(value)
        offset += size
    return result


def hermes_version(data):
    require(data[:8] == HERMES_MAGIC, 'Expected Hermes bytecode')
    return struct.unpack_from('<I', data, 8)[0]


def inspect(path):
    with zipfile.ZipFile(path) as z:
        require(z.testzip() is None, 'Corrupt ZIP member')
        names = z.namelist()
        require(len(names) == len(set(names)), 'Duplicate ZIP paths')
        for name in names:
            p = PurePosixPath(name)
            require(not p.is_absolute() and '..' not in p.parts and '\\' not in name,
                    'Unsafe archive path')
        roots = [n[:-10] for n in names if n.startswith('Payload/') and
                 n.count('/') == 2 and n.endswith('/Info.plist')]
        require(len(roots) == 1, 'Expected one top-level app')
        root = roots[0]
        info = plistlib.loads(z.read(root + 'Info.plist'))
        require(info['CFBundleIdentifier'] == 'com.hammerandchisel.discord', 'Not original Discord bundle ID')
        executable = root + info['CFBundleExecutable']
        binary = z.read(executable)
        main = macho(binary)
        require(not any(main['cryptids']), 'Discord executable is encrypted')
        require(b'RCTHost\0' in binary and b'instance:didInitializeRuntime:\0' in binary,
                'Required React Native RCTHost runtime hook not found')
        images = {}
        for n in names:
            if n.endswith('/') or not n.startswith(root):
                continue
            with z.open(n) as f:
                magic = f.read(4)
            if magic in MACH_MAGIC + FAT_MAGIC:
                images[n] = macho(z.read(n))
        # Encrypted extensions can be dropped by cyan; encrypted frameworks cannot.
        encrypted = [n for n, image in images.items() if any(image['cryptids'])]
        require(all('/PlugIns/' in n for n in encrypted), 'Encrypted app framework found')
        version = hermes_version(z.read(root + 'main.jsbundle'))
        return {'path': str(path), 'sha256': sha(Path(path).read_bytes()), 'root': root,
                'executable': executable, 'discord_version': info['CFBundleShortVersionString'],
                'discord_build': info['CFBundleVersion'], 'minimum_ios': info['MinimumOSVersion'],
                'hermes_bytecode_version': version, 'main': main, 'images': images,
                'encrypted_extensions': encrypted}


def symbols(data, options):
    with tempfile.NamedTemporaryFile() as f:
        f.write(data)
        f.flush()
        return set(subprocess.check_output(['nm', options, f.name], text=True).splitlines())


def verify(source, output):
    before, after = inspect(source), inspect(output)
    root = after['root']
    require(not after['encrypted_extensions'], 'Output still contains encrypted extensions')
    require(before['discord_version'] == after['discord_version'] and
            before['discord_build'] == after['discord_build'], 'Discord version was modified')
    tweak = root + 'Frameworks/ValencedTweak.dylib'
    bundle = root + 'valenced.bundle'
    substrate = root + 'Frameworks/CydiaSubstrate.framework/CydiaSubstrate'
    with zipfile.ZipFile(source) as src, zipfile.ZipFile(output) as dst:
        require(tweak not in src.namelist(), 'Input was already modified with Valenced')
        for name in (tweak, bundle, substrate):
            require(name in dst.namelist(), 'Missing injected file: ' + name)
        require('@rpath/ValencedTweak.dylib' in after['main']['dependencies'],
                'Discord does not load ValencedTweak')
        require('@executable_path/Frameworks' in after['main']['rpaths'], 'Missing Frameworks rpath')
        deps = after['images'][tweak]['dependencies']
        require('@rpath/CydiaSubstrate.framework/CydiaSubstrate' in deps, 'Hook framework dependency not relocated')
        require(not any('/var/jb/' in d or '/Library/MobileSubstrate/' in d or 'ValencedCore.framework' in d
                        for d in deps), 'External jailbreak or ValencedCore runtime dependency')
        require(hermes_version(dst.read(bundle)) == before['hermes_bytecode_version'],
                'Valenced and Discord Hermes bytecode versions differ')
        # The Kotlin core is linked statically; its C bridge must be defined in the tweak.
        defined = symbols(dst.read(tweak), '-gUj')
        require('_ValencedCore_FreeString' in defined, 'Static Kotlin core is missing')
        undefined = symbols(dst.read(tweak), '-uj')
        jsi = {s for s in undefined if 'facebook3jsi' in s}
        require(jsi, 'Tweak has no JSI imports')
        available = set()
        for n in before['images']:
            if '/PlugIns/' not in n:
                available.update(symbols(src.read(n), '-gUj'))
        missing = sorted(jsi - available)
        require(not missing, 'Discord does not export required JSI symbols: ' + repr(missing))
        # All original resources and frameworks survive byte-for-byte. Only the app
        # executable/signature and encrypted extension directories may change.
        removed_roots = {n.split('.appex/')[0] + '.appex/' for n in before['encrypted_extensions']}
        preserved = 0
        for name in src.namelist():
            if name.endswith('/') or not name.startswith(before['root']):
                continue
            relative = name[len(before['root']):]
            if name == before['executable'] or '/_CodeSignature/' in name or relative == 'embedded.mobileprovision':
                continue
            if any(name.startswith(prefix) for prefix in removed_roots):
                continue
            target = root + relative
            require(target in dst.namelist(), 'Original file removed: ' + relative)
            require(sha(src.read(name)) == sha(dst.read(target)), 'Original file changed: ' + relative)
            preserved += 1
        after['verification'] = {'on_device_tested': False, 'jsi_imports_resolved': len(jsi),
                                 'original_files_preserved': preserved,
                                 'valenced_bundle_sha256': sha(dst.read(bundle)),
                                 'tweak_sha256': sha(dst.read(tweak)),
                                 'hook_framework_sha256': sha(dst.read(substrate)),
                                 'removed_encrypted_extensions': before['encrypted_extensions']}
    return after


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    result = verify(args.input, args.output) if args.output else inspect(args.input)
    args.report.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k: v for k, v in result.items() if k != 'images'}, indent=2))


if __name__ == '__main__':
    main()
