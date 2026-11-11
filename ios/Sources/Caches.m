#import "Bridge.h"
#import "Constants.h"
#import "Utils.h"
#import "Logger.h"
#import <CommonCrypto/CommonDigest.h>

static NSString *hostBundleDigest;
static BOOL hostBundleSeen;

void SetHostBundleCacheSource(NSData *data) {
    NSString *digest = nil;
    if (data.length > 0 && data.length <= UINT32_MAX) {
        unsigned char bytes[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(data.bytes, (CC_LONG)data.length, bytes);
        char hex[CC_SHA256_DIGEST_LENGTH * 2 + 1];
        for (NSUInteger i = 0; i < sizeof(bytes); i++)
            snprintf(hex + i * 2, 3, "%02x", (unsigned int)bytes[i]);
        digest = [NSString stringWithUTF8String:hex];
    }

    @synchronized (bridgeHandlers()) {
        if (!hostBundleSeen) {
            hostBundleSeen = YES;
            hostBundleDigest = digest;
        } else if (![hostBundleDigest isEqualToString:digest]) {
            // A queued write from the previous runtime must never reach another bundle's cache.
            hostBundleDigest = nil;
        }
    }
}

static NSURL *CacheFile(NSURL *directory, NSString *kind, NSString *version) {
    @synchronized (bridgeHandlers()) {
        if (!hostBundleDigest) return nil;
        NSString *name = [NSString stringWithFormat:@"%@.%@.%@", kind, version, hostBundleDigest];
        return [directory URLByAppendingPathComponent:name];
    }
}

static const int kModulesCacheVersion = 3;
static const int kAssetsCacheVersion = 2;

static NSDictionary *ModulesCacheToMap(NSArray<NSNumber *> *blacklist,
                                       NSDictionary<NSString *, id> *finds) {
    return @{@"blacklist": blacklist, @"finds": finds, @"version": @(kModulesCacheVersion)};
}

static BOOL ModulesCacheSaveToFile(NSURL *file,
                                   NSArray<NSNumber *> *blacklist,
                                   NSDictionary<NSString *, id> *finds) {
    NSMutableData *out = DataOutputBuffer();
    DataOutputWriteInt(out, kModulesCacheVersion);

    DataOutputWriteInt(out, (int)blacklist.count);
    for (NSNumber *num in blacklist) DataOutputWriteInt(out, num.intValue);

    DataOutputWriteInt(out, (int)finds.count);
    for (NSString *filter in finds) {
        DataOutputWriteUTF(out, filter);
        id matches = finds[filter];
        if (matches == [NSNull null] || !matches) {
            DataOutputWriteBoolean(out, NO);
        } else {
            DataOutputWriteBoolean(out, YES);
            DataOutputWriteInt(out, (int)[matches count]);
            for (NSString *id in matches) {
                DataOutputWriteInt(out, [id intValue]);
                DataOutputWriteInt(out, [matches[id] intValue]);
            }
        }
    }
    [out writeToFile:file.path atomically:YES];
    return YES;
}

static NSDictionary *ModulesCacheLoadFromFileOrNull(NSURL *file) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attrs = [fm attributesOfItemAtPath:file.path error:nil];
    if (!attrs || [attrs[NSFileSize] longLongValue] <= 0) return nil;

    NSData *data = [NSData dataWithContentsOfFile:file.path];
    if (!data) return nil;

    @try {
        NSUInteger offset = 0;
        const int version = DataInputReadInt(data, &offset);
        if (version != kModulesCacheVersion) {
            ValencedLog(@"Modules cache version mismatch: expected %d, but got version: %d", kModulesCacheVersion, version);
            [fm removeItemAtPath:file.path error:nil];
            return nil;
        }

        int blacklistSize = DataInputReadCount(data, &offset, 4);
        NSMutableArray<NSNumber *> *blacklist = [NSMutableArray arrayWithCapacity:(NSUInteger)blacklistSize];
        for (int i = 0; i < blacklistSize; i++) {
            [blacklist addObject:@(DataInputReadInt(data, &offset))];
        }

        int findsSize = DataInputReadCount(data, &offset, 3);
        NSMutableDictionary<NSString *, id> *finds = [NSMutableDictionary dictionary];
        for (int i = 0; i < findsSize; i++) {
            NSString *filter = DataInputReadUTF(data, &offset);
            BOOL hasMatches = DataInputReadBoolean(data, &offset);
            if (!hasMatches) {
                finds[filter] = [NSNull null];
                continue;
            }
            int mapSize = DataInputReadCount(data, &offset, 8);
            NSMutableDictionary<NSString *, NSNumber *> *matches = [NSMutableDictionary dictionary];
            for (int j = 0; j < mapSize; j++) {
                int id = DataInputReadInt(data, &offset);
                int flag = DataInputReadInt(data, &offset);
                matches[[NSString stringWithFormat:@"%d", id]] = @(flag);
            }
            finds[filter] = matches;
        }
        if (offset != data.length) [NSException raise:NSInvalidArgumentException format:@"Trailing cache data"];
        return ModulesCacheToMap(blacklist, finds);
    } @catch (NSException *exception) {
        ValencedLog(@"Modules cache corrupt: %@", exception.reason);
        [fm removeItemAtPath:file.path error:nil];
        return nil;
    }
}

static NSDictionary *AssetsCacheToMap(NSDictionary<NSString *, NSDictionary *> *data) {
    return @{@"data": data, @"version": @(kAssetsCacheVersion)};
}

