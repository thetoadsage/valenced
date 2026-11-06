#import <Foundation/Foundation.h>
#include <stdio.h>
#include <errno.h>
#import "Plugins/PluginStates.h"
#define ValencedLog(...) ((void)0)

#include "utils.inc"
#include "caches.inc"

static BOOL failRename;
static int testRename(const char *from, const char *to, unsigned int flags) {
    if (failRename) { errno = ENOSPC; return -1; }
    return renamex_np(from, to, flags);
}
#define renamex_np testRename
@interface TestLoader : NSObject
@property NSURL *root;
- (NSURL *)pluginsDirectory;
@end
@implementation TestLoader
- (NSURL *)pluginsDirectory { return self.root; }
#include "install.inc"
@end
#undef renamex_np

static NSURL *testRoot;
static NSURL *getValencedDirectory(void) { return testRoot; }
static NSString *const PLUGIN_STORAGE_DIR = @"plugins";
#include "themes-header.inc"
#include "themes-state.inc"

static BOOL defaultsOnly;
static NSDictionary<NSString *, NSNumber *> *pluginFlags;
@implementation PluginsStates
- (BOOL)hasPlugin:(NSString *)pluginId { return pluginFlags[pluginId] != nil; }
- (BOOL)isPluginEnabled:(NSString *)pluginId { return [pluginFlags[pluginId] boolValue]; }
@end
@implementation PluginStatesStore
+ (instancetype)sharedStore {
    static PluginStatesStore *store;
    if (!store) store = [self new];
    return store;
}
- (PluginsStates *)ensureLoaded { return [PluginsStates new]; }
- (BOOL)defaultsOnly { return defaultsOnly; }
@end
static VTHColorsSelection *appliedColors;
static VTHFontsSelection *appliedFonts;
static VTHEmojiSelection *appliedEmoji;
@implementation VTHColorApplier
+ (instancetype)sharedApplier { return [self new]; }
- (void)apply:(VTHColorsSelection *)selection { appliedColors = selection; }
@end
@implementation VTHFontApplier
+ (instancetype)sharedApplier { return [self new]; }
- (void)apply:(VTHFontsSelection *)selection { appliedFonts = selection; }
@end
@implementation VTHEmojiApplier
+ (instancetype)sharedApplier { return [self new]; }
- (void)apply:(VTHEmojiSelection *)selection { appliedEmoji = selection; }
@end
#include "themes-boot.inc"

