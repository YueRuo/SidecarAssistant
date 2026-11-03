//
//  Created by YueRuo on 2026/11/2.
//

#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <ServiceManagement/ServiceManagement.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>
#include <mach/mach_time.h>

#import "Localization.m"

static const NSTimeInterval SidecarDelay = 1.0;
static const NSTimeInterval AutomaticDiscoveryBudget = 120.0;
static const NSUInteger AutomaticDiscoveryMaximumAttempts = 16;
static int logFD = -1;
static NSString *const AutomaticModeHeadless = @"headless";
static NSString *const AutomaticModeAlways = @"always";
static NSString *const AutomaticModeDisabled = @"disabled";
static NSString *const DeviceSelectionNamed = @"named";
static NSString *const DeviceSelectionAutomatic = @"automatic";

static NSTimeInterval ContinuousTimeSeconds(void) {
    static mach_timebase_info_data_t timebase;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&timebase); });
    return timebase.denom ? (double)mach_continuous_time() * timebase.numer / timebase.denom / 1e9
        : NSProcessInfo.processInfo.systemUptime;
}

static NSTimeInterval DiscoveryRetryDelay(NSUInteger failures) {
    return failures == 1 ? 4.0 : (failures == 2 ? 6.0 : 8.0);
}

static NSTimeInterval TimeBudgetRemaining(NSTimeInterval deadline, NSTimeInterval maximum) {
    return deadline > 0 ? MAX(0.0, MIN(maximum, deadline - ContinuousTimeSeconds())) : maximum;
}

static NSString *DeviceSelectionMode(NSDictionary *settings) {
    id mode = settings[@"deviceSelectionMode"] ?: DeviceSelectionNamed;
    return [mode isKindOfClass:NSString.class] &&
        [@[DeviceSelectionNamed, DeviceSelectionAutomatic] containsObject:mode] ? mode : nil;
}

static BOOL UsesAutomaticDeviceSelection(NSDictionary *settings) {
    return [DeviceSelectionMode(settings) isEqualToString:DeviceSelectionAutomatic];
}

static NSString *AutomaticConnectionMode(NSDictionary *settings) {
    id mode = settings[@"automaticConnectionMode"] ?: AutomaticModeHeadless;
    return [mode isKindOfClass:NSString.class] &&
        [@[AutomaticModeHeadless, AutomaticModeAlways, AutomaticModeDisabled] containsObject:mode] ? mode : nil;
}

static const NSInteger ProcessTimeoutErrorCode = 2;

static NSError *Failure(NSString *message) {
    return [NSError errorWithDomain:@"local.HeadlessSidecarLogin" code:1
                          userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSString *LauncherPath(void) {
    return [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Contents/Helpers/SidecarLauncher"];
}

static NSString *SettingsPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/HeadlessSidecarLogin/config.json"];
}

static BOOL ValidDeviceName(id name) {
    return [name isKindOfClass:NSString.class] && [name length] > 0 && [name length] <= 256 &&
        [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location == NSNotFound &&
        [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length > 0;
}

static BOOL HasConfiguredDevice(NSDictionary *settings) {
    return UsesAutomaticDeviceSelection(settings) ||
        ([DeviceSelectionMode(settings) isEqualToString:DeviceSelectionNamed] && ValidDeviceName(settings[@"targetDevice"]));
}

static NSDictionary *NormalizeSettings(id input, NSError **error) {
    if (![input isKindOfClass:NSDictionary.class]) {
        if (error) *error = Failure(L(@"设置必须是 JSON 对象。"));
        return nil;
    }
    id target = input[@"targetDevice"] ?: @"";
    id names = input[@"ignoreDisplayNames"] ?: @[];
    NSString *automaticMode = AutomaticConnectionMode(input);
    NSString *selectionMode = DeviceSelectionMode(input);
    if (!selectionMode) {
        if (error) *error = Failure(L(@"设备选择方式无效，请重新选择并保存。"));
        return nil;
    }
    if (!automaticMode) {
        if (error) *error = Failure(L(@"自动连接方式无效，请重新选择并保存。"));
        return nil;
    }
    if (![target isKindOfClass:NSString.class] || ([target length] && !ValidDeviceName(target))) {
        if (error) *error = Failure(L(@"iPad 名称无效，最长 256 个字符，不能包含换行或控制字符。"));
        return nil;
    }
    if (![names isKindOfClass:NSArray.class] || [names count] > 128) {
        if (error) *error = Failure(L(@"ignoreDisplayNames 必须是字符串数组，最多 128 项。"));
        return nil;
    }
    for (id name in names) {
        if (![name isKindOfClass:NSString.class] || [name length] == 0 || [name length] > 512 ||
            [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound) {
            if (error) *error = Failure(L(@"忽略列表包含无效显示器名称。"));
            return nil;
        }
    }
    return @{@"targetDevice": target, @"ignoreDisplayNames": names, @"automaticConnectionMode": automaticMode,
             @"deviceSelectionMode": selectionMode};
}

static NSDictionary *ReadSettingsAtPath(NSString *path, NSError **error) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0) {
        if (errno == ENOENT) return NormalizeSettings(@{}, error);
        if (error) *error = Failure(L(@"无法读取设置，请检查配置文件的权限和路径。"));
        return nil;
    }
    struct stat info;
    if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_uid != getuid() ||
        info.st_nlink != 1 || info.st_size > 65536) {
        close(fd);
        if (error) *error = Failure(L(@"设置文件必须是当前用户的普通文件，且不超过 64 KiB。"));
        return nil;
    }
    NSMutableData *data = [NSMutableData data];
    unsigned char buffer[4096];
    ssize_t length;
    while ((length = read(fd, buffer, sizeof(buffer))) != 0) {
        if (length < 0) { if (errno == EINTR) continue; break; }
        [data appendBytes:buffer length:(NSUInteger)length];
        if (data.length > 65536) break;
    }
    close(fd);
    if (length < 0 || data.length > 65536) {
        if (error) *error = Failure(L(@"设置文件读取失败或超过 64 KiB。"));
        return nil;
    }
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
    return object ? NormalizeSettings(object, error) : nil;
}

static BOOL SaveSettingsAtPath(NSDictionary *settings, NSString *path, NSError **error) {
    NSDictionary *normalized = NormalizeSettings(settings, error);
    if (!normalized) return NO;
    if (!HasConfiguredDevice(normalized) &&
        ![AutomaticConnectionMode(normalized) isEqualToString:AutomaticModeDisabled]) {
        if (error) *error = Failure(L(@"请选择自动发现设备，或填写要连接的 iPad 名称。"));
        return NO;
    }
    NSString *directory = path.stringByDeletingLastPathComponent;
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions: @0700} error:error]) return NO;
    struct stat info;
    if (lstat(directory.fileSystemRepresentation, &info) != 0 || !S_ISDIR(info.st_mode) || info.st_uid != getuid()) {
        if (error) *error = Failure(L(@"设置目录不安全或不可访问。"));
        return NO;
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:normalized options:NSJSONWritingPrettyPrinted error:error];
    if (!data) return NO;
    char *temporary = strdup([[directory stringByAppendingPathComponent:@".settings.XXXXXX"] fileSystemRepresentation]);
    if (!temporary) { if (error) *error = Failure(L(@"无法分配设置文件。")); return NO; }
    int fd = mkstemp(temporary);
    BOOL ok = fd >= 0;
    if (ok) {
        ok = fchmod(fd, 0600) == 0;
        const unsigned char *bytes = data.bytes;
        NSUInteger offset = 0;
        while (ok && offset < data.length) {
            ssize_t written = write(fd, bytes + offset, data.length - offset);
            if (written < 0 && errno == EINTR) continue;
            if (written <= 0) { ok = NO; break; }
            offset += (NSUInteger)written;
        }
        if (ok) ok = fsync(fd) == 0;
        close(fd);
        if (ok) ok = rename(temporary, path.fileSystemRepresentation) == 0;
    }
    if (!ok) {
        (void)unlink(temporary);
        if (error) *error = Failure(L(@"保存设置失败，请检查当前账户的写入权限。"));
    }
    free(temporary);
    return ok;
}

