//
//  Created by YueRuo on 2026/11/2.
//

#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <unistd.h>

static NSDictionary *Unavailable(NSString *reason) {
    return @{@"available": @NO, @"reason": reason};
}

static BOOL CanTrustEmptyResult(void) {
    // A restricted process can receive an empty list even while Sidecar is connected.
    // Only inspect our own confinement; do not change or relax any system policy.
    void *library = dlopen("/usr/lib/libsandbox.1.dylib", RTLD_LAZY | RTLD_LOCAL);
    if (!library) return NO;
    int (*check)(pid_t, const char *, int, ...) = dlsym(library, "sandbox_check");
    return check && check(getpid(), NULL, 0) == 0;
}

// Only fixed, zero-argument object getters are called. Check the runtime ABI first.
static id ReadObject(id receiver, SEL selector) {
    if (!receiver) return nil;
    Method method = class_getInstanceMethod(object_getClass(receiver), selector);
    if (!method || method_getNumberOfArguments(method) != 2) return nil;
    char *returnType = method_copyReturnType(method);
    BOOL returnsObject = returnType && returnType[0] == '@';
    free(returnType);
    if (!returnsObject) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(receiver, selector);
}

static NSDictionary *ReadConnectedDevices(void) {
    if (!dlopen("/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore", RTLD_LAZY | RTLD_LOCAL))
        return Unavailable(@"framework-unavailable");
    Class managerClass = NSClassFromString(@"SidecarDisplayManager");
    id manager = ReadObject(managerClass, NSSelectorFromString(@"sharedManager"));
    if (!manager) return Unavailable(@"manager-unavailable");
    id connected = ReadObject(manager, NSSelectorFromString(@"connectedDevices"));
    NSArray *devices;
    if ([connected isKindOfClass:NSArray.class]) devices = connected;
    else if ([connected isKindOfClass:NSSet.class] && [connected count] <= 128) devices = [connected allObjects];
    else if ([connected isKindOfClass:NSOrderedSet.class] && [connected count] <= 128) devices = [connected array];
    else return Unavailable(@"connected-devices-unavailable");
    if (devices.count > 128) return Unavailable(@"invalid-response");
    if (devices.count == 0 && !CanTrustEmptyResult()) return Unavailable(@"query-restricted");
    NSMutableSet *names = [NSMutableSet set];
    for (id device in devices) {
        id name = ReadObject(device, NSSelectorFromString(@"name"));
        if (![name isKindOfClass:NSString.class] || [name length] == 0 || [name length] > 256 ||
            [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound)
            return Unavailable(@"invalid-device-name");
        [names addObject:name];
    }
    return @{@"available": @YES, @"connectedDeviceNames": [names.allObjects sortedArrayUsingSelector:@selector(compare:)]};
}

int main(int argc, const char *argv[]) {
    (void)argv;
    @autoreleasepool {
        if (argc != 1) return 2;
        NSDictionary *report;
        @try { report = ReadConnectedDevices(); }
        @catch (NSException *exception) { (void)exception; report = Unavailable(@"query-failed"); }
        NSData *data = [NSJSONSerialization dataWithJSONObject:report options:0 error:nil];
        if (!data) return 1;
        fwrite(data.bytes, 1, data.length, stdout);
        fputc('\n', stdout);
        return 0;
    }
}
