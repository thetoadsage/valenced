#pragma once

#import <Foundation/Foundation.h>

#ifdef __cplusplus
namespace facebook { namespace jsi { class Runtime; } }
#endif

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

typedef NSDictionary * _Nonnull (^ _Nonnull BridgeHandler)(NSArray * _Nonnull args);

NSMutableDictionary<NSString *, BridgeHandler> *bridgeHandlers(void);

void RegisterBridgeMethods(void);
void SetHostBundleCacheSource(NSData * _Nullable data);

// ValencedBridge.callJSMethod
extern NSString * const EVENT_DOWNLOAD_PROGRESS;           // valenced.plugins.events.downloadProgress
extern NSString * const EVENT_PLUGIN_INSTALL_READY;        // valenced.plugins.events.pluginInstallFileReady
extern NSString * const EVENT_PLUGIN_INSTALL_RESULT;       // valenced.plugins.events.pluginInstallResult
extern NSString * const EVENT_PLUGIN_UPDATED;              // valenced.plugins.events.pluginUpdated
extern NSString * const EVENT_PLUGIN_ERRORED;              // valenced.plugins.events.pluginErrored
extern NSString * const EVENT_REPO_STATE_UPDATE;           // valenced.plugins.events.repoStateUpdate
extern NSString * const EVENT_DEPENDENCIES_UPDATED;        // valenced.plugins.events.dependenciesUpdated
extern NSString * const EVENT_PLUGIN_STOPPING;             // valenced.plugins.stopping

void EmitJSEvent(NSString *eventName, NSDictionary * _Nullable payload);
void EmitJSEventArgs(NSString *eventName, NSArray *args);

void SetJsiInstance(id _Nullable instance);
#ifdef __cplusplus
void SetJsiRuntime(facebook::jsi::Runtime *runtime);
void injectPreBundle(facebook::jsi::Runtime &runtime);
NSDictionary *callBridgeMethodHelper(NSString *methodName, NSArray *args);
#endif

NSString * _Nullable argString(NSArray *args, NSUInteger idx, NSString * _Nullable fallback);
BOOL        argBool(NSArray *args, NSUInteger idx, BOOL fallback);
id _Nullable argPresent(NSArray *args, NSUInteger idx);
BOOL        argIsString(NSArray *args, NSUInteger idx);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