static NSString *LogDirectory(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/HeadlessSidecarLogin"];
}

static void Log(NSString *message) {
    NSString *safe = [[message stringByReplacingOccurrencesOfString:@"\r" withString:@"\\r"]
                              stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], safe];
    if (logFD >= 0) {
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        // Every event is small; child process output is deliberately not logged.
        (void)write(logFD, data.bytes, data.length);
    } else {
        fprintf(stderr, "%s", line.UTF8String);
    }
}

static int OpenPrivateFile(NSString *path, int flags) {
    int fd = open(path.fileSystemRepresentation, flags | O_NOFOLLOW | O_CLOEXEC, 0600);
    struct stat info;
    if (fd < 0) return -1;
    if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_uid != getuid() || info.st_nlink != 1) {
        close(fd);
        return -1;
    }
    if (fchmod(fd, 0600) != 0) { close(fd); return -1; }
    return fd;
}

static NSString *const ShowExistingSettingsNotification = @"local.HeadlessSidecarLogin.showExistingSettings";

// Keep the descriptor open for the entire GUI lifetime. The kernel releases it on exit or crash.
// Unlike run.lock, this lock is shared by app copies and is never released when a connection finishes.
static int AcquireInstanceLockAtDirectory(NSString *directory, NSError **error) {
    if (![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions: @0700} error:error]) return -1;
    struct stat info;
    if (lstat(directory.fileSystemRepresentation, &info) != 0 || !S_ISDIR(info.st_mode) || info.st_uid != getuid()) {
        if (error) *error = Failure(L(@"无法安全访问应用实例锁目录。"));
        return -1;
    }
    NSString *path = [directory stringByAppendingPathComponent:@"instance.lock"];
    int fd = OpenPrivateFile(path, O_CREAT | O_RDWR);
    if (fd < 0) {
        if (error) *error = Failure(L(@"无法创建应用实例锁，已停止启动。"));
        return -1;
    }
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        int reason = errno;
        close(fd);
        if (reason == EWOULDBLOCK || reason == EAGAIN) return -2;
        if (error) *error = Failure(L(@"无法获取应用实例锁，已停止启动。"));
        return -1;
    }
    return fd;
}

static BOOL ExistingGUIInstanceIsRunning(void) {
    NSString *identifier = NSBundle.mainBundle.bundleIdentifier;
    if (!identifier.length) return NO;
    for (NSRunningApplication *application in [NSRunningApplication runningApplicationsWithBundleIdentifier:identifier]) {
        // New contenders have not initialized NSApplication yet; do not mistake them for an owner.
        if (application.processIdentifier != getpid() && application.finishedLaunching && !application.terminated) return YES;
    }
    return NO;
}

static void ShowExistingInstance(void) {
    NSString *identifier = NSBundle.mainBundle.bundleIdentifier;
    if (!identifier.length) return;
    // This session-local message only shows settings; it can never start a connection or change configuration.
    [NSDistributedNotificationCenter.defaultCenter postNotificationName:ShowExistingSettingsNotification
        object:identifier userInfo:nil options:NSDistributedNotificationDeliverImmediately];
    for (NSRunningApplication *application in [NSRunningApplication runningApplicationsWithBundleIdentifier:identifier]) {
        if (application.processIdentifier != getpid() && !application.terminated) {
            [application activateWithOptions:NSApplicationActivateAllWindows];
        }
    }
}

// Returns an open, locked descriptor that is held for the whole workflow.
static int PrepareRun(void) {
    NSString *directory = LogDirectory();
    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:directory
                                 withIntermediateDirectories:YES
                                                  attributes:@{NSFilePosixPermissions: @0700}
                                                       error:&error]) return -1;
    struct stat info;
    if (lstat(directory.fileSystemRepresentation, &info) != 0 ||
        !S_ISDIR(info.st_mode) || info.st_uid != getuid()) return -1;
    int lockFD = OpenPrivateFile([directory stringByAppendingPathComponent:@"run.lock"], O_CREAT | O_RDWR);
    if (lockFD < 0) return -1;
    if (flock(lockFD, LOCK_EX | LOCK_NB) != 0) { close(lockFD); return -2; }
    logFD = OpenPrivateFile([directory stringByAppendingPathComponent:@"run.log"], O_CREAT | O_WRONLY | O_APPEND);
    if (logFD < 0) { close(lockFD); return -1; }
    if (fstat(logFD, &info) == 0 && info.st_size > 1024 * 1024) (void)ftruncate(logFD, 0);
    return lockFD;
}

