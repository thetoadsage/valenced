#import <Foundation/Foundation.h>
#import <objc/message.h>
#include <functional>
#include <memory>
#include <exception>
#define ValencedLog(...) ((void)0)

// Only the executor's queue/lifetime contract is mocked; dispatch and handlers are production code.
namespace jsi { struct Runtime {}; }
typedef NSDictionary *(^BridgeHandler)(NSArray *);
static NSMutableDictionary<NSString *, BridgeHandler> *bridgeHandlers(void) {
    static NSMutableDictionary *handlers;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ handlers = [NSMutableDictionary dictionary]; });
    return handlers;
}
#include "fs-queue.inc"
#include "bridge-dispatch.inc"
#include "bridge-calls.inc"

static dispatch_queue_t jsQueue;
static const char *jsQueueKey = "test-js-queue";
static int scheduled;
static jsi::Runtime testRuntime;
@interface TestInstance : NSObject
- (void)callFunctionOnBufferedRuntimeExecutor:(std::function<void(jsi::Runtime &)> &&)executor;
@end
@implementation TestInstance
- (void)callFunctionOnBufferedRuntimeExecutor:(std::function<void(jsi::Runtime &)> &&)executor {
    scheduled++;
    auto task = std::make_shared<std::function<void(jsi::Runtime &)>>(std::move(executor));
    dispatch_async(jsQueue, ^{ (*task)(testRuntime); });
}
@end
static void waitFor(dispatch_semaphore_t semaphore) {
    NSCAssert(dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) == 0,
              @"timed out: possible bridge deadlock");
}
static void asyncBridge(void) {
    TestInstance *instance __attribute__((objc_precise_lifetime)) = [TestInstance new];
    dispatch_semaphore_t entered = dispatch_semaphore_create(0);
    dispatch_semaphore_t releaseNative = dispatch_semaphore_create(0);
    dispatch_semaphore_t returned = dispatch_semaphore_create(0);
    dispatch_semaphore_t heartbeat = dispatch_semaphore_create(0);
    dispatch_semaphore_t completed = dispatch_semaphore_create(0);
    bridgeHandlers()[@"test.slow"] = ^NSDictionary *(NSArray *args) {
        NSCAssert(onFsQueue(), @"native work is not serialized on fsQueue");
        NSCAssert(!dispatch_get_specific(jsQueueKey), @"native work ran on JS thread");
        dispatch_semaphore_signal(entered);
        waitFor(releaseNative);
        return @{@"result": args.firstObject};
    };
    dispatch_async(jsQueue, ^{
        callBridgeMethodAsync(instance, @"test.slow", @[@42], ^(jsi::Runtime &runtime, NSDictionary *result) {
            NSCAssert(dispatch_get_specific(jsQueueKey), @"completion is off the JS thread");
            NSCAssert(&runtime == &testRuntime, @"wrong runtime");
            NSCAssert([result[@"result"] isEqual:@42], @"result envelope changed");
            dispatch_semaphore_signal(completed);
        });
        dispatch_semaphore_signal(returned);
    });
    waitFor(entered);
    waitFor(returned);
    dispatch_async(jsQueue, ^{
        NSDictionary *ack = callBridgeMethodHelper(@"valenced.__callableReturn", @[]);
        NSCAssert(ack[@"result"] == NSNull.null, @"acknowledgement failed");
        dispatch_semaphore_signal(heartbeat);
    });
    waitFor(heartbeat);
    NSCAssert(scheduled == 0, @"slow operation completed before release");
    dispatch_semaphore_signal(releaseNative);
    waitFor(completed);
}
static void destroyedInstance(void) {
    dispatch_semaphore_t releaseNative = dispatch_semaphore_create(0);
    dispatch_async(fsQueue(), ^{ waitFor(releaseNative); });
    __block BOOL ran = NO;
    __block BOOL completed = NO;
    bridgeHandlers()[@"test.work"] = ^NSDictionary *(NSArray *args) { ran = YES; return @{@"result": @YES}; };
    __weak TestInstance *weakInstance;
    @autoreleasepool {
        TestInstance *instance = [TestInstance new];
        weakInstance = instance;
        callBridgeMethodAsync(instance, @"test.work", @[], ^(jsi::Runtime &runtime, NSDictionary *result) { completed = YES; });
    }
    NSCAssert(!weakInstance, @"async operation retained the old runtime owner");
    dispatch_semaphore_signal(releaseNative);
    dispatchSyncFs(^{});
    dispatch_sync(jsQueue, ^{});
    NSCAssert(ran && !completed && scheduled == 0, @"callback dispatched to destroyed runtime");
}
static void errors(void) {
    BridgeHandler throwing = ^NSDictionary *(NSArray *args) {
        [NSException raise:NSInvalidArgumentException format:@"test failure"];
        return nil;
    };
    bridgeHandlers()[@"test.failure"] = throwing;
    bridgeHandlers()[@"valenced.plugins.failure"] = throwing;
    NSDictionary *plain = callBridgeMethodHelper(@"test.failure", @[]);
    NSCAssert([plain[@"error"] isEqual:@"test failure"], @"plain exception envelope changed");
    NSDictionary *plugin = callBridgeMethodHelper(@"valenced.plugins.failure", @[]);
    NSCAssert([plugin[@"result"][@"error"][@"message"] isEqual:@"test failure"], @"plugin exception envelope changed");
    NSDictionary *unknown = callBridgeMethodHelper(@"valenced.plugins.unknown", @[]);
    NSCAssert([unknown[@"result"][@"error"][@"code"] isEqual:@"UNKNOWN"], @"missing handler envelope changed");
}
int main(int argc, const char **argv) { @autoreleasepool {
    jsQueue = dispatch_queue_create("test-js-queue", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(jsQueue, jsQueueKey, (void *)jsQueueKey, NULL);
    NSString *name = argc > 1 ? @(argv[1]) : @"";
    if ([name isEqual:@"async"]) asyncBridge();
    else if ([name isEqual:@"destroyed"]) destroyedInstance();
    else if ([name isEqual:@"errors"]) errors();
    else return 2;
    printf("PASS %s\n", name.UTF8String);
} return 0; }
