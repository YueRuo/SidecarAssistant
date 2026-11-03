//
//  Created by YueRuo on 2026/11/2.
//

// Virtual time exercises the real workflow without waiting two minutes or using real devices/settings.
@interface RetryTestServices : DiscoveryTestServices
@property (nonatomic) NSTimeInterval clock;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *lookupTimes;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *retryWaits;
@property (nonatomic, copy) NSArray *lookupResults;
@property (nonatomic) NSTimeInterval lookupDuration;
@property (nonatomic) NSTimeInterval detectionDuration;
@property (nonatomic) NSTimeInterval physicalAt;
@property (nonatomic, copy) NSDictionary *physicalSnapshot;
@property (nonatomic) BOOL settingsChanged;
@property (nonatomic) BOOL connectionFails;
@property (nonatomic, copy) void (^afterRetryWait)(RetryTestServices *services);
@property (nonatomic, copy) void (^afterLookup)(RetryTestServices *services);
@end

@implementation RetryTestServices
- (instancetype)initWithSettings:(NSDictionary *)settings {
    if ((self = [super initWithSettings:settings])) {
        _clock = 1000;
        _lookupTimes = [NSMutableArray array];
        _retryWaits = [NSMutableArray array];
    }
    return self;
}
- (NSTimeInterval)discoveryTime { return self.clock; }
- (BOOL)automaticDiscoveryStillAllowed:(NSError **)error {
    if (self.cancelDiscoveryRequested || self.settingsChanged) {
        if (error) *error = Failure(self.settingsChanged ? @"设置已更改，已停止本次自动查找。" : @"已停止本次自动查找。");
        return NO;
    }
    return YES;
}
- (NSDictionary *)detect:(NSError **)error {
    if (self.discoveryDeadline > 0)
        self.clock += MIN(self.detectionDuration, MAX(0, self.discoveryDeadline - self.clock));
    if (self.physicalAt > 0 && self.clock >= self.physicalAt) {
        [self.events addObject:@"detect"];
        return self.physicalSnapshot;
    }
    return [super detect:error];
}
- (NSArray<NSString *> *)availableDeviceNames:(NSError **)error {
    [self.events addObject:@"discover"];
    [self.lookupTimes addObject:@(self.clock - 1000)];
    NSTimeInterval remaining = self.discoveryDeadline > 0 ? MAX(0, self.discoveryDeadline - self.clock) : 15;
    self.clock += MIN(self.lookupDuration, MIN(15, remaining));
    NSUInteger index = self.lookupTimes.count - 1;
    id result = index < self.lookupResults.count ? self.lookupResults[index] : @[];
    if (self.afterLookup) self.afterLookup(self);
    if (result == NSNull.null) {
        if (error) *error = Failure(@"模拟短暂查询失败");
        return nil;
    }
    return result;
}
- (BOOL)waitForDiscoveryRetry:(NSTimeInterval)seconds {
    [self.retryWaits addObject:@(seconds)];
    self.clock += MIN(seconds, MAX(0, self.discoveryDeadline - self.clock));
    if (self.afterRetryWait) self.afterRetryWait(self);
    return !self.cancelDiscoveryRequested;
}
- (NSDictionary *)executeSidecarArguments:(NSArray<NSString *> *)arguments error:(NSError **)error {
    (void)error;
    [self.events addObject:arguments];
    return @{@"status": self.connectionFails ? @2 : @0};
}
@end

static RetryTestServices *RetryFixture(NSString *mode, NSDictionary *snapshot) {
    RetryTestServices *services = [[RetryTestServices alloc] initWithSettings:AutomaticDeviceSettings(mode)];
    services.snapshot = snapshot;
    return services;
}

static BOOL HasConnectionAttempt(RetryTestServices *services) {
    for (id event in services.events)
        if ([event isKindOfClass:NSArray.class] && [[event firstObject] isEqual:@"connect"]) return YES;
    return NO;
}

