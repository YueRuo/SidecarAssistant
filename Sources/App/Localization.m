//
//  Created by YueRuo on 2026/11/2.
//

// UI language is a separate preference; it never changes connection settings or device names.
static NSString *const AppLanguagePreferenceKey = @"AppLanguage";
static NSString *const AppLanguageSystem = @"system";
static NSString *const AppLanguageChinese = @"zh-Hans";
static NSString *const AppLanguageEnglish = @"en";

#ifdef HEADLESS_TEST
static NSString *TestLanguagePreference = @"zh-Hans";
static NSBundle *TestLocalizationBundle = nil;
#endif

static NSString *NormalizeLanguagePreference(id value) {
    return [value isKindOfClass:NSString.class] && [@[AppLanguageSystem, AppLanguageChinese, AppLanguageEnglish] containsObject:value]
        ? value : AppLanguageSystem;
}

static NSString *AppLanguagePreference(void) {
#ifdef HEADLESS_TEST
    return NormalizeLanguagePreference(TestLanguagePreference);
#else
    return NormalizeLanguagePreference([NSUserDefaults.standardUserDefaults objectForKey:AppLanguagePreferenceKey]);
#endif
}

static NSString *ResolveAppLanguage(id preference, NSArray *preferredLanguages) {
    NSString *normalized = NormalizeLanguagePreference(preference);
    if (![normalized isEqualToString:AppLanguageSystem]) return normalized;
    for (id item in preferredLanguages) {
        if (![item isKindOfClass:NSString.class]) continue;
        NSString *code = [[item lowercaseString] componentsSeparatedByCharactersInSet:
            [NSCharacterSet characterSetWithCharactersInString:@"-_"]].firstObject;
        if ([code isEqualToString:@"zh"]) return AppLanguageChinese;
        if ([code isEqualToString:@"en"]) return AppLanguageEnglish;
    }
    return AppLanguageEnglish;
}

static NSString *CurrentAppLanguage(void) {
    return ResolveAppLanguage(AppLanguagePreference(), NSLocale.preferredLanguages);
}

static NSBundle *AppLocalizationRootBundle(void) {
#ifdef HEADLESS_TEST
    if (TestLocalizationBundle) return TestLocalizationBundle;
#endif
    return NSBundle.mainBundle;
}

static NSBundle *AppBundleForLanguage(NSString *language) {
    if (![@[AppLanguageChinese, AppLanguageEnglish] containsObject:language]) return nil;
    NSBundle *root = AppLocalizationRootBundle();
    static NSCache *bundles;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ bundles = [NSCache new]; bundles.countLimit = 8; });
    NSString *key = [NSString stringWithFormat:@"%@/%@", root.bundlePath, language];
    NSBundle *bundle = [bundles objectForKey:key];
    if (!bundle) {
        NSString *path = [root pathForResource:language ofType:@"lproj"];
        bundle = path ? [NSBundle bundleWithPath:path] : nil;
        if (bundle) [bundles setObject:bundle forKey:key];
    }
    return bundle;
}

static NSString *L(NSString *key) {
    if (!key.length) return key ?: @"";
    NSBundle *bundle = AppBundleForLanguage(CurrentAppLanguage());
    return bundle ? [bundle localizedStringForKey:key value:key table:@"Localizable"] : key;
}

static NSURL *LocalizedShortcutURL(void) {
    NSString *language = CurrentAppLanguage();
    NSString *name = [language isEqualToString:AppLanguageEnglish] ? @"iPad Sidecar Connect" : @"iPad随航连接";
    return [AppBundleForLanguage(language) URLForResource:name withExtension:@"shortcut"];
}
