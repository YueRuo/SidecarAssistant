//
//  Created by YueRuo on 2026/11/2.
//

// Included after FakeServices in tests.m. These tests use fake reports and never touch displays.
@interface DisplayMonitorFixture : NSObject {
    NSDictionary *_snapshot;
    NSTimeInterval _delay;
    NSUInteger _readCount;
    NSUInteger _activeReaders;
    NSUInteger _peakReaders;
}
- (void)setSnapshot:(NSDictionary *)snapshot delay:(NSTimeInterval)delay;
- (NSDictionary *)readSnapshot;
@property (nonatomic, readonly) NSUInteger readCount;
@property (nonatomic, readonly) NSUInteger peakReaders;
@end

@implementation DisplayMonitorFixture
- (void)setSnapshot:(NSDictionary *)snapshot delay:(NSTimeInterval)delay {
    @synchronized (self) { _snapshot = snapshot; _delay = delay; }
}
- (NSDictionary *)readSnapshot {
    NSDictionary *snapshot;
    NSTimeInterval delay;
    @synchronized (self) {
        snapshot = _snapshot;
        delay = _delay;
        _readCount++;
        _activeReaders++;
        _peakReaders = MAX(_peakReaders, _activeReaders);
    }
    if (delay) [NSThread sleepForTimeInterval:delay];
    @synchronized (self) { _activeReaders--; }
    return snapshot;
}
- (NSUInteger)readCount { @synchronized (self) { return _readCount; } }
- (NSUInteger)peakReaders { @synchronized (self) { return _peakReaders; } }
@end

static BOOL WaitForMonitor(BOOL (^condition)(void)) {
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 3;
    while (!condition() && NSProcessInfo.processInfo.systemUptime < deadline)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.005, false);
    return condition();
}

static void DrainMonitorEvents(NSTimeInterval interval) {
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, interval, false);
}

static PhysicalDisplayMonitor *TestMonitor(DisplayMonitorFixture *fixture, void (^handler)(void)) {
    return [[PhysicalDisplayMonitor alloc] initWithReader:^NSDictionary *{
        return [fixture readSnapshot];
    } removalHandler:handler settleDelay:0.02];
}