// Fixed executable + argument array. No shell evaluation or command interpolation.
// Capture is bounded to 4 MiB; both the process and the pipe have deadlines.
static NSDictionary *RunTask(NSString *executable, NSArray<NSString *> *arguments,
                             NSTimeInterval timeout, BOOL capture, NSString *workingDirectory,
                             NSError **error) {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:executable];
    task.arguments = arguments;
    if (workingDirectory) task.currentDirectoryURL = [NSURL fileURLWithPath:workingDirectory];
    NSMutableDictionary *environment = [NSProcessInfo.processInfo.environment mutableCopy];
    environment[@"PATH"] = @"/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";
    environment[@"HOME"] = NSHomeDirectory();
    task.environment = environment;
    task.standardInput = NSFileHandle.fileHandleWithNullDevice;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    NSPipe *pipe = capture ? [NSPipe pipe] : nil;
    task.standardOutput = capture ? (id)pipe : NSFileHandle.fileHandleWithNullDevice;
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    task.terminationHandler = ^(NSTask *unused) { (void)unused; dispatch_semaphore_signal(finished); };
    if (![task launchAndReturnError:error]) return nil;

    dispatch_group_t reader = dispatch_group_create();
    NSMutableData *output = [NSMutableData data];
    __block BOOL overflow = NO;
    __block BOOL readFailed = NO;
    if (capture) {
        dispatch_group_async(reader, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            @autoreleasepool {
                @try {
                    while (YES) {
                        NSData *chunk = pipe.fileHandleForReading.availableData;
                        if (chunk.length == 0) break;
                        if (output.length + chunk.length <= 4 * 1024 * 1024 && !overflow) {
                            [output appendData:chunk];
                        } else {
                            overflow = YES;
                        }
                    }
                } @catch (NSException *exception) { readFailed = YES; }
            }
        });
    }

    BOOL timedOut = dispatch_semaphore_wait(finished,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))) != 0;
    if (timedOut) {
        // NSTask owns this child; do not signal an unrelated process after it exits.
        @try { if (task.running) [task terminate]; } @catch (NSException *exception) {}
        if (dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) != 0) {
            if (task.running) (void)kill(task.processIdentifier, SIGKILL);
            (void)dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC));
        }
    }
    BOOL drained = dispatch_group_wait(reader, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0;
    if (timedOut || !drained) {
        if (error) *error = [NSError errorWithDomain:@"local.HeadlessSidecarLogin" code:ProcessTimeoutErrorCode
            userInfo:@{NSLocalizedDescriptionKey:L(@"进程执行或读取结果超时，已停止本次流程。")}];
        return nil;
    }
    if (overflow || readFailed) {
        if (error) *error = Failure(L(@"显示器报告过大或读取失败，已停止本次流程。"));
        return nil;
    }
    return @{@"status": @(task.terminationStatus), @"output": [output copy]};
}

static BOOL IsYes(id value) {
    if ([value isKindOfClass:NSNumber.class]) return [value boolValue];
    if (![value isKindOfClass:NSString.class]) return NO;
    return [@[@"yes", @"true", @"1", @"spdisplays_yes"] containsObject:[value lowercaseString]];
}

static BOOL IsExplicitlyNo(id value) {
    if ([value isKindOfClass:NSNumber.class]) return ![value boolValue];
    if (![value isKindOfClass:NSString.class]) return NO;
    return [@[@"no", @"false", @"0", @"spdisplays_no"] containsObject:[value lowercaseString]];
}

static NSDictionary *ConnectionSnapshot(NSString *state, NSString *target, NSArray *names) {
    return @{@"state": state, @"targetDevice": target ?: @"", @"connectedDeviceNames": names ?: @[]};
}

static NSArray<NSString *> *ConnectedNamesFromReport(id report) {
    if (![report isKindOfClass:NSDictionary.class] || ![report[@"available"] isKindOfClass:NSNumber.class] ||
        ![report[@"available"] boolValue]) return nil;
    id names = report[@"connectedDeviceNames"];
    if (![names isKindOfClass:NSArray.class] || [names count] > 128) return nil;
    for (id name in names) if (!ValidDeviceName(name)) return nil;
    return names;
}

static NSDictionary *ConnectionStatusFromReport(id report, NSString *target) {
    if (!ValidDeviceName(target)) return ConnectionSnapshot(@"unconfigured", @"", nil);
    NSArray *names = ConnectedNamesFromReport(report);
    if (!names) return ConnectionSnapshot(@"unknown", target, nil);
    BOOL connected = NO;
    for (id name in names) {
        // Match the exact device name, ignoring case like SidecarLauncher; never use substring matching.
        if ([name caseInsensitiveCompare:target] == NSOrderedSame) connected = YES;
    }
    return ConnectionSnapshot(connected ? @"connected" : @"disconnected", target, names);
}

static NSDictionary *ReadConnectedDeviceReportWithTimeout(NSTimeInterval timeout) {
    if (timeout <= 0) return nil;
    NSString *helper = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Contents/Helpers/SidecarStatus"];
    NSError *error = nil;
    // The helper only reads connectedDevices, and is isolated so a private API failure cannot hang the UI.
    NSDictionary *result = RunTask(helper, @[], MIN(5.0, timeout), YES, nil, &error);
    if (!result || [result[@"status"] intValue] != 0) return nil;
    id report = [NSJSONSerialization JSONObjectWithData:result[@"output"] options:0 error:&error];
    return [report isKindOfClass:NSDictionary.class] ? report : nil;
}

static NSDictionary *ReadConnectedDeviceReport(void) { return ReadConnectedDeviceReportWithTimeout(5.0); }

static NSDictionary *ConnectionStatusForSettings(id report, NSDictionary *settings) {
    if (!HasConfiguredDevice(settings)) return ConnectionSnapshot(@"unconfigured", @"", nil);
    if (!UsesAutomaticDeviceSelection(settings))
        return ConnectionStatusFromReport(report, settings[@"targetDevice"]);
    NSArray *names = ConnectedNamesFromReport(report);
    if (!names) return ConnectionSnapshot(@"unknown", @"", nil);
    return ConnectionSnapshot(names.count ? @"connected" : @"disconnected", names.firstObject ?: @"", names);
}

static NSDictionary *ReadConnectionStatus(NSDictionary *settings) {
    if (!HasConfiguredDevice(settings)) return ConnectionSnapshot(@"unconfigured", @"", nil);
    return ConnectionStatusForSettings(ReadConnectedDeviceReport(), settings);
}

static NSArray<NSString *> *DeviceNamesFromResult(id result, NSError **error) {
    if (![result isKindOfClass:NSDictionary.class] || ![result[@"status"] isKindOfClass:NSNumber.class] ||
        [result[@"status"] intValue] != 0 || ![result[@"output"] isKindOfClass:NSData.class] ||
        [result[@"output"] length] > 4 * 1024 * 1024) {
        if (error) *error = Failure(L(@"暂时无法查找可用 iPad，请稍后重试。"));
        return nil;
    }
    NSString *output = [[NSString alloc] initWithData:result[@"output"] encoding:NSUTF8StringEncoding];
    if (!output) {
        if (error) *error = Failure(L(@"设备列表暂时无法读取，请重新查找。"));
        return nil;
    }
    NSMutableOrderedSet<NSString *> *names = [NSMutableOrderedSet orderedSet];
    __block NSUInteger lines = 0;
    __block BOOL oversized = NO;
    [output enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
        if (++lines > 256) { oversized = YES; *stop = YES; return; }
        // Keep the exact name, including spaces and punctuation. Ignore invalid or blank names.
        if (ValidDeviceName(line)) [names addObject:line];
        if (names.count > 128) { oversized = YES; *stop = YES; }
    }];
    if (oversized) {
        if (error) *error = Failure(L(@"设备列表返回异常，请稍后重新查找。"));
        return nil;
    }
    return names.array;
}

