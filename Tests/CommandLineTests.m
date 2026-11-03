//
//  Created by YueRuo on 2026/11/2.
//

// Exercise the same argument parser and connection dispatch used by the real executable.
// All display reports, device discovery and connection commands below are simulated.
static void CheckCommandLineConnection(NSDictionary *physical, NSDictionary *internal,
    NSDictionary *empty, NSDictionary *virtualScreen) {
    const char *connectArguments[] = {"HeadlessSidecarLogin", "--connect"};
    const char *automaticArguments[] = {"HeadlessSidecarLogin", "--run"};
    CommandLineMode directMode = ParseCommandLineMode(2, connectArguments);
    CommandLineMode automaticMode = ParseCommandLineMode(2, automaticArguments);
    Check(directMode == CommandLineModeDirectConnection && automaticMode == CommandLineModeAutomaticConnection,
        @"新的 --connect 入口与旧 --run 自动连接入口明确区分");

    for (NSString *savedMode in @[AutomaticModeHeadless, AutomaticModeAlways, AutomaticModeDisabled]) {
        for (NSDictionary *snapshot in @[physical, internal, empty, virtualScreen]) {
            NSDictionary *settings = @{@"targetDevice":TestTarget, @"automaticConnectionMode":savedMode};
            FakeServices *services = [[FakeServices alloc] initWithSettings:settings];
            services.snapshot = snapshot;
            NSArray *expected = [snapshot[@"needsBetterDisplay"] boolValue]
                ? @[@"detect", @"BetterDisplay", @1, @[@"connect", TestTarget]]
                : @[@"detect", @[@"connect", TestTarget]];
            Check(RunCommandLineConnection(directMode, services) == 0 && [services.events isEqual:expected] &&
                [services.settings isEqual:settings],
                @"--connect 在三种自动方式及内屏、外屏、无屏、虚拟屏幕下直接尝试连接，不改保存设置");
        }
    }
    FakeServices *disabled = [[FakeServices alloc] initWithSettings:@{
        @"targetDevice":TestTarget, @"automaticConnectionMode":AutomaticModeDisabled}];
    disabled.snapshot = empty;
    Check(RunCommandLineConnection(automaticMode, disabled) == 0 && disabled.events.count == 0,
        @"旧 --run 在禁止自动连接时仍保持待命，不因新参数改变行为");
    FakeServices *hasScreen = [[FakeServices alloc] initWithSettings:@{
        @"targetDevice":TestTarget, @"automaticConnectionMode":AutomaticModeHeadless}];
    hasScreen.snapshot = internal;
    Check(RunCommandLineConnection(automaticMode, hasScreen) == 0 && [hasScreen.events isEqual:@[@"detect"]],
        @"旧 --run 在无屏模式遇到实体屏幕仍按规则跳过");

    RetryTestServices *automaticSelection = RetryFixture(AutomaticModeDisabled, physical);
    NSString *target = @"小王's iPad $(literal); `name`";
    automaticSelection.lookupResults = @[@[target, @"Another iPad"]];
    Check(RunCommandLineConnection(directMode, automaticSelection) == 0 &&
        [automaticSelection.events.lastObject isEqual:@[@"connect",target]] &&
        automaticSelection.lookupTimes.count == 1 && automaticSelection.retryWaits.count == 0 &&
        automaticSelection.discoveryDeadline == 0,
        @"快捷指令直接连接自动发现的第一台设备，完整名称作为独立参数，不进入自动重试");
    RetryTestServices *notFound = RetryFixture(AutomaticModeDisabled, physical);
    Check(RunCommandLineConnection(directMode, notFound) == 1 && notFound.lookupTimes.count == 1 &&
        notFound.retryWaits.count == 0 && !HasConnectionAttempt(notFound),
        @"直接连接没发现设备时返回失败，不误报连接成功或无限等待");
    RetryTestServices *alreadyConnected = RetryFixture(AutomaticModeDisabled, empty);
    alreadyConnected.connectedNames = @[target];
    Check(RunCommandLineConnection(directMode, alreadyConnected) == 0 && alreadyConnected.lookupTimes.count == 0 &&
        !HasConnectionAttempt(alreadyConnected) && ![alreadyConnected.events containsObject:@"BetterDisplay"],
        @"已有随航连接时沿用当前设备，不重复建立连接");
    FakeServices *failed = [[FakeServices alloc] initWithSettings:@{
        @"targetDevice":TestTarget, @"automaticConnectionMode":AutomaticModeDisabled}];
    failed.snapshot = internal;
    failed.failConnect = YES;
    Check(RunCommandLineConnection(directMode, failed) == 1 && [failed.lastMessage isEqual:@"模拟脚本失败"],
        @"快捷指令能够收到实际连接失败的非零退出状态");
    FakeServices *missingDisplay = [FakeServices new];
    missingDisplay.snapshot = empty;
    missingDisplay.failLaunch = YES;
    Check(RunCommandLineConnection(directMode, missingDisplay) == 1 &&
        [missingDisplay.events isEqual:@[@"detect",@"BetterDisplay"]],
        @"无屏且 BetterDisplay 准备失败时返回错误，不强行执行后续连接");
    FakeServices *badDisplay = [FakeServices new];
    Check(RunCommandLineConnection(directMode, badDisplay) == 1 && [badDisplay.events isEqual:@[@"detect"]],
        @"新入口沿用屏幕读取失败处理，不把失败当作无需虚拟屏幕");
    FakeServices *unconfigured = [[FakeServices alloc] initWithSettings:@{
        @"targetDevice":@"", @"automaticConnectionMode":AutomaticModeDisabled}];
    Check(RunCommandLineConnection(directMode, unconfigured) == 1 && unconfigured.events.count == 0,
        @"禁止自动连接且尚未配置设备时，直接连接仍要求先保存设备选项");

    for (NSArray<NSString *> *arguments in @[@[@"--connect",@"Extra iPad"], @[@"--connect",@"--run"],
        @[@"--run",@"--connect"], @[@"--connect=Other iPad"], @[@"--CONNECT"], @[@"--connect;touch anything"]]) {
        const char *argv[4] = {"HeadlessSidecarLogin", NULL, NULL, NULL};
        for (NSUInteger i = 0; i < arguments.count; i++) argv[i + 1] = arguments[i].UTF8String;
        CommandLineMode mode = ParseCommandLineMode((int)arguments.count + 1, argv);
        FakeServices *services = [FakeServices new];
        services.snapshot = empty;
        Check(mode == CommandLineModeInvalid && RunCommandLineConnection(mode, services) == 2 && services.events.count == 0,
            @"未知、拼接、混用和额外设备参数被拒绝，不意外执行连接或覆盖目标");
    }
    const char *missingArgument[] = {"HeadlessSidecarLogin", NULL};
    Check(ParseCommandLineMode(0,NULL) == CommandLineModeInvalid &&
        ParseCommandLineMode(2,missingArgument) == CommandLineModeInvalid, @"缺少有效参数时安全返回错误");
    const char *gui[] = {"HeadlessSidecarLogin"};
    Check(ParseCommandLineMode(1,gui) == CommandLineModeGUI, @"无参数启动仍进入菜单栏 App");
    for (NSArray *entry in @[@[@"--settings",@(CommandLineModeSettings)], @[@"--check",@(CommandLineModeCheck)],
        @[@"--status",@(CommandLineModeStatus)]]) {
        const char *argv[] = {"HeadlessSidecarLogin",[entry[0] UTF8String]};
        CommandLineMode mode = ParseCommandLineMode(2,argv);
        FakeServices *services = [FakeServices new];
        Check(mode == [entry[1] unsignedIntegerValue] && RunCommandLineConnection(mode,services) == 2 && services.events.count == 0,
            @"旧设置与只读入口仍独立，不因新连接参数意外进入连接流程");
    }
}
