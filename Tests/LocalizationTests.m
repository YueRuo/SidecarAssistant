//
//  Created by YueRuo on 2026/11/2.
//

static NSArray<NSString *> *LocalizationFormatTokens(NSString *text) {
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:
        @"%(?:[0-9]+\\$)?[-+#0 ]*(?:[0-9]+|\\*)?(?:\\.(?:[0-9]+|\\*))?(?:hh|ll|[hljztL])?[@diuoxXfFeEgGaAcCsSp%]"
        options:0 error:nil];
    NSMutableArray *tokens = [NSMutableArray array];
    for (NSTextCheckingResult *match in [regex matchesInString:text options:0 range:NSMakeRange(0,text.length)])
        [tokens addObject:[text substringWithRange:match.range]];
    return tokens;
}

static void CheckLocalization(NSDictionary *physical, NSDictionary *internal, NSDictionary *empty) {
    (void)AppLanguagePreferenceKey;
    for (NSArray *test in @[
        @[AppLanguageSystem,@[@"zh-Hans-CN",@"en-US"],AppLanguageChinese],
        @[AppLanguageSystem,@[@"zh-Hant-TW"],AppLanguageChinese],
        @[AppLanguageSystem,@[@"en-GB",@"zh-Hans"],AppLanguageEnglish],
        @[AppLanguageSystem,@[@"fr-FR",@"zh_CN"],AppLanguageChinese],
        @[AppLanguageSystem,@[@"fr-FR"],AppLanguageEnglish],
        @[AppLanguageSystem,@[],AppLanguageEnglish],
        @[AppLanguageEnglish,@[@"zh-Hans"],AppLanguageEnglish],
        @[AppLanguageChinese,@[@"en-US"],AppLanguageChinese],
        @[@42,@[@"zh-Hans"],AppLanguageChinese],
        @[@"../../invalid",@[@"en-US"],AppLanguageEnglish],
        @[AppLanguageSystem,@[NSNull.null,@12,@"en_US"],AppLanguageEnglish]]) {
        Check([ResolveAppLanguage(test[0],test[1]) isEqual:test[2]],
            @"默认系统语言、地区变体、明确选择及不支持的系统语言均使用确定的中文或英文");
    }
    Check([NormalizeLanguagePreference(nil) isEqual:AppLanguageSystem] &&
        AppBundleForLanguage(@"../../invalid") == nil, @"缺省偏好跟随系统，资源目录只允许固定语言白名单");
    NSDictionary *tables = @{};
    NSMutableDictionary *loaded = [NSMutableDictionary dictionary];
    for (NSString *language in @[AppLanguageChinese,AppLanguageEnglish]) {
        NSURL *url = [AppBundleForLanguage(language) URLForResource:@"Localizable" withExtension:@"strings"];
        NSString *contents = url ? [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil] : nil;
        NSDictionary *table = contents.propertyListFromStringsFileFormat;
        Check([table isKindOfClass:NSDictionary.class] && table.count > 190, @"实际 App bundle 中完整打包中英文文案资源");
        if (table) loaded[language] = table;
    }
    tables = loaded;
    NSDictionary *zh = tables[AppLanguageChinese], *en = tables[AppLanguageEnglish];
    Check([[NSSet setWithArray:zh.allKeys] isEqual:[NSSet setWithArray:en.allKeys]], @"两种语言文案键完整一致");
    BOOL matchingFormats = YES, englishComplete = YES;
    NSCharacterSet *han = [NSCharacterSet characterSetWithRange:NSMakeRange(0x4e00,0x9fff-0x4e00+1)];
    for (NSString *key in zh) {
        if (![LocalizationFormatTokens(zh[key]) isEqual:LocalizationFormatTokens(en[key])]) matchingFormats = NO;
        if (![key isEqual:@"简体中文"] && [en[key] rangeOfCharacterFromSet:han].location != NSNotFound) englishComplete = NO;
    }
    Check(matchingFormats, @"全部翻译保留格式化参数，不能改变动态参数个数或类型");
    Check(englishComplete, @"英文资源完整翻译，语言列表保留中文自称便于切回");
    for (NSString *language in @[AppLanguageChinese,AppLanguageEnglish]) {
        TestLanguagePreference = language;
        BOOL allLookupsMatch = YES;
        for (NSString *key in tables[language]) if (![L(key) isEqual:tables[language][key]]) allLookupsMatch = NO;
        Check(allLookupsMatch, @"运行时从所选语言 bundle 返回正确文案，无需重启");
        NSURL *shortcut = LocalizedShortcutURL();
        NSData *data = shortcut ? [NSData dataWithContentsOfURL:shortcut] : nil;
        Check(data.length > 10000 && memcmp(data.bytes,"AEA1",4) == 0 &&
            [shortcut.path containsString:[language stringByAppendingString:@".lproj"]],
            @"添加入口按界面语言选择对应的已签名快捷指令");
        FakeServices *disabled = [[FakeServices alloc] initWithSettings:@{
            @"targetDevice":TestTarget,@"automaticConnectionMode":AutomaticModeDisabled}];
        disabled.snapshot = empty;
        Check(RunWorkflow(disabled) == 0 && disabled.events.count == 0,
            @"切换语言不会改变禁止自动连接的行为");
        FakeServices *withScreen = [FakeServices new]; withScreen.snapshot = internal;
        Check(RunWorkflow(withScreen) == 0 && [withScreen.events isEqual:@[@"detect"]],
            @"中英文下无屏模式均跳过实体屏幕");
        NSString *name = @"金鱼's iPad $(literal)";
        NSDictionary *settings = @{@"targetDevice":name,@"automaticConnectionMode":AutomaticModeDisabled};
        FakeServices *direct = [[FakeServices alloc] initWithSettings:settings]; direct.snapshot = physical;
        Check(RunDirectConnection(direct) == 0 && [direct.events.lastObject isEqual:@[@"connect",name]] &&
            [direct.settings isEqual:settings], @"语言不翻译设备名、不改保存设置，直接连接参数始终一致");
    }
    TestLanguagePreference = AppLanguageEnglish;
    Check([L(@"我的 iPad's Name") isEqual:@"我的 iPad's Name"], @"未知文本保持原样，不错误翻译用户数据");
    Check([[NSString stringWithFormat:L(@"正在断开 %@…"),@"金鱼's iPad"] isEqual:@"Disconnecting 金鱼's iPad…"],
        @"英文动态消息保留设备名原文");
    NSError *error = nil;
    Check(NormalizeSettings(@[],&error) == nil && [error.localizedDescription isEqual:@"Settings must be a JSON object."],
        @"设置验证错误随选择显示英文");
    error = nil;
    Check(RunTask(@"/bin/sleep",@[@"2"],0.02,NO,nil,&error) == nil && error.code == ProcessTimeoutErrorCode &&
        [error.localizedDescription containsString:@"timed out"], @"进程超时保持固定错误码，不依赖提示语言");
    CommandSpyServices *spy = [[CommandSpyServices alloc] initWithSettings:@{@"targetDevice":TestTarget}];
    spy.exitStatus = 5;
    Check(![spy connectSidecar:&error] && [error.localizedDescription containsString:@"timed out"],
        @"连接助手超时提示可以正确显示英文");
    TestLanguagePreference = AppLanguageChinese;
}