static BOOL Contains(NSString *value, NSArray<NSString *> *needles) {
    for (NSString *needle in needles) if ([value containsString:needle]) return YES;
    return NO;
}

static NSString *StringValue(id value) {
    return [value isKindOfClass:NSString.class] ? value : @"";
}

static NSSet<NSString *> *IgnoredDisplayNames(NSDictionary *settings) {
    NSMutableSet *names = [NSMutableSet setWithArray:settings[@"ignoreDisplayNames"] ?: @[]];
    NSString *target = settings[@"targetDevice"];
    if (!UsesAutomaticDeviceSelection(settings) && target.length) [names addObject:target];
    return names;
}

static NSDictionary *ClassifyDisplays(id report, NSSet<NSString *> *ignoreNames, NSString *targetDevice, NSError **error) {
    if (![report isKindOfClass:NSDictionary.class] ||
        ![report[@"SPDisplaysDataType"] isKindOfClass:NSArray.class] ||
        [report[@"SPDisplaysDataType"] count] == 0 || [report[@"SPDisplaysDataType"] count] > 64) {
        if (error) *error = Failure(L(@"系统未提供有效的显示器报告。"));
        return nil;
    }
    NSMutableArray *physical = [NSMutableArray array];
    NSMutableArray *ignored = [NSMutableArray array];
    NSMutableArray *builtIn = [NSMutableArray array];
    NSMutableArray *virtualBase = [NSMutableArray array];
    for (id gpu in report[@"SPDisplaysDataType"]) {
        if (![gpu isKindOfClass:NSDictionary.class] ||
            (gpu[@"spdisplays_ndrvs"] && ![gpu[@"spdisplays_ndrvs"] isKindOfClass:NSArray.class]) ||
            [gpu[@"spdisplays_ndrvs"] count] > 128) {
            if (error) *error = Failure(L(@"系统显示器列表格式异常。"));
            return nil;
        }
        NSString *gpuType = [StringValue(gpu[@"sppci_device_type"]) lowercaseString];
        for (id display in gpu[@"spdisplays_ndrvs"]) {
            if (![display isKindOfClass:NSDictionary.class] || [display count] == 0) {
                if (error) *error = Failure(L(@"系统显示器信息格式异常。"));
                return nil;
            }
            NSString *name = StringValue(display[@"_name"]);
            if (name.length == 0) name = L(@"（未命名显示器）");
            NSString *connection = [StringValue(display[@"spdisplays_connection_type"]) lowercaseString];
            NSString *displayType = [StringValue(display[@"spdisplays_display_type"]) lowercaseString];
            BOOL internal = [connection isEqualToString:@"spdisplays_internal"] ||
                            [displayType containsString:@"built-in"];
            BOOL virtual = Contains(connection, @[@"virtual", @"airplay", @"sidecar"]) ||
                           Contains(displayType, @[@"virtual", @"airplay", @"sidecar"]) ||
                           Contains(gpuType, @[@"virtual", @"airplay", @"sidecar"]) ||
                           IsYes(display[@"spdisplays_virtualdevice"]) ||
                           IsYes(display[@"_spdisplays_airplay"]) ||
                           IsYes(gpu[@"_spdisplays_airplay"]) ||
                           [ignoreNames containsObject:name];
            // Reuse local virtual displays; keep Sidecar targets and AirPlay separate from that list.
            // Match the target separately from the configurable virtual-display ignore list.
            BOOL sidecar = Contains(connection, @[@"sidecar"]) || Contains(displayType, @[@"sidecar"]) ||
                           Contains(gpuType, @[@"sidecar"]) ||
                           (targetDevice.length && [name caseInsensitiveCompare:targetDevice] == NSOrderedSame);
            BOOL airplay = Contains(connection, @[@"airplay"]) || Contains(displayType, @[@"airplay"]) ||
                           Contains(gpuType, @[@"airplay"]) ||
                           IsYes(display[@"_spdisplays_airplay"]) || IsYes(gpu[@"_spdisplays_airplay"]);
            virtual = virtual || sidecar;
            NSDictionary *entry = @{@"name": name, @"connection": connection};
            if (internal) [builtIn addObject:entry];
            else if (virtual) {
                [ignored addObject:entry];
                if (!sidecar && !airplay && !IsExplicitlyNo(display[@"spdisplays_online"]) &&
                    !IsYes(display[@"spdisplays_asleep"]))
                    [virtualBase addObject:entry];
            }
            // Unknown external devices count as physical, including sleeping/mirrored monitors.
            else [physical addObject:entry];
        }
    }
    return @{@"physicalExternalDisplays": physical, @"ignoredVirtualDisplays": ignored,
             @"builtInDisplays": builtIn, @"virtualBaseDisplays": virtualBase,
             @"needsBetterDisplay": physical.count == 0 && builtIn.count == 0 && virtualBase.count == 0 ? @YES : @NO,
             @"shouldStart": physical.count == 0 && builtIn.count == 0 ? @YES : @NO};
}

static NSDictionary *ClassifyDisplaysForSettings(id report, NSDictionary *settings, id connectedReport, NSError **error) {
    NSMutableSet *names = [IgnoredDisplayNames(settings) mutableCopy];
    NSString *displayTarget = UsesAutomaticDeviceSelection(settings) ? @"" : settings[@"targetDevice"];
    if (UsesAutomaticDeviceSelection(settings)) {
        NSArray *connected = ConnectedNamesFromReport(connectedReport);
        if (connected) [names addObjectsFromArray:connected];
        displayTarget = connected.firstObject ?: @"";
    }
    return ClassifyDisplays(report, names, displayTarget, error);
}

static NSDictionary *ReadDisplaysWithDeadline(NSDictionary *settings, NSTimeInterval deadline, NSError **error) {
    NSDictionary *connected = UsesAutomaticDeviceSelection(settings)
        ? ReadConnectedDeviceReportWithTimeout(TimeBudgetRemaining(deadline, 5.0)) : nil;
    NSTimeInterval remaining = TimeBudgetRemaining(deadline, 20.0);
    if (remaining <= 0) {
        if (error) *error = Failure(L(@"自动查找已达到 2 分钟上限。"));
        return nil;
    }
    NSDictionary *result = RunTask(@"/usr/sbin/system_profiler",
        @[@"SPDisplaysDataType", @"-json", @"-timeout", @"15"], remaining, YES, nil, error);
    if (!result) return nil;
    if ([result[@"status"] intValue] != 0) {
        if (error) *error = Failure(L(@"暂时无法检查外接显示器，请稍后重试。"));
        return nil;
    }
    id report = [NSJSONSerialization JSONObjectWithData:result[@"output"] options:0 error:error];
    if (!report) return nil;
    return ClassifyDisplaysForSettings(report, settings, connected, error);
}

