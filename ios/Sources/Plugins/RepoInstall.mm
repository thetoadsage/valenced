#import "Plugins/PluginLoader.h"
#import "Plugins/PluginManifest.h"
#import "Plugins/PluginVersion.h"
#import "Plugins/RepoStore.h"
#import "Plugins/SourcesStore.h"
#import "Bridge.h"
#import "Constants.h"
#import "Utils.h"
#import "Logger.h"
#import "ValencedCoreBridge.h"

static const long long kProgressIntervalMs = 150;

static NSString * const kRepoInstallTmpPrefix = @".repo-install-";

@interface RepoInstallActionEntry : NSObject
@property (nonatomic, copy) NSString *actionId;
@property (nonatomic, strong) PluginVersion *version;
@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy) NSString *sha256;
@property (nonatomic, assign) long long size;
@property (nonatomic, copy) NSString *repo;
@property (nonatomic, copy) NSString *channel;
@end

@implementation RepoInstallActionEntry
@end

static RepoInstallActionEntry *ParseRepoInstallAction(id raw, NSString * _Nullable * _Nullable error) {
    if (![raw isKindOfClass:[NSDictionary class]]) {
        if (error) *error = @"Expected a plan action object";
        return nil;
    }
    NSDictionary *map = raw;
    for (NSString *key in @[@"id", @"version", @"url", @"sha256", @"repo"]) {
        if (![map[key] isKindOfClass:[NSString class]]) {
            if (error) *error = [NSString stringWithFormat:@"Plan action is missing '%@'", key];
            return nil;
        }
    }
    NSNumber *size = map[@"size"];
    if (![size isKindOfClass:[NSNumber class]]) {
        if (error) *error = @"Plan action is missing 'size'";
        return nil;
    }

    NSString *versionError = nil;
    PluginVersion *version = [PluginVersion versionFromString:map[@"version"] error:&versionError];
    if (!version) {
        if (error) *error = versionError ?: @"Invalid version";
        return nil;
    }

    RepoInstallActionEntry *action = [[RepoInstallActionEntry alloc] init];
    action.actionId = map[@"id"];
    action.version = version;
    action.url = map[@"url"];
    action.sha256 = map[@"sha256"];
    action.size = size.longLongValue;
    action.repo = map[@"repo"];
    action.channel = [map[@"channel"] isKindOfClass:[NSString class]] ? map[@"channel"] : REPO_CHANNEL_LATEST;
    return action;
}

typedef void (^ProgressEmit)(long long received);

static ProgressEmit MakeThrottledProgress(RepoInstallActionEntry *action, NSInteger index, NSInteger count) {
    __block long long lastTime = 0;
    __block long long lastBytes = -1;
    long long delta = (action.size / 10) >= 1 ? (action.size / 10) : 1;
    return ^(long long received) {
        long long now = (long long)([[NSDate date] timeIntervalSince1970] * 1000);
        if (received == 0 || received >= action.size ||
            now - lastTime >= kProgressIntervalMs || received - lastBytes >= delta) {
            lastTime = now;
            lastBytes = received;
            EmitJSEvent(EVENT_DOWNLOAD_PROGRESS, @{
                @"id": action.actionId,
                @"version": action.version.stringValue,
                @"repo": action.repo,
                @"received": @(received),
                @"total": @(action.size),
                @"index": @(index),
                @"count": @(count),
            });
        }
    };
}

@interface RepoDownloadDelegate : NSObject <NSURLSessionDataDelegate>
@property (nonatomic, strong) NSMutableData *data;
@property (nonatomic, assign) long long statusCode;
@property (nonatomic, strong, nullable) NSError *error;
@property (nonatomic, copy, nullable) ProgressEmit onReceived;
@property (nonatomic, strong) dispatch_semaphore_t done;
@end

@implementation RepoDownloadDelegate

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        self.statusCode = ((NSHTTPURLResponse *)response).statusCode;
    }
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    [self.data appendData:data];
    if (self.onReceived) self.onReceived((long long)self.data.length);
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    self.error = error;
    dispatch_semaphore_signal(self.done);
}

@end

