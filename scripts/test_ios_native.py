"""Run iOS Foundation regressions on macOS without a Discord binary."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def section(path, start, end=None):
    source = (ROOT / path).read_text()
    first = source.index(start)
    return source[first:source.index(end, first) if end else None]


@unittest.skipUnless(sys.platform == 'darwin', 'requires macOS Foundation and Xcode')
class IOSNativeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='valenced-native-tests-')
        cls.addClassCleanup(cls.temp.cleanup)
        directory = Path(cls.temp.name)
        sources = {
            'utils.inc': section('ios/Sources/Utils.m', 'NSMutableData *DataOutputBuffer'),
            'caches.inc': section('ios/Sources/Caches.m', 'static const int', 'void RegisterCachesMethods'),
            'install.inc': section('ios/Sources/Plugins/PluginLoader.mm', '- (nullable NSURL *)applyStagedDirectory:', '- (void)installFromFile:'),
            'themes-header.inc': (ROOT / 'ios/Headers/Themes.h').read_text().replace('#import <UIKit/UIKit.h>', ''),
            'themes-state.inc': section('ios/Sources/Themes/ThemesState.mm', 'NS_ASSUME_NONNULL_BEGIN'),
            'themes-boot.inc': section('ios/Sources/Themes/ThemesBridge.mm', 'static BOOL themePluginEnabled', 'NS_ASSUME_NONNULL_END'),
            'fs-queue.inc': section('ios/Sources/Utils.m', 'static const char *const kFsQueueKey', 'NSMutableData *DataOutputBuffer'),
            'bridge-dispatch.inc': section('ios/Sources/Bridge.mm', 'static void dispatchOnJsThread', 'void EmitJSEventArgs'),
            'bridge-calls.inc': section('ios/Sources/Bridge.mm', 'NSDictionary *callBridgeMethodHelper', 'void injectPreBundle'),
        }
        for name, source in sources.items():
            (directory / name).write_text(source)
        cls.binaries = {}
        for name, suffix in [('foundation', 'm'), ('bridge', 'mm')]:
            binary = directory / name
            command = ['xcrun', 'clang++' if suffix == 'mm' else 'clang',
                       '-fobjc-arc', '-fblocks', '-Wno-incompatible-pointer-types',
                       '-Wno-incomplete-implementation', '-framework', 'Foundation',
                       '-I' + str(directory), '-I' + str(ROOT / 'ios/Headers')]
            if suffix == 'mm':
                command += ['-std=c++17']
            command += [str(ROOT / f'scripts/tests/ios_{name}.{suffix}'), '-o', str(binary)]
            result = subprocess.run(command, capture_output=True, text=True)
            if result.returncode:
                raise AssertionError(result.stdout + result.stderr)
            cls.binaries[name] = binary

    def run_case(self, binary, case):
        result = subprocess.run([self.binaries[binary], case], capture_output=True,
                                text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_cache_round_trip(self):
        self.run_case('foundation', 'cache-round-trip')

    def test_truncated_caches(self):
        self.run_case('foundation', 'cache-truncated')

    def test_invalid_cache_counts_and_values(self):
        self.run_case('foundation', 'cache-invalid')

    def test_install_new_and_replace(self):
        self.run_case('foundation', 'install-success')

    def test_install_failure_preserves_both_copies(self):
        self.run_case('foundation', 'install-failure')

    def test_theme_recovery_preserves_saved_selection(self):
        self.run_case('foundation', 'theme-recovery')

    def test_disabled_theme_providers(self):
        self.run_case('foundation', 'theme-disabled')

    def test_async_bridge_returns_before_native_work_finishes(self):
        self.run_case('bridge', 'async')

    def test_bridge_drops_completion_for_destroyed_instance(self):
        self.run_case('bridge', 'destroyed')

    def test_bridge_error_envelopes(self):
        self.run_case('bridge', 'errors')


if __name__ == '__main__':
    unittest.main()