static NSDictionary *ReadDisplays(NSDictionary *settings, NSError **error) {
    return ReadDisplaysWithDeadline(settings, 0, error);
}

#import "PhysicalDisplayMonitor.m"

static NSURL *FindBetterDisplay(void) {
    NSArray *paths = @[@"/Applications/BetterDisplay.app",
                      [NSHomeDirectory() stringByAppendingPathComponent:@"Applications/BetterDisplay.app"]];
    for (NSString *path in paths) {
        NSBundle *bundle = [NSBundle bundleWithPath:path];
        if (bundle.executableURL) return [NSURL fileURLWithPath:path];
    }
    return [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:@"pro.betterdisplay.BetterDisplay"];
}

@interface LoginServices : NSObject
@property (nonatomic, copy, readonly) NSDictionary *settings;
@property (nonatomic, copy, readonly) NSString *targetDevice;
@property (nonatomic, copy) NSString *lastMessage;
@property (nonatomic, copy) NSString *resolvedTargetDevice;
@property (nonatomic) BOOL alreadyConnected;
@property (nonatomic) NSTimeInterval discoveryDeadline;
@property (atomic) BOOL cancelDiscoveryRequested;
@property (nonatomic, copy) void (^discoveryProgress)(NSString *message, BOOL searching);
- (instancetype)initWithSettings:(NSDictionary *)settings;
- (NSDictionary *)detect:(NSError **)error;
- (NSArray<NSString *> *)availableDeviceNames:(NSError **)error;
- (NSArray<NSString *> *)connectedDeviceNames;
- (BOOL)resolveConnectionDevice:(NSError **)error;
- (BOOL)discoverAutomaticConnectionDevice:(NSError **)error;
- (BOOL)resolveDisconnectionDevice:(NSError **)error;
- (NSTimeInterval)discoveryTime;
- (BOOL)automaticDiscoveryStillAllowed:(NSError **)error;
- (BOOL)waitForDiscoveryRetry:(NSTimeInterval)seconds;
- (void)reportDiscoveryProgress:(NSString *)message searching:(BOOL)searching;
- (BOOL)launchBetterDisplay:(NSError **)error;
- (void)wait:(NSTimeInterval)seconds;
- (BOOL)connectSidecar:(NSError **)error;
- (BOOL)disconnectSidecar:(NSError **)error;
- (BOOL)performSidecarCommand:(NSString *)command error:(NSError **)error;
- (NSDictionary *)executeSidecarArguments:(NSArray<NSString *> *)arguments error:(NSError **)error;
@end