static NSData *DownloadAndVerify(RepoInstallActionEntry *action, ProgressEmit onReceived,
                                 NSString * _Nullable * _Nullable error) {
    NSURL *url = [NSURL URLWithString:action.url];
    if (!url) {
        if (error) *error = [NSString stringWithFormat:@"Failed to download %@@%@: invalid URL",
                             action.actionId, action.version.stringValue];
        return nil;
    }

    RepoDownloadDelegate *delegate = [[RepoDownloadDelegate alloc] init];
    delegate.data = [NSMutableData data];
    delegate.onReceived = onReceived;
    delegate.done = dispatch_semaphore_create(0);

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.timeoutIntervalForResource = 60;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config delegate:delegate delegateQueue:nil];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalAndRemoteCacheData
                                                       timeoutInterval:60];
    [[session dataTaskWithRequest:request] resume];
    dispatch_semaphore_wait(delegate.done, DISPATCH_TIME_FOREVER);
    [session finishTasksAndInvalidate];

    if (delegate.error) {
        if (error) *error = [NSString stringWithFormat:@"Failed to download %@@%@: %@",
                             action.actionId, action.version.stringValue, delegate.error.localizedDescription ?: @"connection failed"];
        return nil;
    }
    if (delegate.statusCode != 200) {
        if (error) *error = [NSString stringWithFormat:@"Failed to download %@@%@: %lld",
                             action.actionId, action.version.stringValue, delegate.statusCode];
        return nil;
    }

    NSData *bytes = delegate.data;
    if ((long long)bytes.length != action.size) {
        if (error) *error = [NSString stringWithFormat:@"Artifact for %@@%@ is %lu bytes; the plan says %lld",
                             action.actionId, action.version.stringValue, (unsigned long)bytes.length, action.size];
        return nil;
    }
    char *hashError = NULL;
    char *digestRaw = ValencedCore_Sha256Hex((const char *)bytes.bytes,
                                             (unsigned long long)bytes.length, &hashError);
    if (!digestRaw) {
        if (error) *error = [NSString stringWithFormat:@"Artifact digest mismatch for %@@%@: %@",
                             action.actionId, action.version.stringValue, ValencedCore_ConsumeError(hashError)];
        return nil;
    }
    NSString *digest = ValencedCore_ConsumeString(digestRaw);
    if (![digest isEqualToString:action.sha256]) {
        if (error) *error = [NSString stringWithFormat:@"Artifact digest mismatch for %@@%@ (got %@)",
                             action.actionId, action.version.stringValue, digest];
        return nil;
    }
    return bytes;
}

static NSArray *OrderStagedByDependencies(NSArray<NSDictionary *> *staged) {
    NSMutableArray<NSString *> *ids = [NSMutableArray arrayWithCapacity:staged.count];
    NSMutableDictionary<NSString *, NSDictionary *> *byId = [NSMutableDictionary dictionaryWithCapacity:staged.count];
    NSMutableDictionary<NSString *, NSArray<NSString *> *> *dependencies = [NSMutableDictionary dictionaryWithCapacity:staged.count];
    for (NSDictionary *entry in staged) {
        RepoInstallActionEntry *action = entry[@"action"];
        PluginRecord *record = entry[@"record"];
        [ids addObject:action.actionId];
        byId[action.actionId] = entry;
        dependencies[action.actionId] = record.manifest.dependencies.allKeys;
    }

    NSData *requestData = [NSJSONSerialization dataWithJSONObject:@{@"ids": ids, @"dependencies": dependencies}
                                                          options:0
                                                            error:nil];
    if (!requestData) return staged;
    NSString *requestJson = [[NSString alloc] initWithData:requestData encoding:NSUTF8StringEncoding];

    char *orderError = NULL;
    char *orderResultRaw = ValencedCore_OrderPluginsByDependencies(requestJson.UTF8String, &orderError);
    if (!orderResultRaw) {
        ValencedLog(@"Failed to order staged plugins: %@", ValencedCore_ConsumeError(orderError));
        return staged;
    }

    NSData *orderData = [ValencedCore_ConsumeString(orderResultRaw) dataUsingEncoding:NSUTF8StringEncoding];
    NSArray *orderedIds = orderData ? [NSJSONSerialization JSONObjectWithData:orderData options:0 error:nil] : nil;
    if (![orderedIds isKindOfClass:[NSArray class]]) return staged;

    NSMutableArray *ordered = [NSMutableArray arrayWithCapacity:staged.count];
    for (NSString *actionId in orderedIds) {
        NSDictionary *entry = byId[actionId];
        if (entry) [ordered addObject:entry];
    }
    return ordered;
}