static BOOL AssetsCacheSaveToFile(NSURL *file, NSDictionary<NSString *, NSDictionary *> *data) {
    NSMutableData *out = DataOutputBuffer();
    DataOutputWriteInt(out, kAssetsCacheVersion);
    DataOutputWriteInt(out, (int)data.count);
    for (NSString *name in data) {
        DataOutputWriteUTF(out, name);
        NSDictionary *mappings = data[name];
        DataOutputWriteInt(out, (int)mappings.count);
        for (NSString *type in mappings) {
            DataOutputWriteUTF(out, type);
            DataOutputWriteInt(out, [mappings[type] intValue]);
        }
    }
    [out writeToFile:file.path atomically:YES];
    return YES;
}

static NSDictionary *AssetsCacheLoadFromFileOrNull(NSURL *file) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attrs = [fm attributesOfItemAtPath:file.path error:nil];
    if (!attrs || [attrs[NSFileSize] longLongValue] <= 0) return nil;

    NSData *data = [NSData dataWithContentsOfFile:file.path];
    if (!data) return nil;

    @try {
        NSUInteger offset = 0;
        const int version = DataInputReadInt(data, &offset);
        if (version != kAssetsCacheVersion) {
            ValencedLog(@"Assets cache version mismatch: expected %d, but got version: %d", kAssetsCacheVersion, version);
            [fm removeItemAtPath:file.path error:nil];
            return nil;
        }

        int dataSize = DataInputReadCount(data, &offset, 6);
        NSMutableDictionary<NSString *, NSDictionary *> *parsed = [NSMutableDictionary dictionary];
        for (int i = 0; i < dataSize; i++) {
            NSString *name = DataInputReadUTF(data, &offset);
            int mappingsSize = DataInputReadCount(data, &offset, 6);
            NSMutableDictionary<NSString *, NSNumber *> *mappings = [NSMutableDictionary dictionary];
            for (int j = 0; j < mappingsSize; j++) {
                NSString *type = DataInputReadUTF(data, &offset);
                double id = DataInputReadInt(data, &offset);
                mappings[type] = @(id);
            }
            parsed[name] = mappings;
        }
        if (offset != data.length) [NSException raise:NSInvalidArgumentException format:@"Trailing cache data"];
        return AssetsCacheToMap(parsed);
    } @catch (NSException *exception) {
        ValencedLog(@"Assets cache corrupt: %@", exception.reason);
        [fm removeItemAtPath:file.path error:nil];
        return nil;
    }
}

void RegisterCachesMethods(void) {
    NSString *versionTag = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"unknown";

    NSURL *valencedCacheDir = [getValencedDirectory() URLByAppendingPathComponent:CACHE_DIR];
    [[NSFileManager defaultManager] createDirectoryAtURL:valencedCacheDir
                             withIntermediateDirectories:YES attributes:nil error:nil];
    bridgeHandlers()[@"valenced.caches.modules.read"] = ^NSDictionary *(NSArray *args) {
        NSURL *file = CacheFile(valencedCacheDir, @"modules", versionTag);
        NSDictionary *cache = file ? ModulesCacheLoadFromFileOrNull(file) : nil;
        return @{@"result": cache ?: [NSNull null]};
    };

    bridgeHandlers()[@"valenced.caches.modules.write"] = ^NSDictionary *(NSArray *args) {
        NSArray<NSNumber *> *blacklist = args.count > 0 ? args[0] : nil;
        NSDictionary<NSString *, id> *finds = args.count > 1 ? args[1] : nil;
        if (![blacklist isKindOfClass:[NSArray class]]) return @{@"error": @"Expected a blacklist argument"};
        if (![finds isKindOfClass:[NSDictionary class]]) return @{@"error": @"Expected a finds argument"};

        NSURL *modulesCacheFile = CacheFile(valencedCacheDir, @"modules", versionTag);
        if (!modulesCacheFile) return @{@"result": [NSNull null]};
        ModulesCacheSaveToFile(modulesCacheFile, blacklist, finds);
        ValencedLog(@"Modules cache saved: %@ (blacklisted: %lu, finds: %lu)",
                    modulesCacheFile.path, (unsigned long)blacklist.count, (unsigned long)finds.count);
        return @{@"result": [NSNull null]};
    };

    bridgeHandlers()[@"valenced.caches.assets.read"] = ^NSDictionary *(NSArray *args) {
        NSURL *file = CacheFile(valencedCacheDir, @"assets", versionTag);
        NSDictionary *cache = file ? AssetsCacheLoadFromFileOrNull(file) : nil;
        return @{@"result": cache ?: [NSNull null]};
    };

    bridgeHandlers()[@"valenced.caches.assets.write"] = ^NSDictionary *(NSArray *args) {
        NSDictionary *data = args.firstObject;
        if (![data isKindOfClass:[NSDictionary class]]) return @{@"error": @"Expected a data argument"};

        NSURL *assetsCacheFile = CacheFile(valencedCacheDir, @"assets", versionTag);
        if (!assetsCacheFile) return @{@"result": [NSNull null]};
        AssetsCacheSaveToFile(assetsCacheFile, data);
        ValencedLog(@"Assets cache saved: %@ (count: %lu)", assetsCacheFile.path, (unsigned long)data.count);
        return @{@"result": [NSNull null]};
    };
}
