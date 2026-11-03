//
//  Created by YueRuo on 2026/11/2.
//

// Fake discovery and command execution exercise the real resolution and argument-building paths.
@interface DiscoveryTestServices : LoginServices
@property (nonatomic, strong) NSMutableArray *events;
@property (nonatomic, copy) NSDictionary *snapshot;
@property (nonatomic, copy) NSArray<NSString *> *discoverableNames;
@property (nonatomic, copy) NSArray<NSString *> *connectedNames;
@property (nonatomic) BOOL discoveryFails;
@property (nonatomic) BOOL connectedQueryFails;
@end

@implementation DiscoveryTestServices
- (instancetype)initWithSettings:(NSDictionary *)settings {
    if ((self = [super initWithSettings:settings])) _events = [NSMutableArray array];
    return self;
}
- (BOOL)automaticDiscoveryStillAllowed:(NSError **)error { (void)error; return !self.cancelDiscoveryRequested; }
- (NSDictionary *)detect:(NSError **)error {
    [self.events addObject:@"detect"];
    if (!self.snapshot && error) *error = Failure(@"模拟检测失败");
    return self.snapshot;
}
- (NSArray<NSString *> *)availableDeviceNames:(NSError **)error {
    [self.events addObject:@"discover"];
    if (self.discoveryFails) {
        if (error) *error = Failure(@"模拟查找失败");
        return nil;
    }
    return self.discoverableNames ?: @[];
}
- (NSArray<NSString *> *)connectedDeviceNames {
    [self.events addObject:@"connected-devices"];
    return self.connectedQueryFails ? nil : self.connectedNames ?: @[];
}
- (BOOL)launchBetterDisplay:(NSError **)error {
    (void)error;
    [self.events addObject:@"BetterDisplay"];
    return YES;
}
- (void)wait:(NSTimeInterval)seconds { [self.events addObject:@(seconds)]; }
- (NSDictionary *)executeSidecarArguments:(NSArray<NSString *> *)arguments error:(NSError **)error {
    (void)error;
    [self.events addObject:arguments];
    return @{@"status": @0};
}
@end

static NSDictionary *AutomaticDeviceSettings(NSString *automaticMode) {
    return @{@"targetDevice": @"Previous named iPad", @"ignoreDisplayNames": @[],
             @"deviceSelectionMode": DeviceSelectionAutomatic, @"automaticConnectionMode": automaticMode};
}

static NSDictionary *DiscoveryResult(NSString *output) {
    return @{@"status": @0, @"output": [output dataUsingEncoding:NSUTF8StringEncoding]};
}