@implementation LoginServices
- (instancetype)initWithSettings:(NSDictionary *)settings {
    if ((self = [super init])) _settings = [settings copy];
    return self;
}
- (NSString *)targetDevice {
    return UsesAutomaticDeviceSelection(self.settings) ? self.resolvedTargetDevice ?: @"" : self.settings[@"targetDevice"] ?: @"";
}
- (NSDictionary *)detect:(NSError **)error {
    return ReadDisplaysWithDeadline(self.settings, self.discoveryDeadline, error);
}
- (NSTimeInterval)discoveryTime { return ContinuousTimeSeconds(); }
- (BOOL)automaticDiscoveryStillAllowed:(NSError **)error {
    if (self.cancelDiscoveryRequested) {
        if (error) *error = Failure(L(@"已停止本次自动查找。仍可手动连接 iPad。"));
        return NO;
    }
    NSError *problem = nil;
    NSDictionary *current = ReadSettingsAtPath(SettingsPath(), &problem);
    if (!current) {
        if (error) *error = Failure(L(@"设置暂时无法读取，已停止本次自动查找。"));
        return NO;
    }
    if (![current isEqual:NormalizeSettings(self.settings, nil)]) {
        if (error) *error = Failure(L(@"设置已更改，已停止本次自动查找。"));
        return NO;
    }
    return YES;
}
- (BOOL)waitForDiscoveryRetry:(NSTimeInterval)seconds {
    NSTimeInterval end = MIN([self discoveryTime] + seconds, self.discoveryDeadline);
    while (!self.cancelDiscoveryRequested) {
        NSTimeInterval remaining = end - [self discoveryTime];
        if (remaining <= 0) return YES;
        [NSThread sleepForTimeInterval:MIN(0.1, remaining)];
    }
    return NO;
}
- (void)reportDiscoveryProgress:(NSString *)message searching:(BOOL)searching {
    if (self.discoveryProgress) self.discoveryProgress(message, searching);
}
- (NSArray<NSString *> *)availableDeviceNames:(NSError **)error {
    NSError *problem = nil;
    NSTimeInterval remaining = self.discoveryDeadline > 0 ? MAX(0.0, MIN(15.0, self.discoveryDeadline - [self discoveryTime])) : 15.0;
    if (remaining <= 0) {
        if (error) *error = Failure(L(@"自动查找已达到 2 分钟上限。"));
        return nil;
    }
    NSDictionary *result = RunTask(LauncherPath(), @[@"devices"], remaining, YES, nil, &problem);
    if (!result) {
        Log([NSString stringWithFormat:L(@"查找设备执行失败：%@"), problem.localizedDescription]);
        if (error) *error = Failure(L(@"暂时无法查找可用 iPad，请稍后重试。"));
        return nil;
    }
    return DeviceNamesFromResult(result, error);
}
- (NSArray<NSString *> *)connectedDeviceNames {
    NSTimeInterval remaining = self.discoveryDeadline > 0 ? MAX(0.0, MIN(5.0, self.discoveryDeadline - [self discoveryTime])) : 5.0;
    return ConnectedNamesFromReport(ReadConnectedDeviceReportWithTimeout(remaining));
}
- (BOOL)resolveConnectionDevice:(NSError **)error {
    if (!UsesAutomaticDeviceSelection(self.settings)) return ValidDeviceName(self.targetDevice);
    return [self discoverAutomaticConnectionDevice:error];
}
- (BOOL)discoverAutomaticConnectionDevice:(NSError **)error {
    self.alreadyConnected = NO;
    self.resolvedTargetDevice = nil;
    BOOL automatic = UsesAutomaticDeviceSelection(self.settings);
    NSArray *connected = [self connectedDeviceNames];
    NSString *existing = nil;
    for (NSString *name in connected) {
        if (automatic || [name caseInsensitiveCompare:self.settings[@"targetDevice"]] == NSOrderedSame) { existing = name; break; }
    }
    if (existing) {
        self.resolvedTargetDevice = existing;
        self.alreadyConnected = YES;
        return YES;
    }
    NSArray *names = [self availableDeviceNames:error];
    if (!names) return NO;
    NSString *selected = nil;
    for (NSString *name in names) {
        if (automatic || [name caseInsensitiveCompare:self.settings[@"targetDevice"]] == NSOrderedSame) { selected = name; break; }
    }
    if (!selected) {
        if (error) *error = Failure(automatic ? L(@"暂未发现可用 iPad，请唤醒并解锁设备后重试。")
            : L(@"暂未发现指定的 iPad，请唤醒并解锁设备后重试。"));
        return NO;
    }
    self.resolvedTargetDevice = selected;
    Log([NSString stringWithFormat:L(@"自动选择可用 iPad：%@。"), self.resolvedTargetDevice]);
    return YES;
}
- (BOOL)resolveDisconnectionDevice:(NSError **)error {
    self.resolvedTargetDevice = nil;
    if (!UsesAutomaticDeviceSelection(self.settings)) return ValidDeviceName(self.targetDevice);
    NSArray *connected = [self connectedDeviceNames];
    if (!connected.count) {
        if (error) *error = Failure(connected ? L(@"当前没有已连接的 iPad。") : L(@"暂时无法确认已连接的 iPad，请刷新状态后重试。"));
        return NO;
    }
    self.resolvedTargetDevice = connected.firstObject;
    return YES;
}
- (void)wait:(NSTimeInterval)seconds { [NSThread sleepForTimeInterval:seconds]; }
- (BOOL)launchBetterDisplay:(NSError **)error {
    NSURL *url = FindBetterDisplay();
    if (!url) {
        if (error) *error = Failure(L(@"当前没有可用屏幕。请先安装 BetterDisplay 并设置虚拟屏幕，再连接 iPad。"));
        return NO;
    }
    // RunWorkflow executes on a worker; AppKit launches on the main thread.
    dispatch_semaphore_t completed = dispatch_semaphore_create(0);
    __block NSError *launchError = nil;
    __block BOOL success = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
        configuration.activates = NO;
        configuration.addsToRecentItems = NO;
        configuration.promptsUserIfNeeded = NO;
        configuration.createsNewApplicationInstance = NO;
        [NSWorkspace.sharedWorkspace openApplicationAtURL:url configuration:configuration
            completionHandler:^(NSRunningApplication *app, NSError *problem) {
                launchError = problem;
                success = app != nil && problem == nil;
                dispatch_semaphore_signal(completed);
            }];
    });
    if (dispatch_semaphore_wait(completed, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC)) != 0) {
        if (error) *error = Failure(L(@"BetterDisplay 尚未准备好，请稍后再试。也可以先手动打开它。"));
        return NO;
    }
    if (!success) {
        Log([NSString stringWithFormat:L(@"打开 BetterDisplay 失败：%@"), launchError.localizedDescription ?: @"unknown"]);
        if (error) *error = Failure(L(@"无法打开 BetterDisplay。请先在「应用程序」中手动打开它，再试一次。"));
    }
    return success;
}
- (BOOL)connectSidecar:(NSError **)error {
    return [self performSidecarCommand:@"connect" error:error];
}
- (BOOL)disconnectSidecar:(NSError **)error {
    return [self performSidecarCommand:@"disconnect" error:error];
}
- (BOOL)performSidecarCommand:(NSString *)command error:(NSError **)error {
    if (![command isKindOfClass:NSString.class] || ![@[@"connect", @"disconnect"] containsObject:command]) {
        if (error) *error = Failure(L(@"不支持的随航操作。"));
        return NO;
    }
    if (!ValidDeviceName(self.targetDevice)) {
        if (error) *error = Failure(L(@"请先在设置中填写并保存 iPad 名称。"));
        return NO;
    }
    NSDictionary *result = [self executeSidecarArguments:@[command, self.targetDevice] error:error];
    if (!result) return NO;
    int status = [result[@"status"] intValue];
    if (status != 0) {
        NSString *operation = [command isEqualToString:@"disconnect"] ? L(@"断开连接") : L(@"连接");
        Log([NSString stringWithFormat:@"SidecarLauncher %@ exit=%d target=%@", command, status, self.targetDevice]);
        NSString *detail;
        if (status == 1 || status == 3) detail = L(@"请点击「查找 iPad」确认设备名称，然后保存设置。");
        else if (status == 2) detail = L(@"暂未找到可用 iPad，请唤醒并解锁设备后重试。");
        else if (status == 5) detail = L(@"等待系统随航操作超时，请唤醒并解锁 iPad 后重试。");
        else detail = L(@"请确认 iPad 已解锁且可用于随航，再试一次。");
        if (error) *error = Failure([NSString stringWithFormat:L(@"%@失败。%@"), operation, detail]);
        return NO;
    }
    return YES;
}
- (NSDictionary *)executeSidecarArguments:(NSArray<NSString *> *)arguments error:(NSError **)error {
    NSString *path = LauncherPath();
    BOOL isDirectory = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDirectory] || isDirectory ||
        ![[NSFileManager defaultManager] isExecutableFileAtPath:path]) {
        if (error) *error = Failure(L(@"应用文件不完整，请重新安装随航助手。"));
        return nil;
    }
    NSError *executionError = nil;
    NSDictionary *result = RunTask(path, arguments, 60, NO, [path stringByDeletingLastPathComponent], &executionError);
    if (!result) {
        Log([NSString stringWithFormat:L(@"随航操作执行失败：%@"), executionError.localizedDescription]);
        if (error) *error = Failure(([executionError.domain isEqualToString:@"local.HeadlessSidecarLogin"] && executionError.code == ProcessTimeoutErrorCode)
            ? L(@"操作等待超时，请确认 iPad 已唤醒，再试一次。") : L(@"暂时无法完成操作，请稍后重试。"));
    }
    return result;
}
@end

typedef NS_ENUM(NSUInteger, AutomaticDiscoveryResult) {
    AutomaticDiscoveryReady,
    AutomaticDiscoverySkipped,
    AutomaticDiscoveryFailed
};

static AutomaticDiscoveryResult FinishAutomaticDiscovery(LoginServices *services,
    AutomaticDiscoveryResult result, NSString *message) {
    services.discoveryDeadline = 0;
    if (message.length) { services.lastMessage = message; Log(message); }
    [services reportDiscoveryProgress:message ?: L(@"正在准备连接 iPad…") searching:NO];
    return result;
}