static NSURL *ApplyStagedPlugin(PluginLoader *loader, NSString *stagedPath, NSString *pluginId,
                                NSString * _Nullable * _Nullable error) {
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:stagedPath isDirectory:&isDir] || !isDir) {
        if (error) *error = @"Staged plugin directory is missing";
        return nil;
    }
    NSError *applyError = nil;
    NSURL *dest = [loader applyStagedDirectory:[NSURL fileURLWithPath:stagedPath] forPluginId:pluginId error:&applyError];
    if (!dest) {
        if (error) *error = applyError.localizedDescription ?: @"Failed to apply staged plugin";
        return nil;
    }
    return dest;
}

NSDictionary *ExecuteInstallPlan(NSDictionary *plan,
                                 BOOL (^isInstalled)(NSString *pluginId),
                                 BOOL (^isPendingReload)(NSString *pluginId),
                                 void (^setPendingUpdate)(NSString *pluginId, NSString *version)) {
    id actionsRaw = plan[@"actions"];
    if (![actionsRaw isKindOfClass:[NSArray class]]) return @{@"error": @"Expected an install plan"};

    NSMutableArray<RepoInstallActionEntry *> *actions = [NSMutableArray array];
    for (id raw in actionsRaw) {
        NSString *parseError = nil;
        RepoInstallActionEntry *action = ParseRepoInstallAction(raw, &parseError);
        if (!action) return @{@"error": parseError ?: @"Expected a plan action object"};
        [actions addObject:action];
    }

    [[RepoStore sharedStore] ensureLoaded];
    [[SourcesStore sharedStore] ensureLoaded];

    __block NSDictionary *result = nil;
    __block NSString *installError = nil;

    dispatchSyncFs(^{
        PluginLoader *loader = [PluginLoader sharedLoader];
        if (actions.count == 0) {
            result = @{@"installed": @[], @"pending": @[], @"skipped": @[]};
            return;
        }

        NSURL *root = [loader pluginsDirectory];
        [[NSFileManager defaultManager] createDirectoryAtURL:root
                                 withIntermediateDirectories:YES attributes:nil error:nil];
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:root.path isDirectory:NULL] || ![fm isWritableFileAtPath:root.path]) {
            installError = [NSString stringWithFormat:@"Plugin directory is not writable: %@", root.path];
            return;
        }

        NSDictionary<NSString *, PluginVersion *> *installedVersions = [loader installedVersions];

        NSMutableArray<RepoInstallActionEntry *> *todo = [NSMutableArray array];
        for (RepoInstallActionEntry *action in actions) {
            PluginVersion *installed = installedVersions[action.actionId];
            if (installed && [installed.stringValue isEqualToString:action.version.stringValue]) continue;
            NSString *pending = [loader pendingUpdateForPlugin:action.actionId];
            if (pending && [pending isEqualToString:action.version.stringValue]) continue;
            [todo addObject:action];
        }
        NSMutableSet<NSString *> *todoIds = [NSMutableSet set];
        for (RepoInstallActionEntry *action in todo) [todoIds addObject:action.actionId];
        NSMutableArray *skipped = [NSMutableArray array];
        for (RepoInstallActionEntry *action in actions) {
            if (![todoIds containsObject:action.actionId]) [skipped addObject:action.actionId];
        }

        NSMutableDictionary<NSString *, PluginVersion *> *effectiveVersions =
            [NSMutableDictionary dictionaryWithDictionary:installedVersions];
        for (RepoInstallActionEntry *action in todo) effectiveVersions[action.actionId] = action.version;

        NSMutableArray<NSDictionary *> *staged = [NSMutableArray array];
        do {
            for (NSUInteger i = 0; i < todo.count; i++) {
                RepoInstallActionEntry *action = todo[i];
                ProgressEmit emit = MakeThrottledProgress(action, (NSInteger)i + 1, (NSInteger)todo.count);
                emit(0);
                NSString *downloadError = nil;
                NSData *bytes = DownloadAndVerify(action, emit, &downloadError);
                if (!bytes) {
                    installError = downloadError ?: @"Failed to download plugin artifact";
                    break;
                }
                emit(action.size);

                NSString *zipPath = [NSTemporaryDirectory()
                                     stringByAppendingPathComponent:[NSString stringWithFormat:@".repo-download-%lu.zip", (unsigned long)i]];
                [bytes writeToFile:zipPath atomically:YES];
                PluginErrorInfo *stageError = nil;
                PluginRecord *record = [loader extractPluginZipAtPath:zipPath
                                                                 root:root
                                                              tmpName:[NSString stringWithFormat:@"%@%lu", kRepoInstallTmpPrefix, (unsigned long)i]
                                                                error:&stageError];
                [[NSFileManager defaultManager] removeItemAtPath:zipPath error:nil];
                if (!record) {
                    installError = stageError.message ?: @"Failed to extract plugin artifact";
                    break;
                }

                if (![record.manifest.id isEqualToString:action.actionId] ||
                    ![record.manifest.version.stringValue isEqualToString:action.version.stringValue]) {
                    installError = [NSString stringWithFormat:
                        @"Artifact manifest (%@%@) does not match the plan (%@%@); aborting the install plan",
                        record.manifest.id, record.manifest.version.stringValue,
                        action.actionId, action.version.stringValue];
                    break;
                }
                [staged addObject:@{@"action": action, @"record": record,
                                     @"stagedDir": [record.bundlePath copy]}];
            }
            if (installError) break;

            NSMutableArray<PluginRecord *> *fresh = [NSMutableArray array];
            NSMutableArray<RepoInstallActionEntry *> *pending = [NSMutableArray array];
            NSMutableSet<NSString *> *pendingIds = [NSMutableSet set];
            for (NSDictionary *entry in OrderStagedByDependencies(staged)) {
                RepoInstallActionEntry *action = entry[@"action"];
                PluginRecord *record = entry[@"record"];
                NSString *applyError = nil;
                NSURL *dir = ApplyStagedPlugin(loader, record.bundlePath, action.actionId, &applyError);
                if (!dir) {
                    installError = applyError ?: @"Failed to apply staged plugin";
                    break;
                }
                record.bundlePath = dir.path;
                SourcesStoreSet(action.actionId, action.repo, action.channel);

                BOOL deferred = isInstalled(action.actionId);
                if (!deferred) {
                    for (NSString *depId in record.manifest.dependencies) {
                        PluginDependency *dep = record.manifest.dependencies[depId];
                        if (dep.optional) continue;
                        if ([pendingIds containsObject:depId] || isPendingReload(depId)) {
                            deferred = YES;
                            break;
                        }
                    }
                }
                if (deferred) {
                    [pendingIds addObject:action.actionId];
                    [pending addObject:action];
                    ValencedLog(@"Applied %@@%@ from %@ (pending reload)",
                                action.actionId, action.version.stringValue, action.repo);
                    continue;
                }

                NSString *readError = nil;
                PluginRecord *freshRecord = [loader readExternalPluginDir:dir
                                                            knownVersions:effectiveVersions
                                                                    error:&readError];
                if (!freshRecord) {
                    installError = readError ?: @"Failed to read installed plugin";
                    break;
                }
                [fresh addObject:freshRecord];
                ValencedLog(@"Installed %@@%@ from %@", action.actionId, action.version.stringValue, action.repo);
            }
            if (installError) break;

            for (PluginRecord *freshRecord in fresh) {
                [loader addRecord:freshRecord];
                [loader clearPersistedState:freshRecord.manifest.id];
                PluginSource *source = SourcesStoreAll()[freshRecord.manifest.id];
                freshRecord.hasSource = source != nil;
                freshRecord.sourceRepo = source.repo;
                freshRecord.sourceChannel = source.channel ?: REPO_CHANNEL_LATEST;
                EmitJSEvent(EVENT_PLUGIN_INSTALL_RESULT, @{
                    @"error": @NO,
                    @"plugin": [freshRecord toJSPayloadWithScript:YES],
                });
            }

            for (RepoInstallActionEntry *action in pending) {
                setPendingUpdate(action.actionId, action.version.stringValue);
                EmitJSEvent(EVENT_PLUGIN_UPDATED, @{
                    @"id": action.actionId,
                    @"version": action.version.stringValue,
                });
            }

            NSMutableArray *installedIds = [NSMutableArray array];
            for (PluginRecord *freshRecord in fresh) [installedIds addObject:freshRecord.manifest.id];
            NSMutableArray *pendingIdsList = [NSMutableArray array];
            for (RepoInstallActionEntry *action in pending) [pendingIdsList addObject:action.actionId];
            result = @{@"installed": installedIds, @"pending": pendingIdsList, @"skipped": skipped};
            break;
        } while (NO);

        for (NSDictionary *entry in staged) {
            NSString *stagedDir = entry[@"stagedDir"];
            if (stagedDir) [[NSFileManager defaultManager] removeItemAtPath:stagedDir error:nil];
        }
    });

    if (installError) return @{@"error": installError};
    return result ?: @{@"error": @"Failed to execute install plan"};
}