static void CheckPhysicalDisplayMonitor(NSDictionary *physical, NSDictionary *internal,
                                        NSDictionary *empty, NSDictionary *virtualScreen) {
    Check(PhysicalDisplayPresence(@{}) == nil && PhysicalDisplayPresence(nil) == nil,
          @"异常屏幕报告不能被当成没有实体屏幕");
    Check(PhysicalDisplayPresence(physical).boolValue && PhysicalDisplayPresence(internal).boolValue,
          @"监听同时识别外屏和内屏");
    Check(!PhysicalDisplayPresence(empty).boolValue && !PhysicalDisplayPresence(virtualScreen).boolValue,
          @"独立虚拟屏幕不计入硬件屏幕状态");

    DisplayMonitorFixture *fixture = [DisplayMonitorFixture new];
    [fixture setSnapshot:physical delay:0];
    __block NSUInteger removals = 0;
    PhysicalDisplayMonitor *monitor = TestMonitor(fixture, ^{ removals++; });
    [monitor start];
    Check(WaitForMonitor(^BOOL{ return monitor.hasBaseline && !monitor.scanRunning; }) && removals == 0,
          @"启动监听只记录基线，不把首次检查当成拔屏");
    [fixture setSnapshot:empty delay:0];
    for (NSUInteger i = 0; i < 30; i++) [monitor displayConfigurationDidChange];
    Check(WaitForMonitor(^BOOL{ return removals == 1; }), @"最后一块实体屏幕断开后触发一次");
    Check(fixture.readCount == 2 && fixture.peakReaders == 1, @"三十个连续通知合并为一次串行屏幕检查");
    NSUInteger idleReads = fixture.readCount;
    DrainMonitorEvents(0.1);
    Check(fixture.readCount == idleReads && removals == 1, @"空闲时没有定时轮询或重复连接");

    [fixture setSnapshot:virtualScreen delay:0];
    [monitor displayConfigurationDidChange];
    Check(WaitForMonitor(^BOOL{ return fixture.readCount > idleReads && !monitor.scanRunning; }) && removals == 1,
          @"无实体屏幕时增加虚拟屏幕，不会再次触发连接");
    [fixture setSnapshot:physical delay:0];
    [monitor displayConfigurationDidChange];
    Check(WaitForMonitor(^BOOL{ return monitor.physicalDisplayPresent && !monitor.scanRunning; }) && removals == 1,
          @"接入实体屏幕只更新状态，不触发连接或断开");
    NSUInteger modeReads = fixture.readCount;
    [monitor displayConfigurationDidChange];
    Check(WaitForMonitor(^BOOL{ return fixture.readCount > modeReads && !monitor.scanRunning; }) && removals == 1,
          @"分辨率等变化但实体屏幕仍在时，不触发连接");

    NSDictionary *twoPhysical = @{@"builtInDisplays": @[], @"physicalExternalDisplays":
        @[physical[@"physicalExternalDisplays"][0], physical[@"physicalExternalDisplays"][0]]};
    [fixture setSnapshot:twoPhysical delay:0];
    NSUInteger multiReads = fixture.readCount;
    [monitor displayConfigurationDidChange];
    Check(WaitForMonitor(^BOOL{ return fixture.readCount > multiReads && !monitor.scanRunning; }), @"记录多实体屏幕状态");
    [fixture setSnapshot:physical delay:0];
    multiReads = fixture.readCount;
    [monitor displayConfigurationDidChange];
    Check(WaitForMonitor(^BOOL{ return fixture.readCount > multiReads && !monitor.scanRunning; }) && removals == 1,
          @"两块实体屏幕减少到一块时，不触发");
    [fixture setSnapshot:empty delay:0];
    [monitor displayConfigurationDidChange];
    Check(WaitForMonitor(^BOOL{ return removals == 2; }), @"之后最后一块实体屏幕断开，重新触发一次");

    NSDictionary *both = @{@"builtInDisplays": internal[@"builtInDisplays"],
                           @"physicalExternalDisplays": physical[@"physicalExternalDisplays"]};
    [fixture setSnapshot:both delay:0];
    [monitor displayConfigurationDidChange];
    Check(WaitForMonitor(^BOOL{ return monitor.physicalDisplayPresent && !monitor.scanRunning; }), @"记录内屏和外屏共存状态");
    [fixture setSnapshot:internal delay:0];
    NSUInteger internalReads = fixture.readCount;
    [monitor displayConfigurationDidChange];
    Check(WaitForMonitor(^BOOL{ return fixture.readCount > internalReads && !monitor.scanRunning; }) && removals == 2,
          @"拔掉外屏但仍有内屏时，不触发");
    [fixture setSnapshot:nil delay:0];
    NSUInteger failureReads = fixture.readCount;
    [monitor displayConfigurationDidChange];
    Check(WaitForMonitor(^BOOL{ return fixture.readCount > failureReads && !monitor.scanRunning; }) &&
          monitor.physicalDisplayPresent && removals == 2, @"检查失败保留已知状态，不误触发");
    [fixture setSnapshot:empty delay:0];
    [monitor displayConfigurationDidChange];
    Check(WaitForMonitor(^BOOL{ return removals == 3; }), @"恢复有效检查后才确认全部实体屏幕已断开");
    [monitor stop];
    NSUInteger stoppedReads = fixture.readCount;
    [monitor displayConfigurationDidChange];
    DrainMonitorEvents(0.08);
    Check(fixture.readCount == stoppedReads, @"停止监听后忽略后续通知");

    DisplayMonitorFixture *busyFixture = [DisplayMonitorFixture new];
    [busyFixture setSnapshot:physical delay:0];
    __block NSUInteger busyRemovals = 0;
    PhysicalDisplayMonitor *busyMonitor = TestMonitor(busyFixture, ^{ busyRemovals++; });
    [busyMonitor start];
    Check(WaitForMonitor(^BOOL{ return busyMonitor.hasBaseline && !busyMonitor.scanRunning; }), @"建立忙碌场景基线");
    [busyMonitor setOperationBusy:YES];
    [busyFixture setSnapshot:empty delay:0];
    [busyMonitor displayConfigurationDidChange];
    Check(WaitForMonitor(^BOOL{ return busyMonitor.pendingRemoval && !busyMonitor.scanRunning; }) && busyRemovals == 0,
          @"其他操作进行中时记住拔屏，不并发连接");
    [busyMonitor setOperationBusy:NO];
    Check(WaitForMonitor(^BOOL{ return busyRemovals == 1; }) && busyFixture.readCount == 3,
          @"当前操作结束后重新确认无屏，再触发一次");
    [busyFixture setSnapshot:physical delay:0];
    [busyMonitor displayConfigurationDidChange];
    Check(WaitForMonitor(^BOOL{ return busyMonitor.physicalDisplayPresent && !busyMonitor.scanRunning; }), @"重新接回实体屏幕");
    [busyMonitor setOperationBusy:YES];
    [busyFixture setSnapshot:empty delay:0];
    [busyMonitor displayConfigurationDidChange];
    Check(WaitForMonitor(^BOOL{ return busyMonitor.pendingRemoval && !busyMonitor.scanRunning; }), @"忙碌期间保留待处理拔屏");
    [busyFixture setSnapshot:physical delay:0];
    [busyMonitor displayConfigurationDidChange];
    Check(WaitForMonitor(^BOOL{ return !busyMonitor.pendingRemoval && busyMonitor.physicalDisplayPresent && !busyMonitor.scanRunning; }),
          @"等待期间重新插屏时，取消待处理连接");
    [busyMonitor setOperationBusy:NO];
    DrainMonitorEvents(0.08);
    Check(busyRemovals == 1, @"重新插屏后不会补发旧的自动连接");
    [busyMonitor stop];

    DisplayMonitorFixture *slowFixture = [DisplayMonitorFixture new];
    [slowFixture setSnapshot:physical delay:0];
    __block NSUInteger slowRemovals = 0;
    PhysicalDisplayMonitor *slowMonitor = TestMonitor(slowFixture, ^{ slowRemovals++; });
    [slowMonitor start];
    Check(WaitForMonitor(^BOOL{ return slowMonitor.hasBaseline && !slowMonitor.scanRunning; }), @"建立慢速检查场景基线");
    [slowFixture setSnapshot:empty delay:0.1];
    [slowMonitor displayConfigurationDidChange];
    Check(WaitForMonitor(^BOOL{ return slowMonitor.scanRunning && slowFixture.readCount == 2; }), @"拔屏检查正在后台执行");
    [slowFixture setSnapshot:physical delay:0];
    for (NSUInteger i = 0; i < 30; i++) [slowMonitor displayConfigurationDidChange];
    Check(WaitForMonitor(^BOOL{ return slowFixture.readCount >= 3 && !slowMonitor.scanRunning && slowMonitor.physicalDisplayPresent; }) &&
          slowRemovals == 0 && slowFixture.peakReaders == 1, @"检查期间重新插屏时不采用过期结果，也不并发启动检查");
    [slowFixture setSnapshot:empty delay:0.1];
    [slowMonitor displayConfigurationDidChange];
    Check(WaitForMonitor(^BOOL{ return slowMonitor.scanRunning; }), @"停止监听前已有正在执行的检查");
    [slowMonitor stop];
    Check(WaitForMonitor(^BOOL{ return !slowMonitor.scanRunning; }) && slowRemovals == 0,
          @"停止监听后正在执行的检查不会回调连接");

    DisplayMonitorFixture *unknownFixture = [DisplayMonitorFixture new];
    __block NSUInteger unknownRemovals = 0;
    PhysicalDisplayMonitor *unknownMonitor = TestMonitor(unknownFixture, ^{ unknownRemovals++; });
    [unknownMonitor start];
    Check(WaitForMonitor(^BOOL{ return unknownFixture.readCount == 1 && !unknownMonitor.scanRunning; }) && !unknownMonitor.hasBaseline,
          @"首次检查失败时不猜测硬件状态");
    [unknownFixture setSnapshot:empty delay:0];
    [unknownMonitor displayConfigurationDidChange];
    Check(WaitForMonitor(^BOOL{ return unknownMonitor.hasBaseline && !unknownMonitor.scanRunning; }) && unknownRemovals == 0,
          @"没有先前实体屏幕记录时，首次发现无屏不算拔屏");
    [unknownMonitor stop];

    for (NSString *mode in @[AutomaticModeHeadless, AutomaticModeAlways, AutomaticModeDisabled]) {
        DisplayMonitorFixture *modeFixture = [DisplayMonitorFixture new];
        [modeFixture setSnapshot:physical delay:0];
        FakeServices *services = [[FakeServices alloc] initWithSettings:@{@"targetDevice": TestTarget,
            @"automaticConnectionMode": mode}];
        services.snapshot = empty;
        __block int code = -1;
        PhysicalDisplayMonitor *modeMonitor = TestMonitor(modeFixture, ^{ code = RunWorkflow(services); });
        [modeMonitor start];
        Check(WaitForMonitor(^BOOL{ return modeMonitor.hasBaseline && !modeMonitor.scanRunning; }), @"建立各自动连接方式的拔屏基线");
        [modeFixture setSnapshot:empty delay:0];
        [modeMonitor displayConfigurationDidChange];
        Check(WaitForMonitor(^BOOL{ return code == 0; }), @"拔屏后可进入已保存的自动连接方式");
        if ([mode isEqualToString:AutomaticModeDisabled])
            Check(services.events.count == 0, @"禁止自动连接时拔屏也不执行连接流程");
        else Check([services.events isEqual:@[@"detect", @"detect", @"BetterDisplay", @1.0, @[@"connect", TestTarget]]],
                   @"拔屏自动连接仍保留屏幕检查、BetterDisplay 和 1 秒等待顺序");
        [modeMonitor stop];
    }
}
