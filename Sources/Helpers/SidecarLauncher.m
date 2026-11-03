//
//  Created by YueRuo on 2026/11/2.
//

// Project-owned helper. Only macOS frameworks are loaded; no third-party executable is used.
// Keep private API calls in this short-lived process, isolated from the menu-bar application.
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <math.h>
#include <signal.h>
#include <unistd.h>

typedef NS_ENUM(NSInteger, SCLExit) {
    SCLSuccess = 0, SCLInvalidInput = 1, SCLNoDevices = 2,
    SCLDeviceNotFound = 3, SCLBackendError = 4, SCLTimeout = 5
};

static NSError *SCLFailure(SCLExit code, NSString *message) {
    return [NSError errorWithDomain:@"local.HeadlessSidecarLogin.Sidecar" code:code
        userInfo:@{NSLocalizedDescriptionKey:message}];
}

static BOOL SCLValidName(id name) {
    return [name isKindOfClass:NSString.class] && [name length] > 0 && [name length] <= 256 &&
        [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound &&
        [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length > 0 &&
        [name dataUsingEncoding:NSUTF8StringEncoding] != nil;
}

static BOOL SCLTypeMatches(Method method, unsigned argument, const char *expected) {
    char *type = method_copyArgumentType(method, argument);
    BOOL valid = type && (strcmp(expected, "@") == 0 ? (type[0] == '@' && type[1] != '?') : strcmp(type, expected) == 0);
    free(type);
    return valid;
}

// Inspect the ABI before calling a fixed object getter, including a class getter on the metaclass.
static id SCLReadObject(id receiver, NSString *name) {
    if (!receiver) return nil;
    SEL selector = NSSelectorFromString(name);
    Method method = class_getInstanceMethod(object_getClass(receiver), selector);
    if (!method || method_getNumberOfArguments(method) != 2) return nil;
    char *type = method_copyReturnType(method);
    BOOL valid = type && type[0] == '@' && type[1] != '?';
    free(type);
    if (!valid) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(receiver, selector);
}

static id SCLLoadManager(NSError **error) {
    if (!dlopen("/System/Library/PrivateFrameworks/SidecarCore.framework/SidecarCore", RTLD_LAZY | RTLD_LOCAL)) {
        if (error) *error = SCLFailure(SCLBackendError, @"当前系统无法加载随航接口。");
        return nil;
    }
    id manager = SCLReadObject(NSClassFromString(@"SidecarDisplayManager"), @"sharedManager");
    if (!manager && error) *error = SCLFailure(SCLBackendError, @"当前系统的随航管理接口不可用。");
    return manager;
}

static NSArray<NSDictionary *> *SCLDeviceRecords(id raw, NSError **error) {
    NSArray *devices = nil;
    BOOL unordered = NO;
    if ([raw isKindOfClass:NSArray.class]) devices = raw;
    else if ([raw isKindOfClass:NSOrderedSet.class] && [raw count] <= 128) devices = [raw array];
    else if ([raw isKindOfClass:NSSet.class] && [raw count] <= 128) { devices = [raw allObjects]; unordered = YES; }
    if (!devices || devices.count > 128) {
        if (error) *error = SCLFailure(SCLBackendError, @"无法读取有效的随航设备列表。");
        return nil;
    }
    NSMutableArray *records = [NSMutableArray array];
    for (id device in devices) {
        id name = SCLReadObject(device, @"name");
        if (!SCLValidName(name)) {
            if (error) *error = SCLFailure(SCLBackendError, @"随航设备返回了无效的名称。");
            return nil;
        }
        [records addObject:@{@"device":device, @"name":[name copy]}];
    }
    if (unordered) [records sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] compare:b[@"name"]];
    }];
    return records;
}

static BOOL SCLPerform(id manager, NSString *command, id device, NSTimeInterval timeout, NSError **error) {
    // This function is only entered for the two whitelisted commands validated below.
    NSString *methodName = [command isEqualToString:@"connect"]
        ? @"connectToDevice:completion:" : @"disconnectFromDevice:completion:";
    SEL selector = NSSelectorFromString(methodName);
    Method method = class_getInstanceMethod(object_getClass(manager), selector);
    char *returnType = method ? method_copyReturnType(method) : NULL;
    BOOL supported = method && method_getNumberOfArguments(method) == 4 && returnType &&
        strcmp(returnType, "v") == 0 && SCLTypeMatches(method, 2, "@") && SCLTypeMatches(method, 3, "@?");
    free(returnType);
    if (!supported) {
        if (error) *error = SCLFailure(SCLBackendError, @"当前系统的随航操作接口不兼容。");
        return NO;
    }
    if (!NSThread.isMainThread || !isfinite(timeout) || timeout <= 0 || timeout > 45) {
        if (error) *error = SCLFailure(SCLTimeout, @"随航操作等待时间无效或已用尽。");
        return NO;
    }
    __block BOOL finished = NO;
    __block NSError *problem = nil;
    void (^completion)(NSError *) = ^(NSError *systemError) {
        // Private callbacks may arrive on any queue. All completion state lives on the main queue.
        NSError *failure = nil;
        if (systemError) {
            failure = [systemError isKindOfClass:NSError.class]
                ? SCLFailure(SCLBackendError, [NSString stringWithFormat:@"系统随航操作失败（错误 %ld）。", (long)systemError.code])
                : SCLFailure(SCLBackendError, @"系统随航操作返回了无效结果。");
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (finished) return;
            problem = failure;
            finished = YES;
        });
    };
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + timeout;
    ((void (*)(id, SEL, id, void (^)(NSError *)))objc_msgSend)(manager, selector, device, completion);
    while (!finished) {
        NSTimeInterval remaining = deadline - NSProcessInfo.processInfo.systemUptime;
        if (remaining <= 0) break;
        @autoreleasepool {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, MIN(remaining, 0.05), true);
        }
    }
    if (!finished) problem = SCLFailure(SCLTimeout, @"等待系统随航操作超时，请唤醒并解锁 iPad 后重试。");
    finished = YES; // Ignore a late or repeated callback if another test/run-loop turn follows.
    if (problem && error) *error = problem;
    return problem == nil;
}