NSDictionary *ListUpdatesForRepo(NSString *url,
                                 PluginVersion * (^installedVersion)(NSString *pluginId),
                                 NSString * (^pendingUpdate)(NSString *pluginId)) {
    [[RepoStore sharedStore] ensureLoaded];
    [[SourcesStore sharedStore] ensureLoaded];

    BOOL known = NO;
    for (UserRepo *repo in [[RepoStore sharedStore] list]) {
        if ([repo.url isEqualToString:url]) { known = YES; break; }
    }
    if (!known) return @{@"error": [NSString stringWithFormat:@"Unknown repository: '%@'", url]};

    NSMutableDictionary *installed = [NSMutableDictionary dictionary];
    NSMutableDictionary *pending = [NSMutableDictionary dictionary];
    for (NSString *pluginId in SourcesStoreAll()) {
        PluginVersion *current = installedVersion(pluginId);
        if (current) installed[pluginId] = current.stringValue;
        NSString *pendingVersion = pendingUpdate(pluginId);
        if (pendingVersion.length > 0) pending[pluginId] = pendingVersion;
    }
    NSDictionary *installedDeps = [[PluginLoader sharedLoader] installedDependencies];
    NSMutableDictionary *deps = [NSMutableDictionary dictionaryWithCapacity:installedDeps.count];
    for (NSString *dependent in installedDeps) {
        NSMutableDictionary *ranges = [NSMutableDictionary dictionary];
        for (NSString *dep in installedDeps[dependent]) {
            ranges[dep] = [installedDeps[dependent][dep] stringValue];
        }
        deps[dependent] = ranges;
    }

    NSData *installedData = [NSJSONSerialization dataWithJSONObject:installed options:0 error:nil];
    NSData *pendingData = [NSJSONSerialization dataWithJSONObject:pending options:0 error:nil];
    NSData *depsData = [NSJSONSerialization dataWithJSONObject:deps options:0 error:nil];
    if (!installedData || !pendingData || !depsData) return @{@"error": @"Failed to encode installed plugins"};
    NSString *installedJson = [[NSString alloc] initWithData:installedData encoding:NSUTF8StringEncoding];
    NSString *pendingJson = [[NSString alloc] initWithData:pendingData encoding:NSUTF8StringEncoding];
    NSString *depsJson = [[NSString alloc] initWithData:depsData encoding:NSUTF8StringEncoding];

    char *error = NULL;
    char *json = ValencedCore_FindUpdates(installedJson.UTF8String, pendingJson.UTF8String,
                                          depsJson.UTF8String, &error);
    if (!json) return @{@"error": ValencedCore_ConsumeError(error)};

    NSData *updatesData = [ValencedCore_ConsumeString(json) dataUsingEncoding:NSUTF8StringEncoding];
    NSArray *all = updatesData ? [NSJSONSerialization JSONObjectWithData:updatesData options:0 error:nil] : nil;
    if (![all isKindOfClass:[NSArray class]]) return @{@"error": @"Invalid updates from ValencedCore"};

    NSMutableArray *updates = [NSMutableArray array];
    for (id entry in all) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        if (![entry[@"repo"] isKindOfClass:[NSString class]] || ![entry[@"repo"] isEqualToString:url]) continue;
        NSString *entryId = entry[@"id"];
        NSString *installedV = entry[@"installed"];
        NSString *available = entry[@"available"];
        NSString *channel = entry[@"channel"];
        if (![entryId isKindOfClass:[NSString class]] ||
            ![installedV isKindOfClass:[NSString class]] ||
            ![available isKindOfClass:[NSString class]] ||
            ![channel isKindOfClass:[NSString class]]) continue;
        [updates addObject:@{
            @"id": entryId,
            @"installed": installedV,
            @"available": available,
            @"channel": channel,
        }];
    }
    return @{@"updates": updates};
}