static AutomaticDiscoveryResult FindAutomaticDeviceWithRetry(LoginServices *services,
    BOOL skipWithPhysicalDisplay, NSDictionary **displaySnapshot) {
    NSTimeInterval deadline = [services discoveryTime] + AutomaticDiscoveryBudget;
    services.discoveryDeadline = deadline;
    [services reportDiscoveryProgress:L(@"正在查找可用 iPad，最多等待 2 分钟…") searching:YES];
    for (NSUInteger attempt = 0; attempt < AutomaticDiscoveryMaximumAttempts; attempt++) {
        NSError *error = nil;
        if (![services automaticDiscoveryStillAllowed:&error])
            return FinishAutomaticDiscovery(services, AutomaticDiscoverySkipped, error.localizedDescription);
        if ([services discoveryTime] >= deadline) break;
        if (attempt > 0) {
            NSDictionary *current = [services detect:&error];
            if ([services discoveryTime] >= deadline) break;
            if (!current) return FinishAutomaticDiscovery(services, AutomaticDiscoveryFailed,
                L(@"暂时无法确认屏幕状态，已停止本次自动查找。"));
            *displaySnapshot = current;
            if (skipWithPhysicalDisplay && ![current[@"shouldStart"] boolValue])
                return FinishAutomaticDiscovery(services, AutomaticDiscoverySkipped,
                    L(@"检测到内置或实体外接屏幕，已停止本次自动查找。"));
        }
        error = nil;
        if (![services automaticDiscoveryStillAllowed:&error])
            return FinishAutomaticDiscovery(services, AutomaticDiscoverySkipped, error.localizedDescription);
        BOOL found = [services discoverAutomaticConnectionDevice:&error];
        NSError *guardError = nil;
        if (![services automaticDiscoveryStillAllowed:&guardError])
            return FinishAutomaticDiscovery(services, AutomaticDiscoverySkipped, guardError.localizedDescription);
        if ([services discoveryTime] >= deadline) break;
        if (found) {
            // Finding ends the two-minute search budget. Validate eligibility again before connecting.
            services.discoveryDeadline = 0;
            NSDictionary *current = [services detect:&guardError];
            if (!current) return FinishAutomaticDiscovery(services, AutomaticDiscoveryFailed,
                L(@"暂时无法确认屏幕状态，未执行连接。"));
            *displaySnapshot = current;
            if (skipWithPhysicalDisplay && ![current[@"shouldStart"] boolValue])
                return FinishAutomaticDiscovery(services, AutomaticDiscoverySkipped,
                    L(@"检测到内置或实体外接屏幕，已跳过本次自动连接。"));
            if (![services automaticDiscoveryStillAllowed:&guardError])
                return FinishAutomaticDiscovery(services, AutomaticDiscoverySkipped, guardError.localizedDescription);
            [services reportDiscoveryProgress:[NSString stringWithFormat:L(@"已找到 %@，正在准备连接…"), services.targetDevice]
                searching:NO];
            return AutomaticDiscoveryReady;
        }
        Log([NSString stringWithFormat:L(@"第 %lu 次自动查找未发现目标：%@"), (unsigned long)(attempt + 1),
            error.localizedDescription ?: @"no device"]);
        NSTimeInterval remaining = deadline - [services discoveryTime];
        if (remaining <= 0) break;
        NSTimeInterval interval = DiscoveryRetryDelay(attempt + 1);
        NSString *progress = remaining < interval
            ? [NSString stringWithFormat:L(@"尚未发现可用 iPad，本次查找将在最多 %.0f 秒后结束。"), remaining]
            : [NSString stringWithFormat:L(@"尚未发现可用 iPad，%.0f 秒后重试（最多剩余 %.0f 秒）。"), interval, remaining];
        [services reportDiscoveryProgress:progress searching:YES];
        [services waitForDiscoveryRetry:MIN(interval, remaining)];
    }
    NSError *guardError = nil;
    if (![services automaticDiscoveryStillAllowed:&guardError])
        return FinishAutomaticDiscovery(services, AutomaticDiscoverySkipped, guardError.localizedDescription);
    return FinishAutomaticDiscovery(services, AutomaticDiscoveryFailed,
        L(@"2 分钟内未发现可用的目标 iPad，已停止本次自动查找。可唤醒并解锁设备后手动重试。"));
}

static int RunDisconnection(LoginServices *services) {
    if (!HasConfiguredDevice(services.settings)) {
        services.lastMessage = L(@"请先保存要断开连接的 iPad 名称。");
        Log(services.lastMessage);
        return 1;
    }
    NSError *error = nil;
    if (![services resolveDisconnectionDevice:&error]) {
        services.lastMessage = error.localizedDescription ?: L(@"请先选择要断开连接的 iPad。");
        Log(services.lastMessage);
        return 1;
    }
    Log([NSString stringWithFormat:L(@"手动断开 iPad 连接：%@。"), services.targetDevice]);
    if (![services disconnectSidecar:&error]) {
        services.lastMessage = error.localizedDescription ?: L(@"断开连接失败，请重试。");
        Log(services.lastMessage);
        return 1;
    }
    services.lastMessage = L(@"断开操作已完成，连接状态会自动更新。");
    Log(services.lastMessage);
    return 0;
}