// The provider and output sink make the real parsing, target selection and callback path testable.
static SCLExit SCLRun(NSArray *arguments, id (^managerProvider)(NSError **),
    void (^output)(NSString *), NSTimeInterval timeout, NSError **error) {
    if (error) *error = nil;
    if (![arguments isKindOfClass:NSArray.class] || arguments.count < 1 || arguments.count > 2) {
        if (error) *error = SCLFailure(SCLInvalidInput, @"用法：devices | connect <设备名> | disconnect <设备名>");
        return SCLInvalidInput;
    }
    id command = arguments[0];
    BOOL listing = [command isKindOfClass:NSString.class] && [command isEqualToString:@"devices"];
    BOOL operation = [command isKindOfClass:NSString.class] &&
        ([command isEqualToString:@"connect"] || [command isEqualToString:@"disconnect"]);
    if ((!listing && !operation) || (listing && arguments.count != 1) ||
        (operation && (arguments.count != 2 || !SCLValidName(arguments[1])))) {
        if (error) *error = SCLFailure(SCLInvalidInput, @"随航命令或设备名称无效。");
        return SCLInvalidInput;
    }
    @try {
        NSError *problem = nil;
        id manager = managerProvider ? managerProvider(&problem) : nil;
        if (!manager) {
            if (error) *error = problem ?: SCLFailure(SCLBackendError, @"随航管理接口不可用。");
            return SCLBackendError;
        }
        NSArray *records = SCLDeviceRecords(SCLReadObject(manager, @"devices"), &problem);
        if (!records) { if (error) *error = problem; return SCLBackendError; }
        if (records.count == 0) {
            if (error) *error = SCLFailure(SCLNoDevices, @"暂未发现可用的随航设备。");
            return SCLNoDevices;
        }
        if (listing) {
            // Validate the entire list before printing; never emit a partial malformed result.
            for (NSDictionary *record in records) if (output) output(record[@"name"]);
            return SCLSuccess;
        }
        id device = nil;
        for (NSDictionary *record in records) {
            if ([record[@"name"] caseInsensitiveCompare:arguments[1]] == NSOrderedSame) {
                device = record[@"device"];
                break;
            }
        }
        if (!device) {
            if (error) *error = SCLFailure(SCLDeviceNotFound, @"未发现指定名称的 iPad，请核对完整名称。");
            return SCLDeviceNotFound;
        }
        if (!SCLPerform(manager, command, device, timeout, &problem)) {
            if (error) *error = problem;
            return problem.code == SCLTimeout ? SCLTimeout : SCLBackendError;
        }
        if (output) output([command isEqualToString:@"connect"] ? @"connected" : @"disconnected");
        return SCLSuccess;
    } @catch (NSException *exception) {
        (void)exception;
        if (error) *error = SCLFailure(SCLBackendError, @"随航系统接口读取或调用失败。");
        return SCLBackendError;
    }
}

#ifndef SIDECAR_LAUNCHER_TEST
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSMutableArray *arguments = [NSMutableArray array];
        if (argc < 2 || argc > 3) {
            fprintf(stderr, "Usage: SidecarLauncher devices | connect <name> | disconnect <name>\n");
            return SCLInvalidInput;
        }
        for (int i = 1; i < argc; i++) {
            NSString *argument = [NSString stringWithUTF8String:argv[i]];
            if (!argument) return SCLInvalidInput;
            [arguments addObject:argument];
        }
        // The app enforces shorter per-query/operation timeouts. Also bound a standalone invocation.
        alarm(55);
        NSError *error = nil;
        SCLExit result = SCLRun(arguments, ^id(NSError **problem) { return SCLLoadManager(problem); },
            ^(NSString *line) { fprintf(stdout, "%s\n", line.UTF8String); }, 45, &error);
        if (error) fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
        return (int)result;
    }
}
#endif
