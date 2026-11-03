//
//  Created by YueRuo on 2026/11/2.
//

#define HEADLESS_TEST 1
#import "../Sources/App/HeadlessSidecarLogin.m"
static NSString *const TestTarget = @"Demo iPad";

static NSUInteger assertions = 0;
static void Check(BOOL condition, NSString *description) {
    assertions++;
    if (!condition) { fprintf(stderr, "FAIL: %s\n", description.UTF8String); exit(1); }
}

static void CheckConnectionState(id report, NSString *target, NSString *state, NSString *description) {
    Check([ConnectionStatusFromReport(report, target)[@"state"] isEqualToString:state], description);
}

static NSDictionary *GPU(NSArray *displays) {
    return @{@"SPDisplaysDataType": @[@{@"_name": @"Apple M4", @"spdisplays_ndrvs": displays}]};
}

@interface FakeServices : LoginServices
@property (nonatomic, strong) NSMutableArray *events;
@property (nonatomic, strong) NSDictionary *snapshot;
@property BOOL failLaunch;
@property BOOL failConnect;
@property BOOL failDisconnect;
@end

@implementation FakeServices
- (instancetype)init {
    return [self initWithSettings:@{@"targetDevice": TestTarget, @"ignoreDisplayNames": @[]}];
}
- (instancetype)initWithSettings:(NSDictionary *)settings {
    if ((self = [super initWithSettings:settings])) _events = [NSMutableArray array];
    return self;
}
- (NSDictionary *)detect:(NSError **)error {
    [self.events addObject:@"detect"];
    if (!self.snapshot && error) *error = Failure(@"模拟检测失败");
    return self.snapshot;
}
- (BOOL)automaticDiscoveryStillAllowed:(NSError **)error { (void)error; return !self.cancelDiscoveryRequested; }
- (NSArray<NSString *> *)availableDeviceNames:(NSError **)error {
    (void)error;
    return ValidDeviceName(self.targetDevice) ? @[self.targetDevice] : @[];
}
- (NSArray<NSString *> *)connectedDeviceNames { return @[]; }
- (BOOL)launchBetterDisplay:(NSError **)error {
    [self.events addObject:@"BetterDisplay"];
    if (self.failLaunch && error) *error = Failure(@"模拟启动失败");
    return !self.failLaunch;
}
- (void)wait:(NSTimeInterval)seconds { [self.events addObject:@(seconds)]; }
- (BOOL)connectSidecar:(NSError **)error {
    [self.events addObject:@[@"connect", self.targetDevice]];
    if (self.failConnect && error) *error = Failure(@"模拟脚本失败");
    return !self.failConnect;
}
- (BOOL)disconnectSidecar:(NSError **)error {
    [self.events addObject:@[@"disconnect", self.targetDevice]];
    if (self.failDisconnect && error) *error = Failure(@"模拟断开失败");
    return !self.failDisconnect;
}
@end

#import "PhysicalDisplayMonitorTests.m"

@interface CommandSpyServices : LoginServices
@property (nonatomic, copy) NSArray *lastArguments;
@property (nonatomic) int exitStatus;
@end

@implementation CommandSpyServices
- (NSDictionary *)executeSidecarArguments:(NSArray<NSString *> *)arguments error:(NSError **)error {
    (void)error;
    self.lastArguments = arguments;
    return @{@"status": @(self.exitStatus)};
}
@end