static NSURL *file(NSString *name) { return [testRoot URLByAppendingPathComponent:name]; }
static NSDictionary *moduleFixture(void) {
    return ModulesCacheToMap(@[@4, @27], @{@"filter": @{@"12": @1}, @"missing": NSNull.null,
                                          @"emoji-🍄": @{}});
}
static void writeCaches(void) {
    NSDictionary *expected = moduleFixture();
    NSCAssert(ModulesCacheSaveToFile(file(@"modules"), expected[@"blacklist"], expected[@"finds"]), @"write modules");
    NSCAssert(AssetsCacheSaveToFile(file(@"assets"), @{@"asset-🍄": @{@"png": @17}}), @"write assets");
}
static void cacheRoundTrip(void) {
    writeCaches();
    NSCAssert([ModulesCacheLoadFromFileOrNull(file(@"modules")) isEqual:moduleFixture()], @"module round trip");
    NSCAssert(([AssetsCacheLoadFromFileOrNull(file(@"assets")) isEqual:AssetsCacheToMap(@{@"asset-🍄": @{@"png": @17}})]), @"asset round trip");
    ModulesCacheSaveToFile(file(@"modules"), @[], @{});
    AssetsCacheSaveToFile(file(@"assets"), @{});
    NSCAssert(ModulesCacheLoadFromFileOrNull(file(@"modules")) != nil, @"empty module cache");
    NSCAssert(AssetsCacheLoadFromFileOrNull(file(@"assets")) != nil, @"empty asset cache");
}
static void expectCorrupt(NSString *name, NSData *data) {
    [data writeToURL:file(name) atomically:YES];
    id result = [name isEqual:@"modules"] ? ModulesCacheLoadFromFileOrNull(file(name)) : AssetsCacheLoadFromFileOrNull(file(name));
    NSCAssert(result == nil, @"corrupt cache accepted");
    NSCAssert(![NSFileManager.defaultManager fileExistsAtPath:file(name).path], @"corrupt cache not discarded");
}
static void cacheTruncated(void) {
    writeCaches();
    for (NSString *name in @[@"modules", @"assets"]) {
        NSData *data = [NSData dataWithContentsOfURL:file(name)];
        for (NSUInteger length = 1; length < data.length; length++)
            expectCorrupt(name, [data subdataWithRange:NSMakeRange(0, length)]);
    }
}
static void cacheInvalid(void) {
    for (NSString *name in @[@"modules", @"assets"]) {
        int version = [name isEqual:@"modules"] ? kModulesCacheVersion : kAssetsCacheVersion;
        for (NSNumber *count in @[@(-1), @(INT_MAX)]) {
            NSMutableData *data = DataOutputBuffer();
            DataOutputWriteInt(data, version);
            DataOutputWriteInt(data, count.intValue);
            expectCorrupt(name, data);
        }
    }
    NSMutableData *data = DataOutputBuffer();
    DataOutputWriteInt(data, kModulesCacheVersion);
    DataOutputWriteInt(data, 0);
    DataOutputWriteInt(data, 1);
    DataOutputWriteUTF(data, @"filter");
    const uint8_t invalid = 2;
    [data appendBytes:&invalid length:1];
    expectCorrupt(@"modules", data);
    data = DataOutputBuffer();
    DataOutputWriteInt(data, kAssetsCacheVersion);
    DataOutputWriteInt(data, 1);
    const uint8_t invalidString[] = {0, 1, 0xFF, 0, 0, 0, 0};
    [data appendBytes:invalidString length:sizeof(invalidString)];
    expectCorrupt(@"assets", data);
    writeCaches();
    for (NSString *name in @[@"modules", @"assets"]) {
        data = [NSMutableData dataWithContentsOfURL:file(name)];
        [data appendBytes:&invalid length:1];
        expectCorrupt(name, data);
    }
}
static NSURL *pluginDir(NSString *name, NSString *contents) {
    NSURL *dir = file(name);
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    [contents writeToURL:[dir URLByAppendingPathComponent:@"index.js"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    return dir;
}
static NSString *pluginContents(NSURL *dir) {
    return [NSString stringWithContentsOfURL:[dir URLByAppendingPathComponent:@"index.js"] encoding:NSUTF8StringEncoding error:nil];
}
static void installSuccess(void) {
    TestLoader *loader = [TestLoader new]; loader.root = testRoot;
    NSError *error = nil;
    NSURL *staged = pluginDir(@".staged", @"v1");
    NSURL *dest = [loader applyStagedDirectory:staged forPluginId:@"example.plugin" error:&error];
    NSCAssert(dest && !error && [pluginContents(dest) isEqual:@"v1"], @"new install failed");
    NSCAssert(![NSFileManager.defaultManager fileExistsAtPath:staged.path], @"staging retained");
    staged = pluginDir(@".staged", @"v2");
    dest = [loader applyStagedDirectory:staged forPluginId:@"example.plugin" error:&error];
    NSCAssert(dest && !error && [pluginContents(dest) isEqual:@"v2"], @"replacement failed");
    NSCAssert(![NSFileManager.defaultManager fileExistsAtPath:staged.path], @"old copy retained after success");
}
static void installFailure(void) {
    TestLoader *loader = [TestLoader new]; loader.root = testRoot;
    NSURL *old = pluginDir(@"example.plugin", @"v1");
    NSURL *staged = pluginDir(@".staged", @"v2");
    NSError *error = nil;
    failRename = YES;
    NSURL *dest = [loader applyStagedDirectory:staged forPluginId:@"example.plugin" error:&error];
    NSCAssert(!dest && error.code == ENOSPC, @"replacement error not reported");
    NSCAssert([pluginContents(old) isEqual:@"v1"], @"old plugin lost");
    NSCAssert([pluginContents(staged) isEqual:@"v2"], @"staged plugin lost");
    error = nil;
    dest = [loader applyStagedDirectory:staged forPluginId:@"new.plugin" error:&error];
    NSCAssert(!dest && error.code == ENOSPC, @"new install error not reported");
    NSCAssert([pluginContents(staged) isEqual:@"v2"], @"new install staging lost");
}
static NSData *savedTheme(void) {
    return [NSData dataWithContentsOfURL:file(@"plugins/valenced.api.themes/state.json")];
}
static void prepareTheme(void) {
    VTHColorsSelection *colors = VTHColorsSelectionOf(@{@"plugin": @"theme.colors"});
    VTHFontsSelection *fonts = VTHFontsSelectionOf(@{@"families": @{
        @"disabled": @{@"plugin": @"theme.disabled", @"variants": @[]},
        @"enabled": @{@"plugin": @"theme.enabled", @"variants": @[]},
    }});
    VTHEmojiSelection *emoji = VTHEmojiSelectionOf(@{@"plugin": @"theme.emoji"});
    [[VTHStateStore sharedStore] update:^VTHThemesState *(VTHThemesState *state) {
        return [[VTHThemesState alloc] initWithFormat:1 colors:colors fonts:fonts icons:nil emoji:emoji];
    }];
}
static void themeRecovery(void) {
    prepareTheme();
    NSData *saved = savedTheme();
    NSCAssert(saved != nil, @"theme fixture missing");
    defaultsOnly = YES;
    ThemesApplyAtBoot();
    NSCAssert(!appliedColors && !appliedFonts && !appliedEmoji, @"recovery applied theme");
    NSCAssert([savedTheme() isEqual:saved], @"recovery changed saved theme");
    defaultsOnly = NO;
    ThemesApplyAtBoot();
    NSCAssert(appliedColors && appliedFonts.sources.count == 2 && appliedEmoji, @"normal boot did not restore theme");
}
static void themeDisabled(void) {
    prepareTheme();
    NSData *saved = savedTheme();
    pluginFlags = @{@"valenced.api.themes": @NO};
    ThemesApplyAtBoot();
    NSCAssert(!appliedColors && !appliedFonts && !appliedEmoji, @"disabled API applied theme");
    pluginFlags = @{@"valenced.api.themes": @YES, @"theme.colors": @NO, @"theme.emoji": @NO,
                    @"theme.disabled": @NO, @"theme.enabled": @YES};
    ThemesApplyAtBoot();
    NSCAssert(!appliedColors && !appliedEmoji, @"disabled provider applied");
    NSCAssert(appliedFonts.sources.count == 1 && appliedFonts.sources[@"enabled"], @"font provider filtering failed");
    NSCAssert([savedTheme() isEqual:saved], @"disabled providers erased saved theme");
}
int main(int argc, const char **argv) { @autoreleasepool {
    testRoot = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtURL:testRoot withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *name = argc > 1 ? @(argv[1]) : @"";
    if ([name isEqual:@"cache-round-trip"]) cacheRoundTrip();
    else if ([name isEqual:@"cache-truncated"]) cacheTruncated();
    else if ([name isEqual:@"cache-invalid"]) cacheInvalid();
    else if ([name isEqual:@"install-success"]) installSuccess();
    else if ([name isEqual:@"install-failure"]) installFailure();
    else if ([name isEqual:@"theme-recovery"]) themeRecovery();
    else if ([name isEqual:@"theme-disabled"]) themeDisabled();
    else return 2;
    [NSFileManager.defaultManager removeItemAtURL:testRoot error:nil];
    printf("PASS %s\n", name.UTF8String);
} return 0; }