static int RunConnection(LoginServices *services, BOOL skipWithPhysicalDisplay, BOOL automaticFlow) {
    NSError *error = nil;
    if (!HasConfiguredDevice(services.settings)) {
        services.lastMessage = L(@"请选择自动发现设备，或保存要连接的 iPad 名称。");
        Log(services.lastMessage);
        return 1;
    }
    Log(L(@"开始检查屏幕并准备连接。"));
    NSDictionary *displays = [services detect:&error];
    if (!displays) {
        Log([NSString stringWithFormat:L(@"显示器检测失败：%@"), error.localizedDescription]);
        services.lastMessage = L(@"暂时无法检查外接显示器，请稍后重试。");
        return 1;
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:displays options:0 error:nil];
    Log([[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]);
    if (skipWithPhysicalDisplay && ![displays[@"shouldStart"] boolValue]) {
        services.lastMessage = L(@"检测到内置或实体外接屏幕，已跳过本次自动连接。");
        Log(services.lastMessage);
        return 0;
    }
    if (automaticFlow) {
        AutomaticDiscoveryResult result = FindAutomaticDeviceWithRetry(services, skipWithPhysicalDisplay, &displays);
        if (result != AutomaticDiscoveryReady) return result == AutomaticDiscoverySkipped ? 0 : 1;
    } else if (![services resolveConnectionDevice:&error]) {
        services.lastMessage = error.localizedDescription ?: L(@"暂时无法选择连接设备，请重新查找 iPad。");
        Log(services.lastMessage);
        return 1;
    }
    if (services.alreadyConnected) {
        services.lastMessage = [NSString stringWithFormat:L(@"%@ 已连接，继续使用当前设备。"), services.targetDevice];
        Log(services.lastMessage);
        return 0;
    }
    if ([displays[@"needsBetterDisplay"] boolValue]) {
        if (![services launchBetterDisplay:&error]) {
            services.lastMessage = error.localizedDescription ?: L(@"暂时无法准备虚拟屏幕，请检查 BetterDisplay。");
            Log(services.lastMessage);
            return 1;
        }
        Log(L(@"无可用屏幕，BetterDisplay 已启动或已在运行；等待 1 秒。"));
        [services wait:SidecarDelay];
    } else Log(L(@"已有内置、外接或独立虚拟屏幕，无需启动 BetterDisplay。"));
    if (automaticFlow && ![services automaticDiscoveryStillAllowed:&error]) {
        services.lastMessage = error.localizedDescription;
        Log(services.lastMessage);
        return 0;
    }
    Log([NSString stringWithFormat:L(@"执行内置 SidecarLauncher，连接 iPad：%@。"), services.targetDevice]);
    if (![services connectSidecar:&error]) {
        services.lastMessage = error.localizedDescription ?: L(@"随航连接失败，请重试。");
        Log(services.lastMessage);
        return 1;
    }
    services.lastMessage = UsesAutomaticDeviceSelection(services.settings)
        ? [NSString stringWithFormat:L(@"已向 %@ 发起连接，连接状态会自动更新。"), services.targetDevice]
        : L(@"连接操作已完成，连接状态会自动更新。");
    Log(services.lastMessage);
    return 0;
}

static int RunDirectConnection(LoginServices *services) {
    Log(L(@"手动连接 iPad。"));
    return RunConnection(services, NO, NO);
}

static int RunWorkflow(LoginServices *services) {
    NSString *mode = AutomaticConnectionMode(services.settings);
    if (!mode) {
        services.lastMessage = L(@"自动连接方式无效，请重新选择并保存。");
        Log(services.lastMessage);
        return 1;
    }
    if ([mode isEqualToString:AutomaticModeDisabled]) {
        services.lastMessage = L(@"已禁止自动连接，仍可手动连接 iPad。");
        Log(services.lastMessage);
        return 0;
    }
    Log([NSString stringWithFormat:L(@"自动连接方式：%@。"), mode]);
    return RunConnection(services, [mode isEqualToString:AutomaticModeHeadless], YES);
}

typedef NS_ENUM(NSUInteger, CommandLineMode) {
    CommandLineModeGUI,
    CommandLineModeSettings,
    CommandLineModeCheck,
    CommandLineModeStatus,
    CommandLineModeAutomaticConnection,
    CommandLineModeDirectConnection,
    CommandLineModeInvalid
};

static CommandLineMode ParseCommandLineMode(int argc, const char *argv[]) {
    if (argc < 1 || !argv || !argv[0]) return CommandLineModeInvalid;
    if (argc == 1) return CommandLineModeGUI;
    if (argc != 2 || !argv[1]) return CommandLineModeInvalid;
    if (strcmp(argv[1], "--settings") == 0) return CommandLineModeSettings;
    if (strcmp(argv[1], "--check") == 0) return CommandLineModeCheck;
    if (strcmp(argv[1], "--status") == 0) return CommandLineModeStatus;
    if (strcmp(argv[1], "--run") == 0) return CommandLineModeAutomaticConnection;
    if (strcmp(argv[1], "--connect") == 0) return CommandLineModeDirectConnection;
    return CommandLineModeInvalid;
}

static int RunCommandLineConnection(CommandLineMode mode, LoginServices *services) {
    if (mode == CommandLineModeDirectConnection) return RunDirectConnection(services);
    if (mode == CommandLineModeAutomaticConnection) return RunWorkflow(services);
    return 2;
}

#ifndef HEADLESS_TEST
#import "SettingsUI.m"
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        CommandLineMode mode = ParseCommandLineMode(argc, argv);
        if (mode == CommandLineModeInvalid) {
            fprintf(stderr, "Usage: HeadlessSidecarLogin [--check | --run | --connect | --settings | --status]\n");
            return 2;
        }
        if (mode == CommandLineModeGUI || mode == CommandLineModeSettings) {
            if (ExistingGUIInstanceIsRunning()) { ShowExistingInstance(); return 0; }
            NSError *instanceError = nil;
            int instanceFD = AcquireInstanceLockAtDirectory(SettingsPath().stringByDeletingLastPathComponent, &instanceError);
            if (instanceFD == -2) { ShowExistingInstance(); return 0; }
            if (instanceFD < 0) { Log(instanceError.localizedDescription); return 1; }
            int result = SettingsMain(mode == CommandLineModeSettings);
            close(instanceFD);
            return result;
        }
        NSError *error = nil;
        NSDictionary *settings = ReadSettingsAtPath(SettingsPath(), &error);
        if (!settings) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
        if (mode == CommandLineModeStatus) {
            NSDictionary *snapshot = ReadConnectionStatus(settings);
            NSData *json = [NSJSONSerialization dataWithJSONObject:snapshot options:NSJSONWritingPrettyPrinted error:&error];
            if (!json) return 1;
            fwrite(json.bytes, 1, json.length, stdout);
            fputc('\n', stdout);
            return [@[@"connected", @"disconnected"] containsObject:snapshot[@"state"]] ? 0 : 1;
        }
        if (mode == CommandLineModeCheck) {
            NSDictionary *displays = ReadDisplays(settings, &error);
            if (!displays) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
            NSMutableDictionary *check = [displays mutableCopy];
            check[@"betterDisplayFound"] = FindBetterDisplay() != nil ? @YES : @NO;
            check[@"sidecarLauncherExecutable"] = @([NSFileManager.defaultManager isExecutableFileAtPath:LauncherPath()]);
            check[@"launcherPath"] = LauncherPath();
            check[@"targetDevice"] = settings[@"targetDevice"];
            check[@"configured"] = HasConfiguredDevice(settings) ? @YES : @NO;
            check[@"deviceSelectionMode"] = DeviceSelectionMode(settings);
            check[@"automaticConnectionMode"] = AutomaticConnectionMode(settings);
            check[@"settingsPath"] = SettingsPath();
            NSData *json = [NSJSONSerialization dataWithJSONObject:check options:NSJSONWritingPrettyPrinted error:&error];
            if (!json) return 1;
            fwrite(json.bytes, 1, json.length, stdout);
            fputc('\n', stdout);
            return 0;
        }
        int lockFD = PrepareRun();
        if (lockFD == -2) {
            if (mode == CommandLineModeDirectConnection) {
                fprintf(stderr, "%s\n", L(@"另一个连接或检查操作正在进行，请稍后再试。").UTF8String);
                return 1;
            }
            return 0;
        }
        if (lockFD < 0) { Log(L(@"无法创建专用运行日志或锁文件。")); return 1; }
        __block int exitCode = 1;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            @autoreleasepool {
                int result = RunCommandLineConnection(mode, [[LoginServices alloc] initWithSettings:settings]);
                dispatch_async(dispatch_get_main_queue(), ^{
                    exitCode = result;
                    CFRunLoopStop(CFRunLoopGetMain());
                });
            }
        });
        // NSWorkspace completion uses the main run loop; this helper needs no windows or NSApplication.
        CFRunLoopRun();
        close(lockFD);
        close(logFD);
        return exitCode;
    }
}
#endif