#import "DeviceSelectionTests.m"
#import "DiscoveryRetryTests.m"
#import "CommandLineTests.m"
#import "LocalizationTests.m"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 3 && strcmp(argv[1], "--probe-instance-lock") == 0) {
            int fd = AcquireInstanceLockAtDirectory([NSString stringWithUTF8String:argv[2]], nil);
            // Deliberately let process exit close the descriptor, just like unexpected application termination.
            return fd >= 0 ? 0 : (fd == -2 ? 2 : 3);
        }
        if (argc == 2) TestLocalizationBundle = [NSBundle bundleWithPath:[NSString stringWithUTF8String:argv[1]]];
        NSError *error = nil;
        NSSet *ignoredNames = [NSSet setWithObject:TestTarget];
        NSDictionary *empty = ClassifyDisplays(GPU(@[]), ignoredNames, TestTarget, &error);
        Check([empty[@"shouldStart"] boolValue], @"无显示器时应启动");
        Check([empty[@"needsBetterDisplay"] boolValue], @"完全无屏时需要准备虚拟屏幕");
        Check(ClassifyDisplays(@{@"SPDisplaysDataType": @[@{@"_name": @"Apple M4"}]}, ignoredNames, TestTarget, &error) != nil,
              @"无屏 GPU 可省略 spdisplays_ndrvs");
        NSArray *physicalFixtures = @[
            @{@"_name": @"DELL U2720Q", @"spdisplays_connection_type": @"spdisplays_displayport_dongletype_dp"},
            @{@"_name": @"LG HDMI", @"spdisplays_connection_type": @"spdisplays_hdmi"},
            @{@"_name": @"Unknown external"},
            @{@"_name": @"Sleeping HDMI", @"spdisplays_online": @"spdisplays_yes", @"spdisplays_asleep": @YES},
            @{@"_name": @"Mirrored display", @"spdisplays_mirror": @"spdisplays_on"}
        ];
        for (NSDictionary *display in physicalFixtures) {
            NSDictionary *result = ClassifyDisplays(GPU(@[display]), ignoredNames, TestTarget, &error);
            Check(result && ![result[@"shouldStart"] boolValue], [@"实体屏幕应阻止启动: " stringByAppendingString:display[@"_name"]]);
            Check(![result[@"needsBetterDisplay"] boolValue], @"外接屏幕不依赖 BetterDisplay");
        }
        NSArray *virtualFixtures = @[
            @{@"_name": @"Custom virtual", @"spdisplays_connection_type": @"spdisplays_virtualdevice"},
            @{@"_name": @"Living Room", @"spdisplays_connection_type": @"spdisplays_airplay"},
            @{@"_name": @"iPad", @"spdisplays_connection_type": @"Sidecar"},
            @{@"_name": @"BetterDisplay", @"spdisplays_virtualdevice": @"spdisplays_yes"},
            @{@"_name": @"Remote", @"_spdisplays_airplay": @YES},
            @{@"_name": TestTarget}
        ];
        for (NSDictionary *display in virtualFixtures) {
            NSDictionary *result = ClassifyDisplays(GPU(@[display]), ignoredNames, TestTarget, &error);
            Check(result && [result[@"shouldStart"] boolValue] && [result[@"ignoredVirtualDisplays"] count] == 1,
                  [@"应忽略虚拟屏幕: " stringByAppendingString:display[@"_name"]]);
        }
        NSDictionary *internal = ClassifyDisplays(GPU(@[@{@"_name": @"Color LCD", @"spdisplays_connection_type": @"spdisplays_internal"}]), ignoredNames, TestTarget, &error);
        Check(![internal[@"shouldStart"] boolValue] && [internal[@"builtInDisplays"] count] == 1,
              @"内置屏幕也阻止自动连接");
        Check(![internal[@"needsBetterDisplay"] boolValue], @"内置屏幕不需要 BetterDisplay");
        NSDictionary *readyVirtual = ClassifyDisplays(GPU(@[virtualFixtures[0]]), ignoredNames, TestTarget, &error);
        Check(![readyVirtual[@"needsBetterDisplay"] boolValue] && [readyVirtual[@"virtualBaseDisplays"] count] == 1,
              @"已有独立虚拟屏幕时直接复用");
        for (NSDictionary *output in @[virtualFixtures[1], virtualFixtures[2], virtualFixtures[4], virtualFixtures[5]]) {
            NSDictionary *result = ClassifyDisplays(GPU(@[output]), ignoredNames, TestTarget, &error);
            Check([result[@"needsBetterDisplay"] boolValue] && [result[@"virtualBaseDisplays"] count] == 0,
                  @"不把随航目标或 AirPlay 当成独立虚拟屏幕");
        }
        for (NSDictionary *unavailable in @[
            @{@"_name": @"Offline virtual", @"spdisplays_virtualdevice": @YES, @"spdisplays_online": @"spdisplays_no"},
            @{@"_name": @"Sleeping virtual", @"spdisplays_virtualdevice": @YES, @"spdisplays_asleep": @YES}]) {
            Check([ClassifyDisplays(GPU(@[unavailable]), ignoredNames, TestTarget, &error)[@"needsBetterDisplay"] boolValue],
                  @"离线或休眠虚拟屏幕不作为就绪屏幕复用");
        }
        NSSet *customIgnored = [NSSet setWithArray:@[TestTarget, @"My Virtual Screen"]];
        Check(![ClassifyDisplays(GPU(@[@{@"_name": @"My Virtual Screen"}]), customIgnored, TestTarget, &error)[@"needsBetterDisplay"] boolValue],
              @"用户配置的独立虚拟屏幕可复用");
        Check([ClassifyDisplays(GPU(@[@{@"_name": @"demo ipad", @"spdisplays_virtualdevice": @YES}]), ignoredNames, TestTarget, &error)[@"needsBetterDisplay"] boolValue],
              @"忽略大小写识别目标 iPad，避免把它当作独立虚拟屏幕");
        NSDictionary *mixed = ClassifyDisplays(GPU(@[physicalFixtures[0], virtualFixtures[0]]), ignoredNames, TestTarget, &error);
        Check(![mixed[@"shouldStart"] boolValue] && [mixed[@"physicalExternalDisplays"] count] == 1 &&
              [mixed[@"ignoredVirtualDisplays"] count] == 1, @"实体屏幕与虚拟屏幕共存时不启动");
        NSDictionary *virtualGPU = @{@"SPDisplaysDataType": @[@{@"sppci_device_type": @"_sppci_virtualdisplay",
            @"spdisplays_ndrvs": @[@{@"_name": @"Remote screen"}]}]};
        Check([ClassifyDisplays(virtualGPU, ignoredNames, TestTarget, &error)[@"shouldStart"] boolValue], @"虚拟 GPU 下的屏幕应忽略");
        NSArray *invalid = @[@{}, @[], @{@"SPDisplaysDataType": @[]}, @{@"SPDisplaysDataType": @"bad"},
            @{@"SPDisplaysDataType": @[@"bad"]},
            @{@"SPDisplaysDataType": @[@{@"spdisplays_ndrvs": @"bad"}]}, GPU(@[@"bad"]), GPU(@[@{}])];
        for (id report in invalid) {
            error = nil;
            Check(ClassifyDisplays(report, ignoredNames, TestTarget, &error) == nil && error != nil, @"异常报告必须失败");
        }

        CheckPhysicalDisplayMonitor(mixed, internal, empty, readyVirtual);
        CheckAutomaticDeviceSelection(mixed, internal, empty);
        CheckDiscoveryRetries(mixed, internal, empty);
        CheckCommandLineConnection(mixed, internal, empty, readyVirtual);
        CheckLocalization(mixed, internal, empty);

        FakeServices *normal = [FakeServices new];
        normal.snapshot = empty;
        Check(RunWorkflow(normal) == 0, @"无屏启动流程成功");
        Check([normal.events isEqual:@[@"detect", @"detect", @"BetterDisplay", @1.0, @[@"connect", @"Demo iPad"]]],
              @"严格顺序: 检测 → BetterDisplay → 1 秒 → 指定连接参数");
        FakeServices *internalAutomatic = [FakeServices new];
        internalAutomatic.snapshot = internal;
        internalAutomatic.failLaunch = YES;
        Check(RunWorkflow(internalAutomatic) == 0 && [internalAutomatic.events isEqual:@[@"detect"]] &&
              [internalAutomatic.lastMessage containsString:@"跳过"],
              @"有内屏时自动流程跳过，不启动 BetterDisplay、不等待、不连接");
        for (NSArray *screens in @[
            @[@{@"_name": @"Built-in screen", @"spdisplays_display_type": @"spdisplays_built-in-retina"}],
            @[@{@"_name": @"Color LCD", @"spdisplays_connection_type": @"spdisplays_internal"}, physicalFixtures[0]],
            @[@{@"_name": @"Color LCD", @"spdisplays_connection_type": @"spdisplays_internal"}, virtualFixtures[0]]]) {
            FakeServices *withHardware = [FakeServices new];
            withHardware.snapshot = ClassifyDisplays(GPU(screens), ignoredNames, TestTarget, &error);
            Check(RunWorkflow(withHardware) == 0 && [withHardware.events isEqual:@[@"detect"]],
                  @"按屏幕类型识别内屏，以及内屏与其他屏幕共存时，均跳过自动连接");
        }
        FakeServices *virtualAutomatic = [FakeServices new];
        virtualAutomatic.snapshot = readyVirtual;
        virtualAutomatic.failLaunch = YES;
        Check(RunWorkflow(virtualAutomatic) == 0 && [virtualAutomatic.events isEqual:@[@"detect", @"detect", @[@"connect", TestTarget]]],
              @"已有独立虚拟屏幕时不启动 BetterDisplay");
        FakeServices *blocked = [FakeServices new];
        blocked.snapshot = mixed;
        Check(RunWorkflow(blocked) == 0 && [blocked.events isEqual:@[@"detect"]], @"实体屏幕不触发后续步骤");
        FakeServices *detectionFailure = [FakeServices new];
        Check(RunWorkflow(detectionFailure) == 1 && [detectionFailure.events isEqual:@[@"detect"]], @"检测失败不启动");
        FakeServices *launchFailure = [FakeServices new];
        launchFailure.snapshot = empty;
        launchFailure.failLaunch = YES;
        Check(RunWorkflow(launchFailure) == 1 && [launchFailure.events isEqual:@[@"detect", @"detect", @"BetterDisplay"]],
              @"BetterDisplay 失败不运行脚本");
        FakeServices *scriptFailure = [FakeServices new];
        scriptFailure.snapshot = empty;
        scriptFailure.failConnect = YES;
        Check(RunWorkflow(scriptFailure) == 1, @"脚本失败返回失败状态");

        Check([AutomaticConnectionMode(@{}) isEqualToString:AutomaticModeHeadless],
              @"旧设置缺少自动连接方式时，保留无实体屏幕时连接的行为");
        for (NSDictionary *snapshot in @[empty, internal, mixed, readyVirtual]) {
            FakeServices *disabled = [[FakeServices alloc] initWithSettings:@{
                @"targetDevice": TestTarget, @"automaticConnectionMode": AutomaticModeDisabled}];
            disabled.snapshot = snapshot;
            Check(RunWorkflow(disabled) == 0 && disabled.events.count == 0,
                  @"禁止自动连接时，在所有屏幕情况下都不检测、启动或连接");
        }
        FakeServices *disabledWithoutTarget = [[FakeServices alloc] initWithSettings:@{
            @"targetDevice": @"", @"automaticConnectionMode": AutomaticModeDisabled}];
        Check(RunWorkflow(disabledWithoutTarget) == 0 && disabledWithoutTarget.events.count == 0,
              @"禁止自动连接时可不设置 iPad，启动后保持待命");
        Check(RunDirectConnection(disabledWithoutTarget) == 1 && disabledWithoutTarget.events.count == 0,
              @"禁止自动连接且没有设备名时，手动连接仍要求先选择设备");
        for (NSDictionary *snapshot in @[internal, mixed, readyVirtual]) {
            FakeServices *always = [[FakeServices alloc] initWithSettings:@{
                @"targetDevice": TestTarget, @"automaticConnectionMode": AutomaticModeAlways}];
            always.snapshot = snapshot;
            always.failLaunch = YES;
            Check(RunWorkflow(always) == 0 && [always.events isEqual:@[@"detect", @"detect", @[@"connect", TestTarget]]],
                  @"始终自动连接时，有内屏、外屏或虚拟屏幕均继续连接且不需要 BetterDisplay");
        }
        FakeServices *alwaysHeadless = [[FakeServices alloc] initWithSettings:@{
            @"targetDevice": TestTarget, @"automaticConnectionMode": AutomaticModeAlways}];
        alwaysHeadless.snapshot = empty;
        Check(RunWorkflow(alwaysHeadless) == 0 && [alwaysHeadless.events isEqual:@[@"detect", @"detect", @"BetterDisplay", @1.0, @[@"connect", TestTarget]]],
              @"始终自动连接仍在无可用屏幕时准备 BetterDisplay，并保留 1 秒等待顺序");
        FakeServices *invalidMode = [[FakeServices alloc] initWithSettings:@{
            @"targetDevice": TestTarget, @"automaticConnectionMode": @"unknown"}];
        invalidMode.snapshot = empty;
        Check(RunWorkflow(invalidMode) == 1 && invalidMode.events.count == 0,
              @"未知连接方式拒绝执行，不回退到始终自动连接");
        FakeServices *manualWhenDisabled = [[FakeServices alloc] initWithSettings:@{
            @"targetDevice": TestTarget, @"automaticConnectionMode": AutomaticModeDisabled}];
        manualWhenDisabled.snapshot = internal;
        Check(RunDirectConnection(manualWhenDisabled) == 0 &&
              [manualWhenDisabled.events isEqual:@[@"detect", @[@"connect", TestTarget]]],
              @"禁止自动连接不限制用户手动连接");

        NSString *customName = @"小王's iPad $(example); `literal`";
        NSDictionary *customSettings = @{@"targetDevice": customName, @"ignoreDisplayNames": @[@"My Virtual Screen"],
                                         @"automaticConnectionMode": AutomaticModeHeadless, @"deviceSelectionMode": DeviceSelectionNamed};
        CheckConnectionState(@{@"available": @YES, @"connectedDeviceNames": @[TestTarget]}, TestTarget, @"connected", @"目标出现在已连接列表时为已连接");
        CheckConnectionState(@{@"available": @YES, @"connectedDeviceNames": @[@"demo ipad"]}, TestTarget, @"connected", @"名称匹配忽略大小写");
        CheckConnectionState(@{@"available": @YES, @"connectedDeviceNames": @[]}, TestTarget, @"disconnected", @"查询成功且列表为空时为未连接");
        CheckConnectionState(@{@"available": @YES, @"connectedDeviceNames": @[@"Other iPad"]}, TestTarget, @"disconnected", @"其他 iPad 已连接不会误判当前目标");
        CheckConnectionState(@{@"available": @YES, @"connectedDeviceNames": @[@"Demo iPad Pro"]}, TestTarget, @"disconnected", @"不使用设备名子串匹配");
        CheckConnectionState(@{@"available": @NO, @"connectedDeviceNames": @[TestTarget]}, TestTarget, @"unknown", @"失败报告不会误报已连接");
        CheckConnectionState(@[], TestTarget, @"unknown", @"非对象报告无法确认状态");
        CheckConnectionState(@{@"available": @YES}, TestTarget, @"unknown", @"缺失已连接列表时无法确认");
        CheckConnectionState(@{@"available": @YES, @"connectedDeviceNames": TestTarget}, TestTarget, @"unknown", @"列表类型异常时无法确认");
        CheckConnectionState(@{@"available": @YES, @"connectedDeviceNames": @[@"Bad\nName"]}, TestTarget, @"unknown", @"控制字符名称不会用于确认状态");
        CheckConnectionState(@{@"available": @YES, @"connectedDeviceNames": @[@12]}, TestTarget, @"unknown", @"非字符串设备名无法确认");
        NSMutableArray *tooManyNames = [NSMutableArray array];
        for (NSUInteger index = 0; index < 129; index++) [tooManyNames addObject:@"iPad"];
        CheckConnectionState(@{@"available": @YES, @"connectedDeviceNames": tooManyNames}, TestTarget, @"unknown", @"状态列表有数量上限");
        CheckConnectionState(@{@"available": @YES, @"connectedDeviceNames": @[TestTarget]}, @"", @"unconfigured", @"未保存目标设备时不判断其他设备");
        CheckConnectionState(@{@"available": @YES, @"availableDevices": @[TestTarget]}, TestTarget, @"unknown", @"设备可发现不等于已连接");
        CheckConnectionState(@{@"available": @"true", @"connectedDeviceNames": @[TestTarget]}, TestTarget, @"unknown", @"查询成功标记必须是数值类型");
        CheckConnectionState(@{@"available": @YES, @"connectedDeviceNames": @[@""]}, TestTarget, @"unknown", @"空设备名称无法确认");
        CheckConnectionState(@{@"available": @YES, @"connectedDeviceNames": @[@"Other iPad", TestTarget]}, TestTarget, @"connected", @"多个设备时逐个匹配保存的目标");
        Check([ReadConnectionStatus(@{@"targetDevice": @""})[@"state"] isEqualToString:@"unconfigured"], @"未配置时无需启动状态查询子进程");
        FakeServices *custom = [[FakeServices alloc] initWithSettings:customSettings];
        custom.snapshot = empty;
        Check(RunWorkflow(custom) == 0 && [custom.events.lastObject isEqual:@[@"connect", customName]],
              @"配置中的设备名逐字传递，不使用固定名称");
        Check([IgnoredDisplayNames(customSettings) containsObject:customName] &&
              [IgnoredDisplayNames(customSettings) containsObject:@"My Virtual Screen"] &&
              ![IgnoredDisplayNames(customSettings) containsObject:TestTarget], @"显示器忽略列表跟随配置更新");
        FakeServices *unconfigured = [[FakeServices alloc] initWithSettings:@{@"targetDevice": @"", @"ignoreDisplayNames": @[]}];
        unconfigured.snapshot = empty;
        Check(RunWorkflow(unconfigured) == 1 && unconfigured.events.count == 0, @"未配置设备时不执行自动流程");
        FakeServices *direct = [FakeServices new];
        direct.snapshot = mixed;
        direct.failLaunch = YES;
        Check(RunDirectConnection(direct) == 0 && [direct.events isEqual:@[@"detect", @[@"connect", TestTarget]]],
              @"手动连接有外屏时跳过 BetterDisplay 和等待，但仍连接 iPad");
        FakeServices *manualHeadless = [FakeServices new];
        manualHeadless.snapshot = empty;
        Check(RunDirectConnection(manualHeadless) == 0 && [manualHeadless.events isEqual:@[@"detect", @"BetterDisplay", @1.0, @[@"connect", TestTarget]]],
              @"手动连接完全无屏时先准备 BetterDisplay 并等待 1 秒");
        FakeServices *manualMissingBetterDisplay = [FakeServices new];
        manualMissingBetterDisplay.snapshot = empty;
        manualMissingBetterDisplay.failLaunch = YES;
        Check(RunDirectConnection(manualMissingBetterDisplay) == 1 &&
              [manualMissingBetterDisplay.events isEqual:@[@"detect", @"BetterDisplay"]] && manualMissingBetterDisplay.lastMessage.length,
              @"无屏且 BetterDisplay 缺失或失败时给出提示，不尝试随航连接");
        FakeServices *manualDetectionFailure = [FakeServices new];
        Check(RunDirectConnection(manualDetectionFailure) == 1 && [manualDetectionFailure.events isEqual:@[@"detect"]],
              @"手动连接检测失败时停止，不盲目启动 BetterDisplay 或随航");
        FakeServices *directCustom = [[FakeServices alloc] initWithSettings:customSettings];
        directCustom.snapshot = internal;
        directCustom.failLaunch = YES;
        Check(RunDirectConnection(directCustom) == 0 && [directCustom.events isEqual:@[@"detect", @[@"connect", customName]]],
              @"直接连接使用保存的名称并保留特殊字符");
        FakeServices *directFailure = [FakeServices new];
        directFailure.snapshot = internal;
        directFailure.failConnect = YES;
        Check(RunDirectConnection(directFailure) == 1 && [directFailure.lastMessage isEqualToString:@"模拟脚本失败"] &&
              [directFailure.events isEqual:@[@"detect", @[@"connect", TestTarget]]], @"直接连接失败时保留错误并停止");
        Check(RunDirectConnection(unconfigured) == 1 && unconfigured.events.count == 0,
              @"直接连接在未保存设备名称时不执行");
        FakeServices *invalidDirect = [[FakeServices alloc] initWithSettings:@{@"targetDevice": @"bad\nname"}];
        Check(RunDirectConnection(invalidDirect) == 1 && invalidDirect.events.count == 0,
              @"直接连接拒绝包含控制字符的设备名称");
        FakeServices *disconnect = [FakeServices new];
        disconnect.snapshot = mixed;
        disconnect.failLaunch = YES;
        Check(RunDisconnection(disconnect) == 0 && [disconnect.events isEqual:@[@[@"disconnect", TestTarget]]],
              @"断开只操作目标 iPad，不检测显示器、不启动 BetterDisplay 或连接");
        FakeServices *disconnectCustom = [[FakeServices alloc] initWithSettings:customSettings];
        Check(RunDisconnection(disconnectCustom) == 0 && [disconnectCustom.events isEqual:@[@[@"disconnect", customName]]],
              @"断开使用保存的完整设备名称并保留特殊字符");
        FakeServices *disconnectFailure = [FakeServices new];
        disconnectFailure.failDisconnect = YES;
        Check(RunDisconnection(disconnectFailure) == 1 && [disconnectFailure.lastMessage isEqualToString:@"模拟断开失败"],
              @"断开失败显示原始错误");
        Check(RunDisconnection(unconfigured) == 1 && unconfigured.events.count == 0,
              @"未保存设备名称时不执行断开");
        Check(RunDisconnection(invalidDirect) == 1 && invalidDirect.events.count == 0,
              @"断开拒绝控制字符设备名称");
        CommandSpyServices *commandSpy = [[CommandSpyServices alloc] initWithSettings:customSettings];
        Check([commandSpy disconnectSidecar:&error] && [commandSpy.lastArguments isEqual:@[@"disconnect", customName]],
              @"真实断开入口生成 disconnect 和独立设备名参数");
        Check([commandSpy connectSidecar:&error] && [commandSpy.lastArguments isEqual:@[@"connect", customName]],
              @"复用执行代码后连接入口仍生成 connect 参数");
        commandSpy.lastArguments = nil;
        Check(![commandSpy performSidecarCommand:@"disconnect; invalid" error:&error] && commandSpy.lastArguments == nil,
              @"执行命令只接受 connect 与 disconnect 白名单");
        CommandSpyServices *invalidCommandSpy = [[CommandSpyServices alloc] initWithSettings:@{@"targetDevice": @"bad\nname"}];
        Check(![invalidCommandSpy disconnectSidecar:&error] && invalidCommandSpy.lastArguments == nil,
              @"底层断开入口在执行前校验设备名称");
        commandSpy.exitStatus = 4;
        Check(![commandSpy disconnectSidecar:&error] && [error.localizedDescription containsString:@"断开连接失败"],
              @"断开非零退出码被报告为失败");
        commandSpy.exitStatus = 5;
        Check(![commandSpy connectSidecar:&error] && [error.localizedDescription containsString:@"超时"],
              @"源码连接助手的超时退出码映射为明确超时提示");
        NSArray *badSettings = @[@[], @{@"targetDevice": @12}, @{@"targetDevice": @"\nInjected"},
            @{@"targetDevice": @"   "}, @{@"ignoreDisplayNames": @"bad"},
            @{@"ignoreDisplayNames": @[@12]}, @{@"ignoreDisplayNames": @[@"Bad\nName"]},
            @{@"automaticConnectionMode": @"unknown"}, @{@"automaticConnectionMode": @""},
            @{@"automaticConnectionMode": @1}, @{@"automaticConnectionMode": @[]},
            @{@"automaticConnectionMode": NSNull.null},
            @{@"targetDevice": [@"x" stringByPaddingToLength:257 withString:@"x" startingAtIndex:0]}];
        for (id bad in badSettings) {
            error = nil;
            Check(NormalizeSettings(bad, &error) == nil && error != nil, @"设置类型、长度和控制字符校验");
        }
        error = nil;
        NSDictionary *legacy = NormalizeSettings(@{@"ignoreDisplayNames": @[@"Old Virtual"]}, &error);
        Check(legacy && [legacy[@"targetDevice"] length] == 0 && [legacy[@"ignoreDisplayNames"] count] == 1,
              @"旧版忽略列表配置可迁移，设备名仍需用户确认");
        NSString *temporary = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        NSString *configPath = [temporary stringByAppendingPathComponent:@"settings/config.json"];
        Check([ReadSettingsAtPath(configPath, &error)[@"targetDevice"] isEqualToString:@""], @"配置缺失返回未设置状态");
        error = nil;
        Check(SaveSettingsAtPath(customSettings, configPath, &error), @"保存完整设置");
        struct stat savedInfo;
        Check(stat(configPath.fileSystemRepresentation, &savedInfo) == 0 && (savedInfo.st_mode & 0777) == 0600,
              @"配置文件权限为当前用户独有");
        Check([ReadSettingsAtPath(configPath, &error) isEqual:customSettings], @"设置可持久化并逐字恢复");
        for (NSString *mode in @[AutomaticModeAlways, AutomaticModeDisabled, AutomaticModeHeadless]) {
            NSMutableDictionary *choice = [customSettings mutableCopy];
            choice[@"automaticConnectionMode"] = mode;
            Check(SaveSettingsAtPath(choice, configPath, &error) && [ReadSettingsAtPath(configPath, &error) isEqual:choice],
                  @"三种连接方式均可保存、重新读取，同时保留设备名和显示器忽略列表");
        }
        NSString *legacyPath = [temporary stringByAppendingPathComponent:@"settings/legacy.json"];
        NSDictionary *oldSettings = @{@"targetDevice": customName, @"ignoreDisplayNames": @[@"My Virtual Screen"]};
        [[NSJSONSerialization dataWithJSONObject:oldSettings options:0 error:nil] writeToFile:legacyPath atomically:YES];
        Check([ReadSettingsAtPath(legacyPath, &error) isEqual:customSettings],
              @"实际旧版配置文件读取时自动补齐默认连接方式，不丢失原设置");
        NSString *disabledPath = [temporary stringByAppendingPathComponent:@"settings/disabled.json"];
        NSDictionary *noDevice = @{@"targetDevice": @"", @"automaticConnectionMode": AutomaticModeDisabled};
        Check(SaveSettingsAtPath(noDevice, disabledPath, &error) &&
              [AutomaticConnectionMode(ReadSettingsAtPath(disabledPath, &error)) isEqualToString:AutomaticModeDisabled],
              @"允许仅保存禁止自动连接，设备名称可以暂时留空");
        Check(!SaveSettingsAtPath(@{@"targetDevice": @"", @"automaticConnectionMode": AutomaticModeAlways}, disabledPath, &error) &&
              [AutomaticConnectionMode(ReadSettingsAtPath(disabledPath, nil)) isEqualToString:AutomaticModeDisabled],
              @"始终自动连接必须有设备名，无效保存不覆盖已保存的禁止模式");
        Check(!SaveSettingsAtPath(@{@"targetDevice": @""}, configPath, &error) &&
              [ReadSettingsAtPath(configPath, nil) isEqual:customSettings], @"无效设置不会覆盖已保存配置");
        NSString *linkPath = [temporary stringByAppendingPathComponent:@"linked.json"];
        Check(symlink(configPath.fileSystemRepresentation, linkPath.fileSystemRepresentation) == 0 &&
              ReadSettingsAtPath(linkPath, &error) == nil, @"拒绝读取配置符号链接");
        NSString *largePath = [temporary stringByAppendingPathComponent:@"large.json"];
        [[NSMutableData dataWithLength:65537] writeToFile:largePath atomically:YES];
        Check(ReadSettingsAtPath(largePath, &error) == nil, @"配置读取限制 64 KiB");

        NSString *lockDirectory = [temporary stringByAppendingPathComponent:@"instance"];
        int ownerFD = AcquireInstanceLockAtDirectory(lockDirectory, &error);
        Check(ownerFD >= 0, @"首个实例取得应用全程锁");
        Check(AcquireInstanceLockAtDirectory(lockDirectory, nil) == -2, @"重复实例不能取得同一锁");
        Check((fcntl(ownerFD, F_GETFD) & FD_CLOEXEC) != 0, @"连接子进程不会继承应用实例锁");
        NSString *lockPath = [lockDirectory stringByAppendingPathComponent:@"instance.lock"];
        struct stat lockInfo;
        Check(stat(lockPath.fileSystemRepresentation, &lockInfo) == 0 && (lockInfo.st_mode & 0777) == 0600,
              @"实例锁为当前用户私有文件");
        NSString *testExecutable = NSProcessInfo.processInfo.arguments.firstObject;
        NSDictionary *otherProcess = RunTask(testExecutable, @[@"--probe-instance-lock", lockDirectory], 5, NO, nil, &error);
        Check(otherProcess && [otherProcess[@"status"] intValue] == 2, @"另一进程检测到已有实例并退出");
        close(ownerFD);
        NSDictionary *restart = RunTask(testExecutable, @[@"--probe-instance-lock", lockDirectory], 5, NO, nil, &error);
        Check(restart && [restart[@"status"] intValue] == 0, @"退出后保留的锁文件不影响重新启动");
        int afterProcessExit = AcquireInstanceLockAtDirectory(lockDirectory, &error);
        Check(afterProcessExit >= 0, @"进程未主动清理时，内核仍自动释放锁");
        close(afterProcessExit);
        NSString *parallelDirectory = [temporary stringByAppendingPathComponent:@"parallel-instance"];
        int *descriptors = calloc(8, sizeof(int));
        dispatch_apply(8, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t index) {
            @autoreleasepool { descriptors[index] = AcquireInstanceLockAtDirectory(parallelDirectory, nil); }
        });
        NSUInteger winners = 0, rejected = 0;
        for (NSUInteger index = 0; index < 8; index++) {
            if (descriptors[index] >= 0) { winners++; close(descriptors[index]); }
            else if (descriptors[index] == -2) rejected++;
        }
        free(descriptors);
        Check(winners == 1 && rejected == 7, @"八个同时启动请求只有一个取得实例锁");
        NSString *unsafeDirectory = [temporary stringByAppendingPathComponent:@"linked-instance"];
        Check(symlink(lockDirectory.fileSystemRepresentation, unsafeDirectory.fileSystemRepresentation) == 0 &&
              AcquireInstanceLockAtDirectory(unsafeDirectory, nil) == -1, @"拒绝符号链接实例目录");
        unlink(lockPath.fileSystemRepresentation);
        Check(symlink(configPath.fileSystemRepresentation, lockPath.fileSystemRepresentation) == 0 &&
              AcquireInstanceLockAtDirectory(lockDirectory, nil) == -1, @"拒绝符号链接实例锁文件");
        [NSFileManager.defaultManager removeItemAtPath:temporary error:nil];

        error = nil;
        NSDictionary *literal = RunTask(@"/usr/bin/printf", @[@"%s", @"$(touch /tmp/SHOULD_NOT_EXIST); `id`"], 2, YES, nil, &error);
        NSString *literalOutput = [[NSString alloc] initWithData:literal[@"output"] encoding:NSUTF8StringEncoding];
        Check([literalOutput isEqualToString:@"$(touch /tmp/SHOULD_NOT_EXIST); `id`"], @"参数保持字面量，不经过 Shell 执行");
        error = nil;
        NSDictionary *status = RunTask(@"/usr/bin/false", @[], 2, NO, nil, &error);
        Check([status[@"status"] intValue] == 1, @"保留非零退出码");
        error = nil;
        NSTimeInterval start = NSProcessInfo.processInfo.systemUptime;
        Check(RunTask(@"/bin/sleep", @[@"5"], 0.1, NO, nil, &error) == nil && error != nil &&
              NSProcessInfo.processInfo.systemUptime - start < 4, @"超时命令会被终止");
        error = nil;
        Check(RunTask(@"/nonexistent/launcher", @[], 1, NO, nil, &error) == nil && error != nil, @"缺失程序返回清晰失败");
        error = nil;
        Check(RunTask(@"/usr/bin/head", @[@"-c", @"4300000", @"/dev/zero"], 5, YES, nil, &error) == nil && error != nil,
              @"超大输出受 4 MiB 限制");
        error = nil;
        start = NSProcessInfo.processInfo.systemUptime;
        [NSThread sleepForTimeInterval:SidecarDelay];
        Check(NSProcessInfo.processInfo.systemUptime - start >= 1.0, @"真实等待不少于 1 秒");
        printf("PASS: %lu checks\n", (unsigned long)assertions);
        return 0;
    }
}