static void CheckAutomaticDeviceSelection(NSDictionary *physical, NSDictionary *internal, NSDictionary *empty) {
    NSString *firstName = @"  小王’s iPad $(literal); `name`  ";
    NSString *secondName = @"Other iPad";
    NSError *error = nil;
    NSDictionary *autoSettings = AutomaticDeviceSettings(AutomaticModeHeadless);
    Check([DeviceSelectionMode(@{}) isEqualToString:DeviceSelectionNamed], @"旧设置默认保留指定设备，不静默切换自动发现");
    Check(HasConfiguredDevice(@{@"targetDevice": @"", @"deviceSelectionMode": DeviceSelectionAutomatic}),
          @"自动发现无需填写设备名称");
    Check(!HasConfiguredDevice(@{@"targetDevice": @"", @"deviceSelectionMode": DeviceSelectionNamed}),
          @"指定设备仍必须填写名称");
    for (id invalid in @[@"unknown", @"", @1, @[], NSNull.null]) {
        Check(NormalizeSettings(@{@"deviceSelectionMode": invalid}, &error) == nil,
              @"设备选择方式只接受固定白名单，类型错误或未知值不能执行");
    }
    Check([DeviceNamesFromResult(DiscoveryResult([NSString stringWithFormat:@"%@\r\n%@\n", firstName, secondName]), &error)
           isEqual:@[firstName, secondName]], @"设备列表保留顺序、中文、首尾空格、引号和符号");
    Check([DeviceNamesFromResult(DiscoveryResult(@"\nFirst iPad\nFirst iPad\n   \nbad\tname\nSecond iPad\n"), &error)
           isEqual:@[@"First iPad", @"Second iPad"]], @"忽略无效名称和空行，去重但不改变首次出现顺序");
    Check([DeviceNamesFromResult(DiscoveryResult(@""), &error) count] == 0, @"成功查询但没有设备时返回空列表");
    Check(DeviceNamesFromResult(@{@"status": @2, @"output": [@"No devices" dataUsingEncoding:NSUTF8StringEncoding]}, &error) == nil,
          @"设备工具报错时不把错误文字当成设备名称");
    Check(DeviceNamesFromResult(@{@"status": @"0", @"output": NSData.data}, &error) == nil &&
          DeviceNamesFromResult(@{@"status": @0, @"output": @"invalid"}, &error) == nil,
          @"设备查询结果必须使用正确的状态和数据类型");
    unsigned char invalidUTF8[] = {0xff, 0xfe};
    Check(DeviceNamesFromResult(@{@"status": @0, @"output": [NSData dataWithBytes:invalidUTF8 length:2]}, &error) == nil,
          @"无法解码的设备列表不用于连接");
    NSMutableArray *manyNames = [NSMutableArray array];
    for (NSUInteger i = 0; i < 128; i++) [manyNames addObject:[NSString stringWithFormat:@"iPad %lu", (unsigned long)i]];
    Check([DeviceNamesFromResult(DiscoveryResult([manyNames componentsJoinedByString:@"\n"]), &error) count] == 128,
          @"设备列表允许有界数量的候选设备");
    [manyNames addObject:@"One more iPad"];
    Check(DeviceNamesFromResult(DiscoveryResult([manyNames componentsJoinedByString:@"\n"]), &error) == nil,
          @"过多设备时停止，不生成无界候选列表");
    Check(DeviceNamesFromResult(DiscoveryResult([@"\n" stringByPaddingToLength:300 withString:@"\n" startingAtIndex:0]), &error) == nil,
          @"异常大量空行同样受行数限制");

    DiscoveryTestServices *headless = [[DiscoveryTestServices alloc] initWithSettings:autoSettings];
    headless.snapshot = empty;
    headless.discoverableNames = @[firstName, secondName];
    Check(RunWorkflow(headless) == 0 && [headless.events isEqual:@[@"detect", @"connected-devices", @"discover", @"detect",
        @"BetterDisplay", @1.0, @[@"connect", firstName]]],
        @"自动发现连接第一台可用 iPad，仍先检查屏幕并在无屏时准备 BetterDisplay");
    Check([headless.settings[@"targetDevice"] isEqualToString:@"Previous named iPad"] &&
          UsesAutomaticDeviceSelection(headless.settings), @"运行时选中的设备不覆盖自动设置或上次手动填写的名称");
    DiscoveryTestServices *always = [[DiscoveryTestServices alloc] initWithSettings:AutomaticDeviceSettings(AutomaticModeAlways)];
    always.snapshot = internal;
    always.discoverableNames = @[firstName, secondName];
    Check(RunWorkflow(always) == 0 && [always.events isEqual:@[@"detect", @"connected-devices", @"discover", @"detect", @[@"connect", firstName]]],
          @"始终自动连接可在有内屏时自动选择设备，不启动 BetterDisplay 或等待");
    DiscoveryTestServices *blocked = [[DiscoveryTestServices alloc] initWithSettings:autoSettings];
    blocked.snapshot = physical;
    blocked.discoverableNames = @[firstName];
    Check(RunWorkflow(blocked) == 0 && [blocked.events isEqual:@[@"detect"]],
          @"无实体屏幕模式检测到实体屏幕后直接跳过，不查找设备");
    DiscoveryTestServices *disabled = [[DiscoveryTestServices alloc] initWithSettings:AutomaticDeviceSettings(AutomaticModeDisabled)];
    disabled.snapshot = empty;
    Check(RunWorkflow(disabled) == 0 && disabled.events.count == 0, @"禁止自动连接时不会发起自动发现");
    DiscoveryTestServices *notFound = [[DiscoveryTestServices alloc] initWithSettings:autoSettings];
    notFound.snapshot = empty;
    Check(RunDirectConnection(notFound) == 1 && [notFound.events isEqual:@[@"detect", @"connected-devices", @"discover"]] &&
          [notFound.lastMessage containsString:@"暂未发现"], @"手动连接没有可用设备时提示并停止，不启动 BetterDisplay 或尝试连接");
    DiscoveryTestServices *failed = [[DiscoveryTestServices alloc] initWithSettings:autoSettings];
    failed.snapshot = empty;
    failed.discoveryFails = YES;
    Check(RunDirectConnection(failed) == 1 && [failed.events isEqual:@[@"detect", @"connected-devices", @"discover"]] &&
          [failed.lastMessage isEqualToString:@"模拟查找失败"], @"手动连接发现设备失败时停止，不误连保存过的旧名称");
    DiscoveryTestServices *existing = [[DiscoveryTestServices alloc] initWithSettings:autoSettings];
    existing.snapshot = empty;
    existing.connectedNames = @[secondName];
    existing.discoverableNames = @[firstName];
    Check(RunWorkflow(existing) == 0 && [existing.events isEqual:@[@"detect", @"connected-devices", @"detect"]] &&
          [existing.targetDevice isEqualToString:secondName], @"已有随航连接时沿用当前设备，不重新发现或启动虚拟屏幕");
    DiscoveryTestServices *unknownConnection = [[DiscoveryTestServices alloc] initWithSettings:autoSettings];
    unknownConnection.snapshot = internal;
    unknownConnection.connectedQueryFails = YES;
    unknownConnection.discoverableNames = @[firstName];
    Check(RunDirectConnection(unknownConnection) == 0 &&
          [unknownConnection.events isEqual:@[@"detect", @"connected-devices", @"discover", @[@"connect", firstName]]],
          @"无法确认已有连接时仍可显式查找和手动连接，但不使用旧的固定名称");
    DiscoveryTestServices *disconnect = [[DiscoveryTestServices alloc] initWithSettings:autoSettings];
    disconnect.connectedNames = @[secondName];
    disconnect.discoverableNames = @[firstName];
    Check(RunDisconnection(disconnect) == 0 && [disconnect.events isEqual:@[@"connected-devices", @[@"disconnect", secondName]]],
          @"自动模式的断开只针对实际已连接设备，不选附近第一台或旧固定名称");
    DiscoveryTestServices *noConnection = [[DiscoveryTestServices alloc] initWithSettings:autoSettings];
    noConnection.discoverableNames = @[firstName];
    Check(RunDisconnection(noConnection) == 1 && [noConnection.events isEqual:@[@"connected-devices"]],
          @"没有已连接设备时断开不会发起查找、连接或其他设备的断开");
    noConnection.connectedQueryFails = YES;
    [noConnection.events removeAllObjects];
    Check(RunDisconnection(noConnection) == 1 && [noConnection.events isEqual:@[@"connected-devices"]] &&
          [noConnection.lastMessage containsString:@"无法确认"], @"状态查询失败时拒绝猜测断开目标");

    NSDictionary *connectedReport = @{@"available": @YES, @"connectedDeviceNames": @[secondName]};
    NSDictionary *state = ConnectionStatusForSettings(connectedReport, autoSettings);
    Check([state[@"state"] isEqualToString:@"connected"] && [state[@"targetDevice"] isEqualToString:secondName],
          @"自动模式状态显示实际连接名称，不显示保留的手动名称");
    Check([ConnectionStatusForSettings(@{@"available": @YES, @"connectedDeviceNames": @[]}, autoSettings)[@"state"]
           isEqualToString:@"disconnected"], @"自动发现未连接时仍是已配置状态");
    Check([ConnectionStatusForSettings(@{@"available": @NO}, autoSettings)[@"state"] isEqualToString:@"unknown"],
          @"自动模式的状态失败不误报为未连接");
    Check([ConnectionStatusForSettings(@{@"available": @YES, @"connectedDeviceNames": @[@12]}, autoSettings)[@"state"]
           isEqualToString:@"unknown"], @"自动模式也拒绝异常已连接设备名称");
    Check(![IgnoredDisplayNames(autoSettings) containsObject:@"Previous named iPad"],
          @"自动模式的屏幕判断不沿用旧固定名称");
    NSDictionary *sidecarScreen = GPU(@[@{@"_name": secondName}]);
    NSDictionary *classified = ClassifyDisplaysForSettings(sidecarScreen, autoSettings, connectedReport, &error);
    Check([classified[@"shouldStart"] boolValue] && [classified[@"physicalExternalDisplays"] count] == 0 &&
          [classified[@"ignoredVirtualDisplays"] count] == 1, @"自动模式也会排除实际已连接的 iPad，避免误当成实体屏幕");

    NSString *temporary = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *path = [temporary stringByAppendingPathComponent:@"settings.json"];
    NSDictionary *withoutName = @{@"targetDevice": @"", @"deviceSelectionMode": DeviceSelectionAutomatic,
        @"automaticConnectionMode": AutomaticModeHeadless};
    Check(SaveSettingsAtPath(withoutName, path, &error) && UsesAutomaticDeviceSelection(ReadSettingsAtPath(path, &error)),
          @"自动发现无需设备名称，也可保存并恢复");
    Check(SaveSettingsAtPath(autoSettings, path, &error) && [ReadSettingsAtPath(path, &error) isEqual:autoSettings],
          @"保存自动发现时保留手动名称和自动连接方式");
    NSMutableDictionary *namedAgain = [autoSettings mutableCopy];
    namedAgain[@"deviceSelectionMode"] = DeviceSelectionNamed;
    Check(SaveSettingsAtPath(namedAgain, path, &error) && !UsesAutomaticDeviceSelection(ReadSettingsAtPath(path, &error)) &&
          [ReadSettingsAtPath(path, &error)[@"targetDevice"] isEqualToString:@"Previous named iPad"],
          @"切回指定设备后可恢复原来的名称");
    [NSFileManager.defaultManager removeItemAtPath:temporary error:nil];

    DisplayMonitorFixture *monitorFixture = [DisplayMonitorFixture new];
    [monitorFixture setSnapshot:physical delay:0];
    DiscoveryTestServices *afterRemoval = [[DiscoveryTestServices alloc] initWithSettings:autoSettings];
    afterRemoval.snapshot = empty;
    afterRemoval.discoverableNames = @[firstName, secondName];
    __block int removalResult = -1;
    PhysicalDisplayMonitor *monitor = TestMonitor(monitorFixture, ^{ removalResult = RunWorkflow(afterRemoval); });
    [monitor start];
    Check(WaitForMonitor(^BOOL{ return monitor.hasBaseline && !monitor.scanRunning; }), @"建立自动发现设备的实体屏幕基线");
    [monitorFixture setSnapshot:empty delay:0];
    for (NSUInteger i = 0; i < 10; i++) [monitor displayConfigurationDidChange];
    Check(WaitForMonitor(^BOOL{ return removalResult == 0; }) &&
          [afterRemoval.events isEqual:@[@"detect", @"connected-devices", @"discover", @"detect", @"BetterDisplay", @1.0, @[@"connect", firstName]]],
          @"最后一屏断开后自动发现并连接第一台，重复通知不会重复执行");
    [monitor stop];
}