static void CheckDiscoveryRetries(NSDictionary *physical, NSDictionary *internal, NSDictionary *empty) {
    NSString *target = @"新 iPad's Name";
    RetryTestServices *first = RetryFixture(AutomaticModeHeadless, empty);
    first.lookupResults = @[@[target]];
    Check(RunWorkflow(first) == 0 && [first.lookupTimes isEqual:@[@0]] && first.retryWaits.count == 0 &&
        [first.events.lastObject isEqual:@[@"connect", target]], @"首次发现立即结束查找，只连接一次");
    Check([first.events isEqual:@[@"detect", @"connected-devices", @"discover", @"detect", @"BetterDisplay", @1, @[@"connect", target]]],
        @"发现后再次确认屏幕，再启动 BetterDisplay 并等待一秒，不混入重试等待");

    for (NSUInteger failures = 1; failures <= 3; failures++) {
        RetryTestServices *later = RetryFixture(AutomaticModeAlways, internal);
        NSMutableArray *results = [NSMutableArray array];
        for (NSUInteger i = 0; i < failures; i++) [results addObject:@[]];
        [results addObject:@[target, @"Second iPad"]];
        later.lookupResults = results;
        NSArray *expectedTimes = @[@0, @4, @10, @18];
        NSArray *expectedWaits = @[@4, @6, @8];
        Check(RunWorkflow(later) == 0 &&
            [later.lookupTimes isEqual:[expectedTimes subarrayWithRange:NSMakeRange(0, failures + 1)]] &&
            [later.retryWaits isEqual:[expectedWaits subarrayWithRange:NSMakeRange(0, failures)]] &&
            [later.events.lastObject isEqual:@[@"connect", target]], @"未发现时依次等四秒、六秒、八秒，找到后不再重试");
        Check(![later.events containsObject:@"BetterDisplay"], @"始终连接在有实体屏幕时允许重试，但无需 BetterDisplay");
    }

    RetryTestServices *timeout = RetryFixture(AutomaticModeHeadless, empty);
    Check(RunWorkflow(timeout) == 1 && timeout.clock == 1120 && timeout.lookupTimes.count == 16 &&
        [timeout.lastMessage containsString:@"2 分钟"] && timeout.discoveryDeadline == 0 &&
        !HasConnectionAttempt(timeout) && ![timeout.events containsObject:@"BetterDisplay"],
        @"未发现设备时两分钟结束，最多十六次查找，不启动虚拟屏幕或连接");
    Check([timeout.lookupTimes isEqual:@[@0,@4,@10,@18,@26,@34,@42,@50,@58,@66,@74,@82,@90,@98,@106,@114]] &&
        [timeout.retryWaits isEqual:@[@4,@6,@8,@8,@8,@8,@8,@8,@8,@8,@8,@8,@8,@8,@8,@6]],
        @"后续固定八秒间隔，最后等待截断至截止时间，不在第一百二十秒发起新查找");

    RetryTestServices *slow = RetryFixture(AutomaticModeAlways, internal);
    slow.lookupDuration = 15;
    Check(RunWorkflow(slow) == 1 && slow.clock == 1120 &&
        [slow.lookupTimes isEqual:@[@0,@19,@40,@63,@86,@109]] && !HasConnectionAttempt(slow),
        @"查询耗时计入两分钟，总预算限制最后一次查询，非仅累计等待时间");
    RetryTestServices *slowScreens = RetryFixture(AutomaticModeAlways, internal);
    slowScreens.detectionDuration = 20;
    Check(RunWorkflow(slowScreens) == 1 && slowScreens.clock == 1120 &&
        [slowScreens.lookupTimes isEqual:@[@0,@24,@50,@78,@106]] && !HasConnectionAttempt(slowScreens),
        @"重试前的屏幕检查也占用查找预算，检查到期后不再发起设备查询");
    RetryTestServices *late = RetryFixture(AutomaticModeAlways, internal);
    late.lookupDuration = 15;
    late.lookupResults = @[@[],@[],@[],@[],@[],@[target]];
    Check(RunWorkflow(late) == 1 && late.clock == 1120 && !HasConnectionAttempt(late),
        @"截止时间才返回的候选设备不继续连接");

    RetryTestServices *temporaryFailure = RetryFixture(AutomaticModeAlways, internal);
    temporaryFailure.lookupResults = @[NSNull.null, @[target]];
    Check(RunWorkflow(temporaryFailure) == 0 && [temporaryFailure.retryWaits isEqual:@[@4]] && HasConnectionAttempt(temporaryFailure),
        @"开机时设备查询短暂失败同样按有界策略重试");
    RetryTestServices *connected = RetryFixture(AutomaticModeHeadless, empty);
    connected.connectedNames = @[target];
    Check(RunWorkflow(connected) == 0 && connected.lookupTimes.count == 0 && connected.retryWaits.count == 0 &&
        !HasConnectionAttempt(connected) && ![connected.events containsObject:@"BetterDisplay"], @"已有随航连接时沿用当前设备，不进入重试");

    for (NSDictionary *screen in @[empty, internal, physical]) {
        RetryTestServices *disabled = RetryFixture(AutomaticModeDisabled, screen);
        Check(RunWorkflow(disabled) == 0 && disabled.events.count == 0 && disabled.retryWaits.count == 0 &&
            disabled.discoveryDeadline == 0, @"禁止自动连接时无屏、有内屏和有外屏均完全跳过查找重试");
    }
    for (NSDictionary *screen in @[internal, physical]) {
        RetryTestServices *blocked = RetryFixture(AutomaticModeHeadless, screen);
        Check(RunWorkflow(blocked) == 0 && [blocked.events isEqual:@[@"detect"]] && blocked.retryWaits.count == 0 &&
            blocked.discoveryDeadline == 0, @"无实体屏幕模式当前有内屏或外屏时不进入重试预算");
    }
    RetryTestServices *reattached = RetryFixture(AutomaticModeHeadless, empty);
    reattached.physicalAt = 1004;
    reattached.physicalSnapshot = physical;
    reattached.lookupResults = @[@[], @[target]];
    Check(RunWorkflow(reattached) == 0 && [reattached.lookupTimes isEqual:@[@0]] &&
        [reattached.retryWaits isEqual:@[@4]] && !HasConnectionAttempt(reattached) &&
        [reattached.lastMessage containsString:@"屏幕"], @"等待期间接回实体屏幕，下一轮查找前停止");
    RetryTestServices *duringLookup = RetryFixture(AutomaticModeHeadless, empty);
    duringLookup.lookupResults = @[@[target]];
    duringLookup.lookupDuration = 1;
    duringLookup.physicalAt = 1001;
    duringLookup.physicalSnapshot = internal;
    Check(RunWorkflow(duringLookup) == 0 && !HasConnectionAttempt(duringLookup) &&
        ![duringLookup.events containsObject:@"BetterDisplay"], @"查找过程中出现实体屏幕，发现设备后仍跳过连接");
    RetryTestServices *screenFailure = RetryFixture(AutomaticModeHeadless, empty);
    screenFailure.afterRetryWait = ^(RetryTestServices *services) { services.snapshot = nil; };
    Check(RunWorkflow(screenFailure) == 1 && screenFailure.lookupTimes.count == 1 &&
        !HasConnectionAttempt(screenFailure), @"无法重新确认屏幕时停止，不猜测为无实体屏幕");

    RetryTestServices *changed = RetryFixture(AutomaticModeHeadless, empty);
    changed.afterRetryWait = ^(RetryTestServices *services) { services.settingsChanged = YES; };
    Check(RunWorkflow(changed) == 0 && changed.lookupTimes.count == 1 && [changed.lastMessage containsString:@"设置已更改"] &&
        !HasConnectionAttempt(changed), @"等待期间保存设置发生变化会停止原查找");
    RetryTestServices *changedAtEnd = RetryFixture(AutomaticModeHeadless, empty);
    changedAtEnd.afterRetryWait = ^(RetryTestServices *services) { if (services.clock >= 1120) services.settingsChanged = YES; };
    Check(RunWorkflow(changedAtEnd) == 0 && [changedAtEnd.lastMessage containsString:@"设置已更改"],
        @"最后一段等待中的设置变化同样被识别，不误报为超时");
    RetryTestServices *cancelled = RetryFixture(AutomaticModeHeadless, empty);
    cancelled.afterRetryWait = ^(RetryTestServices *services) { services.cancelDiscoveryRequested = YES; };
    Check(RunWorkflow(cancelled) == 0 && cancelled.lookupTimes.count == 1 && !HasConnectionAttempt(cancelled) &&
        [cancelled.lastMessage containsString:@"已停止"], @"主动停止查找后不再查询或连接");
    RetryTestServices *cancelDuringLookup = RetryFixture(AutomaticModeHeadless, empty);
    cancelDuringLookup.lookupResults = @[@[target]];
    cancelDuringLookup.afterLookup = ^(RetryTestServices *services) { services.cancelDiscoveryRequested = YES; };
    Check(RunWorkflow(cancelDuringLookup) == 0 && !HasConnectionAttempt(cancelDuringLookup),
        @"查找执行中点击停止，即使随后找到设备也不连接");

    NSDictionary *namedSettings = @{@"targetDevice":target, @"automaticConnectionMode":AutomaticModeHeadless};
    RetryTestServices *named = [[RetryTestServices alloc] initWithSettings:namedSettings];
    named.snapshot = empty;
    named.lookupResults = @[@[@"Unrelated iPad"], @[@"Unrelated iPad", target]];
    Check(RunWorkflow(named) == 0 && [named.retryWaits isEqual:@[@4]] &&
        [named.events.lastObject isEqual:@[@"connect",target]], @"指定设备的自动连接也能等待发现，只匹配已保存的名称");
    RetryTestServices *manual = RetryFixture(AutomaticModeHeadless, empty);
    Check(RunDirectConnection(manual) == 1 && manual.lookupTimes.count == 1 && manual.retryWaits.count == 0 &&
        manual.discoveryDeadline == 0, @"手动连接只查找一次，不进入自动连接的重试流程");
    RetryTestServices *connectFailure = RetryFixture(AutomaticModeHeadless, empty);
    connectFailure.lookupResults = @[@[target]];
    connectFailure.connectionFails = YES;
    Check(RunWorkflow(connectFailure) == 1 && connectFailure.lookupTimes.count == 1 && connectFailure.retryWaits.count == 0,
        @"找到设备后连接失败不触发发现重试或重复连接");
    NSTimeInterval now = ContinuousTimeSeconds();
    Check(TimeBudgetRemaining(0, 15) == 15 && TimeBudgetRemaining(now - 1, 15) == 0 &&
        TimeBudgetRemaining(now + 100, 15) == 15 && TimeBudgetRemaining(now + 0.25, 15) <= 0.25,
        @"实际进程超时上限按连续时钟和剩余预算收紧");
}
