//
//  Created by YueRuo on 2026/11/2.
//

// Included by HeadlessSidecarLogin.m; all UI actions run on the main thread.
#import "SettingsLayout.m"
@interface MenuBarSettingsWindow : NSWindow
@end

@implementation MenuBarSettingsWindow
- (void)miniaturize:(id)sender {
    (void)sender;
    // Keep the window out of the Dock; the existing status item remains available.
    [self orderOut:nil];
}
- (void)performMiniaturize:(id)sender {
    [self miniaturize:sender];
}
@end

typedef NS_ENUM(NSUInteger, SidecarAction) {
    SidecarActionAutomaticConnection,
    SidecarActionDirectConnection,
    SidecarActionDisconnect
};

@interface SettingsController : NSObject <NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate, NSComboBoxDelegate, NSMenuItemValidation>
@property (nonatomic) BOOL forceSettings;
@property (nonatomic) BOOL busy;
@property (nonatomic, strong) NSStatusItem *statusItem;
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) NSComboBox *deviceField;
@property (nonatomic, strong) NSPopUpButton *deviceSelectionPopup;
@property (nonatomic, strong) NSStackView *deviceNameRow;
@property (nonatomic, strong) NSTextField *deviceSelectionHint;
@property (nonatomic, strong) NSButton *loginToggle;
@property (nonatomic, strong) NSPopUpButton *automaticModePopup;
@property (nonatomic, strong) NSTextField *automaticModeDetail;
@property (nonatomic, strong) NSTextField *feedback;
@property (nonatomic, strong) NSProgressIndicator *progress;
@property (nonatomic, strong) NSButton *stopDiscoveryButton;
@property (nonatomic, strong) LoginServices *activeServices;
@property (nonatomic, strong) NSArray<NSButton *> *workButtons;
@property (nonatomic, copy) NSDictionary *settings;
@property (nonatomic, strong) NSTextField *connectionLabel;
@property (nonatomic, strong) NSMenuItem *connectionMenuItem;
@property (nonatomic, strong) NSDictionary *connectionSnapshot;
@property (nonatomic) BOOL statusQueryRunning;
@property (nonatomic) BOOL statusRefreshPending;
@property (nonatomic) NSUInteger statusGeneration;
@property (nonatomic, strong) NSTextField *targetLabel;
@property (nonatomic, strong) NSTextField *connectionDetail;
@property (nonatomic, strong) NSTextField *draftNote;
@property (nonatomic, strong) NSImageView *connectionSymbol;
@property (nonatomic, strong) NSImageView *feedbackSymbol;
@property (nonatomic, strong) NSStackView *feedbackRow;
@property (nonatomic, strong) NSButton *connectButton;
@property (nonatomic, strong) NSButton *disconnectButton;
@property (nonatomic, strong) NSButton *saveButton;
@property (nonatomic) BOOL savedLoginEnabled;
@property (nonatomic, strong) NSButton *conditionalButton;
@property (nonatomic, strong) PhysicalDisplayMonitor *physicalDisplayMonitor;
@property (nonatomic) BOOL shortcutImportOpening;
@property (nonatomic, strong) NSPopUpButton *languagePopup;
@property (nonatomic, strong) NSTextField *versionLabel;
@property (nonatomic, copy) NSString *renderedLanguage;
@end

@implementation SettingsController
- (NSString *)versionLabelText {
    id version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    return [version isKindOfClass:NSString.class] && [version length]
        ? [NSString stringWithFormat:L(@"版本 %@ · made by YueRuo"), version] : L(@"版本未知 · made by YueRuo");
}
- (void)selectSavedLanguage {
    NSString *preference = AppLanguagePreference();
    for (NSMenuItem *item in self.languagePopup.itemArray) {
        if ([item.representedObject isEqual:preference]) { [self.languagePopup selectItem:item]; break; }
    }
}
- (void)refreshInterfaceLanguage {
    self.renderedLanguage = CurrentAppLanguage();
    RefreshLocalizedProperties();
    [self selectSavedLanguage];
    self.versionLabel.stringValue = [self versionLabelText];
    NSImage *image = [NSImage imageWithSystemSymbolName:@"display" accessibilityDescription:L(@"随航助手")];
    image.template = YES;
    self.statusItem.button.image = image;
    [self setFeedback:self.busy ? L(@"正在处理…") : L(@"语言已更新。") error:NO];
    [self updateConnectionSnapshot:self.connectionSnapshot ?: ConnectionSnapshot(@"checking", self.settings[@"targetDevice"], nil)];
    [self updateControls];
}
- (void)refreshLanguageIfNeeded {
    if (![self.renderedLanguage isEqualToString:CurrentAppLanguage()]) [self refreshInterfaceLanguage];
}
- (void)languageChanged:(id)sender {
    (void)sender;
    if (self.busy) { [self selectSavedLanguage]; return; }
    NSString *preference = NormalizeLanguagePreference(self.languagePopup.selectedItem.representedObject);
    [NSUserDefaults.standardUserDefaults setObject:preference forKey:AppLanguagePreferenceKey];
    [self refreshInterfaceLanguage];
}
- (NSString *)selectedDeviceSelectionMode {
    return self.deviceSelectionPopup.selectedItem.representedObject ?: DeviceSelectionMode(self.settings) ?: DeviceSelectionNamed;
}
- (void)selectSavedDeviceSelectionMode {
    NSString *mode = DeviceSelectionMode(self.settings);
    for (NSMenuItem *item in self.deviceSelectionPopup.itemArray) {
        if ([item.representedObject isEqual:mode]) { [self.deviceSelectionPopup selectItem:item]; break; }
    }
}
- (NSString *)selectedAutomaticMode {
    return self.automaticModePopup.selectedItem.representedObject ?: AutomaticConnectionMode(self.settings) ?: AutomaticModeHeadless;
}
- (void)selectSavedAutomaticMode {
    NSString *mode = AutomaticConnectionMode(self.settings);
    for (NSMenuItem *item in self.automaticModePopup.itemArray) {
        if ([item.representedObject isEqual:mode]) { [self.automaticModePopup selectItem:item]; break; }
    }
}
- (BOOL)hasUnsavedChanges {
    NSString *saved = self.settings[@"targetDevice"] ?: @"";
    return ![self.deviceField.stringValue isEqualToString:saved] ||
        ![[self selectedDeviceSelectionMode] isEqualToString:DeviceSelectionMode(self.settings)] ||
        ![[self selectedAutomaticMode] isEqualToString:AutomaticConnectionMode(self.settings)] ||
        (self.loginToggle.state == NSControlStateValueOn) != self.savedLoginEnabled;
}
- (void)updateControls {
    self.languagePopup.enabled = !self.busy;
    BOOL saved = HasConfiguredDevice(self.settings);
    BOOL automatic = UsesAutomaticDeviceSelection(self.settings);
    BOOL dirty = [self hasUnsavedChanges];
    NSString *state = self.connectionSnapshot[@"state"];
    BOOL tracked = automatic || [self.connectionSnapshot[@"targetDevice"] isEqualToString:self.settings[@"targetDevice"]];
    for (NSButton *button in self.workButtons) button.enabled = !self.busy;
    BOOL automaticDraft = [[self selectedDeviceSelectionMode] isEqualToString:DeviceSelectionAutomatic];
    self.deviceSelectionPopup.enabled = !self.busy;
    self.deviceNameRow.hidden = automaticDraft;
    self.deviceField.enabled = !self.busy && !automaticDraft;
    self.deviceSelectionHint.stringValue = automaticDraft
        ? L(@"连接时自动查找第一台可用 iPad；已连接时沿用当前设备。")
        : L(@"可从列表选择，也可填写 iPad 的完整名称。");
    self.loginToggle.enabled = !self.busy;
    self.automaticModePopup.enabled = !self.busy;
    self.conditionalButton.enabled = !self.busy && saved && !dirty &&
        ![AutomaticConnectionMode(self.settings) isEqualToString:AutomaticModeDisabled];
    self.connectButton.enabled = !self.busy && saved && !(tracked && [state isEqualToString:@"connected"]);
    self.disconnectButton.enabled = !self.busy && saved && (automatic
        ? [state isEqualToString:@"connected"] : !(tracked && [state isEqualToString:@"disconnected"]));
    NSString *draftMode = [self selectedAutomaticMode];
    BOOL canSaveTarget = automaticDraft || ValidDeviceName(self.deviceField.stringValue) ||
        (self.deviceField.stringValue.length == 0 && [draftMode isEqualToString:AutomaticModeDisabled]);
    self.saveButton.enabled = !self.busy && dirty && canSaveTarget;
    self.saveButton.bezelColor = dirty ? NSColor.controlAccentColor : nil;
    self.connectButton.bezelColor = dirty ? nil : NSColor.controlAccentColor;
    NSString *resolved = self.connectionSnapshot[@"targetDevice"];
    self.targetLabel.stringValue = automatic
        ? (ValidDeviceName(resolved) ? resolved : L(@"自动发现设备"))
        : (saved ? self.settings[@"targetDevice"] : L(@"尚未选择 iPad"));
    self.targetLabel.toolTip = automatic ? L(@"连接时自动选择第一台可用 iPad") : (saved ? self.settings[@"targetDevice"] : nil);
    if (self.busy) self.draftNote.stringValue = L(@"正在处理…");
    else if (dirty) self.draftNote.stringValue = canSaveTarget ? L(@"有未保存的更改") : L(@"请填写 iPad 名称");
    else self.draftNote.stringValue = saved || [draftMode isEqualToString:AutomaticModeDisabled] ? L(@"设置已保存") : L(@"请先选择 iPad");
    if ([draftMode isEqualToString:AutomaticModeAlways])
        self.automaticModeDetail.stringValue = L(@"App 启动或最后一块实体屏幕断开时，自动连接 iPad。");
    else if ([draftMode isEqualToString:AutomaticModeDisabled])
        self.automaticModeDetail.stringValue = L(@"App 启动后保持待命，仍可手动连接 iPad。");
    else self.automaticModeDetail.stringValue = L(@"启动时无实体屏幕，或最后一块实体屏幕断开时，自动连接。");
}
- (void)settingsEdited:(id)sender { (void)sender; [self updateControls]; }
- (void)controlTextDidChange:(NSNotification *)notification { (void)notification; [self updateControls]; }
- (void)comboBoxSelectionDidChange:(NSNotification *)notification {
    (void)notification;
    dispatch_async(dispatch_get_main_queue(), ^{ [self updateControls]; });
}
- (void)setFeedback:(NSString *)message error:(BOOL)error {
    self.feedback.stringValue = message ?: @"";
    self.feedback.textColor = error ? NSColor.labelColor : NSColor.secondaryLabelColor;
    self.feedbackSymbol.image = [NSImage imageWithSystemSymbolName:error ? @"exclamationmark.circle.fill" : @"info.circle.fill" accessibilityDescription:nil];
    self.feedbackSymbol.contentTintColor = error ? NSColor.systemOrangeColor : NSColor.secondaryLabelColor;
    self.feedbackRow.hidden = message.length == 0;
    NSString *status = self.connectionMenuItem.title ?: L(@"随航助手");
    self.statusItem.button.toolTip = message.length ? [NSString stringWithFormat:@"%@\n%@", status, message] : status;
}
- (void)setWorking:(BOOL)working {
    self.busy = working;
    [self.physicalDisplayMonitor setOperationBusy:working];
    [self updateControls];
    if (working) [self.progress startAnimation:nil];
    else {
        [self.progress stopAnimation:nil];
        self.stopDiscoveryButton.hidden = YES;
        self.stopDiscoveryButton.enabled = NO;
        self.activeServices = nil;
    }
}
- (void)stopAutomaticDiscovery:(id)sender {
    (void)sender;
    self.activeServices.cancelDiscoveryRequested = YES;
    self.stopDiscoveryButton.enabled = NO;
    [self setFeedback:L(@"正在停止本次自动查找…") error:NO];
}
- (void)buildWindow {
    CGFloat availableHeight = NSScreen.mainScreen.visibleFrame.size.height - 80;
    CGFloat height = MAX(540, MIN(740, availableHeight));
    self.window = [[MenuBarSettingsWindow alloc] initWithContentRect:NSMakeRect(0, 0, 620, height)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    BindLocalizedProperty(self.window, @"title", @"随航助手设置");
    self.window.delegate = self;
    self.window.contentMinSize = NSMakeSize(560, 540);
    self.window.releasedWhenClosed = NO;
    NSButton *minimize = [self.window standardWindowButton:NSWindowMiniaturizeButton];
    minimize.target = self.window;
    minimize.action = @selector(miniaturize:);
    BindLocalizedProperty(minimize, @"toolTip", @"收起到菜单栏");
    [self.window center];

    NSImageView *logo = [[NSImageView alloc] init];
    logo.image = [NSImage imageNamed:NSImageNameApplicationIcon];
    logo.imageScaling = NSImageScaleProportionallyUpOrDown;
    [logo.widthAnchor constraintEqualToConstant:44].active = YES;
    [logo.heightAnchor constraintEqualToConstant:44].active = YES;
    NSString *versionText = [self versionLabelText];
    NSTextField *versionLabel = SettingsText(versionText, 11, NSFontWeightRegular, NSColor.secondaryLabelColor);
    self.versionLabel = versionLabel;
    versionLabel.maximumNumberOfLines = 1;
    [versionLabel setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *titleRow = SettingsRow(@[
        SettingsText(@"随航助手", 23, NSFontWeightSemibold, NSColor.labelColor), versionLabel, SettingsSpace()
    ], 10);
    NSStackView *heading = SettingsColumn(@[
        titleRow,
        SettingsText(@"将 iPad 用作 Mac 的另一块屏幕", 12, NSFontWeightRegular, NSColor.secondaryLabelColor)
    ], 3);
    NSStackView *header = SettingsRow(@[logo, heading], 12);
    self.languagePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.languagePopup.font = [NSFont systemFontOfSize:12];
    self.languagePopup.target = self;
    self.languagePopup.action = @selector(languageChanged:);
    BindLocalizedProperty(self.languagePopup, @"accessibilityLabel", @"语言");
    BindLocalizedProperty(self.languagePopup, @"toolTip", @"切换后立即生效，并自动保存。");
    for (NSArray *entry in @[@[@"跟随系统", AppLanguageSystem], @[@"简体中文", AppLanguageChinese], @[@"English", AppLanguageEnglish]]) {
        [self.languagePopup addItemWithTitle:L(entry[0])];
        NSMenuItem *item = self.languagePopup.lastItem;
        item.representedObject = entry[1];
        BindLocalizedProperty(item, @"title", entry[0]);
    }
    [self selectSavedLanguage];
    self.renderedLanguage = CurrentAppLanguage();
    NSStackView *languageRow = SettingsRow(@[SettingsText(@"语言", 12, NSFontWeightMedium, NSColor.labelColor),
        self.languagePopup, SettingsSpace()], 12);

    NSImageView *deviceIcon = [[NSImageView alloc] init];
    deviceIcon.image = [NSImage imageWithSystemSymbolName:@"ipad" accessibilityDescription:nil];
    deviceIcon.contentTintColor = NSColor.secondaryLabelColor;
    [deviceIcon.widthAnchor constraintEqualToConstant:28].active = YES;
    [deviceIcon.heightAnchor constraintEqualToConstant:32].active = YES;
    self.targetLabel = SettingsText(@"尚未选择 iPad", 18, NSFontWeightSemibold, NSColor.labelColor);
    self.targetLabel.maximumNumberOfLines = 1;
    self.targetLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.targetLabel setContentCompressionResistancePriority:200 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *targetHeading = SettingsColumn(@[
        SettingsText(@"当前设备", 11, NSFontWeightMedium, NSColor.secondaryLabelColor), self.targetLabel
    ], 3);
    [targetHeading setContentCompressionResistancePriority:200 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [targetHeading setContentHuggingPriority:200 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSButton *refresh = SettingsButton(@"刷新状态", self, @selector(refreshConnectionStatus:));
    [refresh setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *targetRow = SettingsRow(@[deviceIcon, targetHeading, refresh], 10);
    self.connectionSymbol = [[NSImageView alloc] init];
    [self.connectionSymbol.widthAnchor constraintEqualToConstant:15].active = YES;
    [self.connectionSymbol.heightAnchor constraintEqualToConstant:15].active = YES;
    self.connectionLabel = SettingsText(@"正在检查连接状态…", 13, NSFontWeightMedium, NSColor.secondaryLabelColor);
    NSStackView *statusRow = SettingsRow(@[self.connectionSymbol, self.connectionLabel, SettingsSpace()], 7);
    self.connectionDetail = SettingsText(@"打开窗口或菜单时刷新，也可手动刷新。", 12, NSFontWeightRegular, NSColor.secondaryLabelColor);
    self.connectionDetail.maximumNumberOfLines = 2;
    self.connectButton = SettingsButton(@"连接 iPad", self, @selector(directConnect:));
    self.disconnectButton = SettingsButton(@"断开连接", self, @selector(disconnectDevice:));
    [self.connectButton.widthAnchor constraintGreaterThanOrEqualToConstant:126].active = YES;
    BindLocalizedProperty(self.connectButton, @"toolTip", @"连接已保存的 iPad；无可用屏幕时先准备虚拟屏幕");
    BindLocalizedProperty(self.disconnectButton, @"toolTip", @"断开当前 iPad 的随航连接");
    NSStackView *connectionActions = SettingsRow(@[self.connectButton, self.disconnectButton, SettingsSpace()], 10);
    [self.disconnectButton.widthAnchor constraintEqualToAnchor:self.connectButton.widthAnchor].active = YES;
    NSView *connection = SettingsSection(@[
        targetRow, statusRow, self.connectionDetail,
        connectionActions
    ]);

    self.deviceField = [[NSComboBox alloc] init];
    self.deviceField.editable = YES;
    self.deviceField.completes = YES;
    self.deviceField.font = [NSFont systemFontOfSize:13];
    BindLocalizedProperty(self.deviceField, @"placeholderString", @"选择或填写 iPad 名称");
    self.deviceField.delegate = self;
    BindLocalizedProperty(self.deviceField, @"accessibilityLabel", @"iPad 名称");
    [self.deviceField.heightAnchor constraintGreaterThanOrEqualToConstant:28].active = YES;
    [self.deviceField setContentHuggingPriority:200 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.deviceField setContentCompressionResistancePriority:200 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSButton *scan = SettingsButton(@"查找 iPad", self, @selector(scanDevices:));
    self.deviceSelectionPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.deviceSelectionPopup.font = [NSFont systemFontOfSize:13];
    self.deviceSelectionPopup.target = self;
    self.deviceSelectionPopup.action = @selector(settingsEdited:);
    BindLocalizedProperty(self.deviceSelectionPopup, @"accessibilityLabel", @"设备选择方式");
    [self.deviceSelectionPopup.heightAnchor constraintGreaterThanOrEqualToConstant:28].active = YES;
    [self.deviceSelectionPopup setContentHuggingPriority:200 forOrientation:NSLayoutConstraintOrientationHorizontal];
    for (NSArray *entry in @[@[@"自动发现设备", DeviceSelectionAutomatic], @[@"指定 iPad", DeviceSelectionNamed]]) {
        [self.deviceSelectionPopup addItemWithTitle:L(entry[0])];
        BindLocalizedProperty(self.deviceSelectionPopup.lastItem, @"title", entry[0]);
        self.deviceSelectionPopup.lastItem.representedObject = entry[1];
    }
    self.deviceNameRow = SettingsRow(@[self.deviceField, scan], 10);
    self.deviceSelectionHint = SettingsText(@"", 11, NSFontWeightRegular, NSColor.secondaryLabelColor);
    self.deviceSelectionHint.maximumNumberOfLines = 2;
    NSView *device = SettingsSection(@[
        SettingsText(@"连接设备", 13, NSFontWeightSemibold, NSColor.labelColor),
        SettingsRow(@[SettingsText(@"选择方式", 12, NSFontWeightMedium, NSColor.labelColor), self.deviceSelectionPopup], 12),
        self.deviceNameRow, self.deviceSelectionHint
    ]);

    self.loginToggle = [NSButton checkboxWithTitle:L(@"登录后启动 App") target:self action:@selector(settingsEdited:)];
    BindLocalizedProperty(self.loginToggle, @"title", @"登录后启动 App");
    self.loginToggle.font = [NSFont systemFontOfSize:13];
    self.automaticModePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.automaticModePopup.font = [NSFont systemFontOfSize:13];
    self.automaticModePopup.target = self;
    self.automaticModePopup.action = @selector(settingsEdited:);
    BindLocalizedProperty(self.automaticModePopup, @"accessibilityLabel", @"自动连接方式");
    [self.automaticModePopup.heightAnchor constraintGreaterThanOrEqualToConstant:28].active = YES;
    [self.automaticModePopup setContentHuggingPriority:200 forOrientation:NSLayoutConstraintOrientationHorizontal];
    for (NSArray *entry in @[
        @[@"无实体屏幕时自动连接", AutomaticModeHeadless],
        @[@"始终自动连接", AutomaticModeAlways],
        @[@"禁止自动连接", AutomaticModeDisabled]]) {
        [self.automaticModePopup addItemWithTitle:L(entry[0])];
        BindLocalizedProperty(self.automaticModePopup.lastItem, @"title", entry[0]);
        self.automaticModePopup.lastItem.representedObject = entry[1];
    }
    self.automaticModeDetail = SettingsText(@"", 11, NSFontWeightRegular, NSColor.secondaryLabelColor);
    self.automaticModeDetail.maximumNumberOfLines = 2;
    NSButton *conditional = SettingsButton(@"执行自动连接", self, @selector(runOnce:));
    self.conditionalButton = conditional;
    BindLocalizedProperty(conditional, @"toolTip", @"按已保存的自动连接方式执行一次；修改方式后请先保存");
    NSButton *loginSettings = SettingsButton(@"登录项设置…", self, @selector(openLoginItems:));
    NSView *automation = SettingsSection(@[
        SettingsText(@"启动与连接", 13, NSFontWeightSemibold, NSColor.labelColor), self.loginToggle,
        SettingsRow(@[SettingsText(@"自动连接方式", 12, NSFontWeightMedium, NSColor.labelColor), self.automaticModePopup], 12),
        self.automaticModeDetail,
        SettingsRow(@[conditional, SettingsSpace(), loginSettings], 10)
    ]);

    NSScrollView *scroll = [[NSScrollView alloc] init];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.drawsBackground = NO;
    scroll.borderType = NSNoBorder;
    SettingsDocumentView *document = [[SettingsDocumentView alloc] init];
    document.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.documentView = document;
    NSStackView *body = SettingsColumn(@[header, languageRow, connection, device, automation, SettingsSpace()], 14);
    [document addSubview:body];
    NSView *content = self.window.contentView;
    [content addSubview:scroll];

    self.feedback = SettingsText(@"", 12, NSFontWeightRegular, NSColor.secondaryLabelColor);
    self.feedback.maximumNumberOfLines = 3;
    self.feedbackSymbol = [[NSImageView alloc] init];
    [self.feedbackSymbol.widthAnchor constraintEqualToConstant:15].active = YES;
    [self.feedbackSymbol.heightAnchor constraintEqualToConstant:15].active = YES;
    self.feedbackRow = SettingsRow(@[self.feedbackSymbol, self.feedback], 8);
    self.progress = [[NSProgressIndicator alloc] init];
    self.progress.style = NSProgressIndicatorStyleSpinning;
    self.progress.displayedWhenStopped = NO;
    [self.progress.widthAnchor constraintEqualToConstant:16].active = YES;
    [self.progress.heightAnchor constraintEqualToConstant:16].active = YES;
    self.draftNote = SettingsText(@"设置已保存", 11, NSFontWeightRegular, NSColor.secondaryLabelColor);
    self.draftNote.maximumNumberOfLines = 1;
    self.draftNote.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.draftNote setContentCompressionResistancePriority:200 forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.saveButton = SettingsButton(@"保存设置", self, @selector(saveSettings:));
    [self.saveButton.widthAnchor constraintGreaterThanOrEqualToConstant:100].active = YES;
    self.saveButton.keyEquivalent = @"s";
    self.saveButton.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    NSPopUpButton *more = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:YES];
    more.font = [NSFont systemFontOfSize:12];
    more.bezelStyle = NSBezelStyleRounded;
    [more addItemWithTitle:L(@"更多操作")];
    BindLocalizedProperty(more.itemArray.firstObject, @"title", @"更多操作");
    for (NSArray *entry in @[@[@"添加到快捷指令…", NSStringFromSelector(@selector(addToShortcuts:))],
                             @[@"检查屏幕", NSStringFromSelector(@selector(checkDisplays:))],
                             @[@"查看运行记录", NSStringFromSelector(@selector(showLogs:))],
                             @[@"关于随航助手", NSStringFromSelector(@selector(showAbout:))]]) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:L(entry[0]) action:NSSelectorFromString(entry[1]) keyEquivalent:@""];
        item.target = self;
        BindLocalizedProperty(item, @"title", entry[0]);
        [more.menu addItem:item];
    }
    self.stopDiscoveryButton = SettingsButton(@"停止查找", self, @selector(stopAutomaticDiscovery:));
    NSStackView *footerButtons = SettingsRow(@[more, self.progress, self.stopDiscoveryButton,
        SettingsSpace(), self.draftNote, self.saveButton], 10);
    self.stopDiscoveryButton.hidden = YES;
    self.stopDiscoveryButton.enabled = NO;
    NSStackView *footerBody = SettingsColumn(@[self.feedbackRow, footerButtons], 10);
    footerBody.detachesHiddenViews = NO;
    NSView *footer = [[NSView alloc] init];
    footer.translatesAutoresizingMaskIntoConstraints = NO;
    [footer addSubview:footerBody];
    NSBox *separator = [[NSBox alloc] init];
    separator.boxType = NSBoxSeparator;
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    [footer addSubview:separator];
    [content addSubview:footer];
    [NSLayoutConstraint activateConstraints:@[
        [footer.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [footer.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [footer.bottomAnchor constraintEqualToAnchor:content.bottomAnchor],
        [separator.topAnchor constraintEqualToAnchor:footer.topAnchor],
        [separator.leadingAnchor constraintEqualToAnchor:footer.leadingAnchor],
        [separator.trailingAnchor constraintEqualToAnchor:footer.trailingAnchor],
        [separator.heightAnchor constraintEqualToConstant:1],
        [footerBody.topAnchor constraintEqualToAnchor:separator.bottomAnchor constant:12],
        [footerBody.leadingAnchor constraintEqualToAnchor:footer.leadingAnchor constant:24],
        [footerBody.trailingAnchor constraintEqualToAnchor:footer.trailingAnchor constant:-24],
        [footerBody.bottomAnchor constraintEqualToAnchor:footer.bottomAnchor constant:-16],
        [scroll.topAnchor constraintEqualToAnchor:content.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:content.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:content.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:footer.topAnchor],
        [document.topAnchor constraintEqualToAnchor:scroll.contentView.topAnchor],
        [document.leadingAnchor constraintEqualToAnchor:scroll.contentView.leadingAnchor],
        [document.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor],
        [document.heightAnchor constraintGreaterThanOrEqualToAnchor:scroll.contentView.heightAnchor],
        [body.leadingAnchor constraintEqualToAnchor:document.leadingAnchor constant:24],
        [body.trailingAnchor constraintEqualToAnchor:document.trailingAnchor constant:-24],
        [body.topAnchor constraintEqualToAnchor:document.topAnchor constant:22],
        [body.bottomAnchor constraintEqualToAnchor:document.bottomAnchor constant:-20]
    ]];
    self.workButtons = @[scan, conditional, loginSettings, self.saveButton];
}
- (void)buildMenu {
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];
    NSImage *image = [NSImage imageWithSystemSymbolName:@"display" accessibilityDescription:L(@"随航助手")];
    image.template = YES;
    self.statusItem.button.image = image;
    NSMenu *menu = [[NSMenu alloc] initWithTitle:L(@"随航助手")];
    BindLocalizedProperty(menu, @"title", @"随航助手");
    NSArray *entries = @[@[@"随航助手设置", NSStringFromSelector(@selector(showSettings:))],
                         @[@"连接 iPad", NSStringFromSelector(@selector(directConnect:))],
                         @[@"断开连接", NSStringFromSelector(@selector(disconnectDevice:))],
                         @[@"执行自动连接", NSStringFromSelector(@selector(runOnce:))],
                         @[@"检查屏幕", NSStringFromSelector(@selector(checkDisplays:))],
                         @[@"查看运行记录", NSStringFromSelector(@selector(showLogs:))],
                         @[@"关于随航助手", NSStringFromSelector(@selector(showAbout:))]];
    for (NSArray *entry in entries) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:L(entry[0]) action:NSSelectorFromString(entry[1]) keyEquivalent:@""];
        item.target = self;
        BindLocalizedProperty(item, @"title", entry[0]);
        [menu addItem:item];
    }
    self.connectionMenuItem = [[NSMenuItem alloc] initWithTitle:L(@"随航状态：检测中…") action:NULL keyEquivalent:@""];
    self.connectionMenuItem.enabled = NO;
    [menu insertItem:self.connectionMenuItem atIndex:1];
    [menu insertItem:NSMenuItem.separatorItem atIndex:2];
    menu.delegate = self;
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *quit = [[NSMenuItem alloc] initWithTitle:L(@"退出随航助手") action:@selector(terminate:) keyEquivalent:@"q"];
    BindLocalizedProperty(quit, @"title", @"退出随航助手");
    quit.target = NSApp;
    [menu addItem:quit];
    self.statusItem.menu = menu;
    NSMenu *main = [[NSMenu alloc] init];
    NSMenuItem *application = [[NSMenuItem alloc] init];
    NSMenu *applicationMenu = [[NSMenu alloc] init];
    BindLocalizedProperty(application, @"title", @"随航助手");
    BindLocalizedProperty(applicationMenu, @"title", @"随航助手");
    NSMenuItem *quitMain = [quit copy];
    BindLocalizedProperty(quitMain, @"title", @"退出随航助手");
    [applicationMenu addItem:quitMain];
    application.submenu = applicationMenu;
    [main addItem:application];
    NSMenuItem *edit = [[NSMenuItem alloc] initWithTitle:L(@"编辑") action:NULL keyEquivalent:@""];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:L(@"编辑")];
    BindLocalizedProperty(edit, @"title", @"编辑");
    BindLocalizedProperty(editMenu, @"title", @"编辑");
    NSArray *editActions = @[@[@"剪切", @"cut:", @"x"], @[@"拷贝", @"copy:", @"c"],
                            @[@"粘贴", @"paste:", @"v"], @[@"全选", @"selectAll:", @"a"]];
    for (NSArray *action in editActions) {
        NSMenuItem *item = [editMenu addItemWithTitle:L(action[0]) action:NSSelectorFromString(action[1]) keyEquivalent:action[2]];
        BindLocalizedProperty(item, @"title", action[0]);
    }
    edit.submenu = editMenu;
    [main addItem:edit];
    NSApp.mainMenu = main;
}
- (void)refreshLoginState {
    SMAppServiceStatus status = SMAppService.mainAppService.status;
    self.savedLoginEnabled = status == SMAppServiceStatusEnabled || status == SMAppServiceStatusRequiresApproval;
    self.loginToggle.state = self.savedLoginEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    [self updateControls];
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    NSError *error = nil;
    self.settings = ReadSettingsAtPath(SettingsPath(), &error);
    if (!self.settings) self.settings = NormalizeSettings(@{}, nil);
    [self buildMenu];
    @try { [self buildWindow]; }
    @catch (NSException *exception) {
        Log([NSString stringWithFormat:L(@"创建设置窗口失败：%@ %@"), exception.name, exception.reason]);
        @throw;
    }
    BOOL disabled = [AutomaticConnectionMode(self.settings) isEqualToString:AutomaticModeDisabled];
    self.deviceField.stringValue = self.settings[@"targetDevice"] ?: @"";
    [self selectSavedDeviceSelectionMode];
    [self selectSavedAutomaticMode];
    [self refreshLoginState];
    if (error) {
        Log([NSString stringWithFormat:L(@"读取设置失败：%@"), error.localizedDescription]);
        [self setFeedback:L(@"设备设置暂时无法读取，请重新选择 iPad 并保存。") error:YES];
    } else [self setFeedback:@"" error:NO];
    [self updateControls];
    [self startPhysicalDisplayMonitor];
    if (self.forceSettings || error || (!disabled && !HasConfiguredDevice(self.settings)))
        [self showSettings:nil];
    else if (!disabled) [self runOnce:nil];
}
- (void)startPhysicalDisplayMonitor {
    __weak SettingsController *weakSelf = self;
    self.physicalDisplayMonitor = [[PhysicalDisplayMonitor alloc] initWithReader:^NSDictionary *{
        NSError *error = nil;
        NSDictionary *settings = ReadSettingsAtPath(SettingsPath(), &error);
        NSDictionary *snapshot = settings ? ReadDisplays(settings, &error) : nil;
        if (!snapshot) Log([NSString stringWithFormat:L(@"屏幕变化检查失败：%@"), error.localizedDescription ?: @"unknown"]);
        return snapshot;
    } removalHandler:^{
        SettingsController *controller = weakSelf;
        if (!controller) return;
        Log(L(@"最后一块实体屏幕已断开，按已保存的自动连接方式执行一次。"));
        [controller runOnce:nil];
    } settleDelay:1.0];
    [self.physicalDisplayMonitor start];
}
- (void)applicationDidChangeScreenParameters:(NSNotification *)notification {
    (void)notification;
    [self.physicalDisplayMonitor displayConfigurationDidChange];
}
- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    self.activeServices.cancelDiscoveryRequested = YES;
    [self.physicalDisplayMonitor stop];
}
- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)visible {
    (void)sender; (void)visible;
    [self showSettings:nil];
    return YES;
}
- (void)showExistingSettings:(NSNotification *)notification {
    (void)notification;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.forceSettings = YES;
        if (self.window) [self showSettings:nil];
    });
}
- (void)showSettings:(id)sender {
    (void)sender;
    [self refreshLanguageIfNeeded];
    if (![self hasUnsavedChanges]) [self refreshLoginState];
    [self refreshConnectionStatus:nil];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}
- (void)openLoginItems:(id)sender { (void)sender; [SMAppService openSystemSettingsLoginItems]; }
- (void)showLogs:(id)sender {
    (void)sender;
    NSString *path = [LogDirectory() stringByAppendingPathComponent:@"run.log"];
    if ([NSFileManager.defaultManager fileExistsAtPath:path]) [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:path]];
    else { [self showSettings:nil]; [self setFeedback:L(@"还没有运行记录。连接或断开一次后，可从这里查看。") error:NO]; }
}
- (void)saveSettings:(id)sender {
    (void)sender;
    if (self.busy) return;
    NSError *error = nil;
    BOOL automatic = [[self selectedDeviceSelectionMode] isEqualToString:DeviceSelectionAutomatic];
    NSString *fixedName = self.deviceField.stringValue;
    if (automatic && !ValidDeviceName(fixedName)) fixedName = @"";
    NSDictionary *updated = @{@"targetDevice": fixedName,
                              @"ignoreDisplayNames": self.settings[@"ignoreDisplayNames"] ?: @[],
                              @"automaticConnectionMode": [self selectedAutomaticMode],
                              @"deviceSelectionMode": [self selectedDeviceSelectionMode]};
    if (!HasConfiguredDevice(updated) &&
        !([updated[@"targetDevice"] length] == 0 && [[self selectedAutomaticMode] isEqualToString:AutomaticModeDisabled])) {
        [self setFeedback:L(@"请填写 iPad 的完整名称，名称中不能包含换行。") error:YES]; return;
    }
    if (!SaveSettingsAtPath(updated, SettingsPath(), &error)) {
        Log([NSString stringWithFormat:L(@"保存设置失败：%@"), error.localizedDescription]);
        [self setFeedback:L(@"设置未能保存，请稍后重试。") error:YES]; return;
    }
    self.settings = updated;
    self.deviceField.stringValue = updated[@"targetDevice"];
    self.statusGeneration++;
    [self updateConnectionSnapshot:ConnectionSnapshot(@"checking", automatic ? @"" : updated[@"targetDevice"], nil)];
    [self refreshConnectionStatus:nil];
    BOOL desired = self.loginToggle.state == NSControlStateValueOn;
    SMAppService *service = SMAppService.mainAppService;
    BOOL enabled = service.status == SMAppServiceStatusEnabled || service.status == SMAppServiceStatusRequiresApproval;
    if (desired != enabled) {
        NSString *parent = NSBundle.mainBundle.bundlePath.stringByDeletingLastPathComponent.stringByResolvingSymlinksInPath;
        NSString *userApplications = [NSHomeDirectory() stringByAppendingPathComponent:@"Applications"];
        if (desired && ![parent isEqualToString:@"/Applications"] && ![parent isEqualToString:userApplications]) {
            [self refreshLoginState];
            [self setFeedback:L(@"设置已保存。请先将随航助手放入「应用程序」，再开启登录后启动 App。") error:YES];
            return;
        }
        BOOL ok = desired ? [service registerAndReturnError:&error] : [service unregisterAndReturnError:&error];
        if (!ok) {
            [self refreshLoginState];
            Log([NSString stringWithFormat:L(@"更新登录项失败：%@"), error.localizedDescription]);
            [self setFeedback:L(@"设备已保存。登录启动设置未能更新，请在「登录项设置」中检查。") error:YES];
            return;
        }
    }
    [self refreshLoginState];
    if (service.status == SMAppServiceStatusRequiresApproval)
        [self setFeedback:L(@"设置已保存。请在「登录项设置」中允许随航助手登录后运行。") error:NO];
    else [self setFeedback:L(@"设置已保存。") error:NO];
}
- (void)updateConnectionSnapshot:(NSDictionary *)snapshot {
    self.connectionSnapshot = snapshot;
    NSString *state = snapshot[@"state"];
    NSString *title;
    NSString *detail;
    NSString *symbol;
    NSColor *color = NSColor.secondaryLabelColor;
    if ([state isEqualToString:@"connected"]) {
        title = L(@"已连接"); symbol = @"checkmark.circle.fill"; color = NSColor.systemGreenColor;
        detail = L(@"此 iPad 的随航连接已建立。");
    } else if ([state isEqualToString:@"disconnected"]) {
        title = L(@"未连接"); symbol = @"circle";
        detail = UsesAutomaticDeviceSelection(self.settings)
            ? L(@"点击「连接 iPad」，将自动查找第一台可用设备。")
            : L(@"唤醒并解锁 iPad 后，点击「连接 iPad」。");
    } else if ([state isEqualToString:@"unconfigured"]) {
        title = L(@"尚未设置设备"); symbol = @"ipad";
        detail = L(@"先在下方选择 iPad 并保存，即可开始连接。");
    } else if ([state isEqualToString:@"checking"]) {
        title = L(@"正在检查连接状态…"); symbol = @"arrow.clockwise.circle";
        detail = L(@"正在读取当前连接状态。");
    } else {
        title = L(@"暂时无法确认状态"); symbol = @"questionmark.circle"; color = NSColor.systemOrangeColor;
        detail = L(@"可以刷新状态，或直接尝试连接。");
    }
    self.connectionLabel.stringValue = title;
    self.connectionLabel.textColor = color;
    self.connectionSymbol.image = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil];
    self.connectionSymbol.contentTintColor = color;
    self.connectionDetail.stringValue = detail;
    self.connectionMenuItem.title = [NSString stringWithFormat:L(@"随航状态：%@"), title];
    NSString *target = snapshot[@"targetDevice"];
    self.connectionLabel.toolTip = target.length ? [NSString stringWithFormat:L(@"%@ 的连接状态"), target]
        : (UsesAutomaticDeviceSelection(self.settings) ? L(@"自动发现设备的连接状态") : L(@"先选择并保存 iPad"));
    [self updateControls];
    NSString *message = self.feedback.stringValue;
    self.statusItem.button.toolTip = message.length
        ? [NSString stringWithFormat:@"%@\n%@", self.connectionMenuItem.title, message]
        : self.connectionMenuItem.title;
}
- (void)refreshConnectionStatus:(id)sender {
    // Opening a window can also make it key. Reuse that in-flight query;
    // manual refreshes and generation changes can request one follow-up.
    if (self.statusQueryRunning) {
        if (sender) self.statusRefreshPending = YES;
        return;
    }
    self.statusQueryRunning = YES;
    NSUInteger generation = self.statusGeneration;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            NSError *error = nil;
            NSDictionary *settings = ReadSettingsAtPath(SettingsPath(), &error);
            NSDictionary *snapshot = settings ? ReadConnectionStatus(settings) : ConnectionSnapshot(@"unknown", @"", nil);
            dispatch_async(dispatch_get_main_queue(), ^{
                self.statusQueryRunning = NO;
                if (generation == self.statusGeneration) {
                    if (settings) {
                        BOOL draft = [self hasUnsavedChanges];
                        self.settings = settings;
                        if (!draft) {
                            self.deviceField.stringValue = settings[@"targetDevice"];
                            [self selectSavedDeviceSelectionMode];
                            [self selectSavedAutomaticMode];
                        }
                    }
                    [self updateConnectionSnapshot:snapshot];
                }
                BOOL again = self.statusRefreshPending || generation != self.statusGeneration;
                self.statusRefreshPending = NO;
                if (again) [self refreshConnectionStatus:nil];
            });
        }
    });
}
- (void)menuWillOpen:(NSMenu *)menu {
    (void)menu;
    [self refreshLanguageIfNeeded];
    [self refreshConnectionStatus:nil];
}
- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action == @selector(addToShortcuts:)) return !self.shortcutImportOpening;
    if (item.action == @selector(directConnect:)) return self.connectButton.enabled;
    if (item.action == @selector(disconnectDevice:)) return self.disconnectButton.enabled;
    if (item.action == @selector(runOnce:)) return self.conditionalButton.enabled;
    if (item.action == @selector(checkDisplays:)) return !self.busy;
    return YES;
}
- (void)windowDidBecomeKey:(NSNotification *)notification {
    (void)notification;
    [self refreshLanguageIfNeeded];
    if (![self hasUnsavedChanges]) [self refreshLoginState];
    [self refreshConnectionStatus:nil];
}
- (void)showAbout:(id)sender {
    (void)sender;
    id bundleVersion = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    NSString *version = [bundleVersion isKindOfClass:NSString.class] && [bundleVersion length]
        ? bundleVersion : L(@"版本未知");
    NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
    paragraph.alignment = NSTextAlignmentCenter;
    NSDictionary *attributes = @{NSFontAttributeName:[NSFont systemFontOfSize:12],
        NSForegroundColorAttributeName:NSColor.secondaryLabelColor, NSParagraphStyleAttributeName:paragraph};
    NSMutableAttributedString *credits = [[NSMutableAttributedString alloc] initWithString:L(@"作者：YueRuo\n\n")
        attributes:attributes];
    // Show the optional author URL only when Info.plist contains a valid HTTPS address.
    id configuredURL = [NSBundle.mainBundle objectForInfoDictionaryKey:@"YueRuoWebsiteURL"];
    NSURL *website = [configuredURL isKindOfClass:NSString.class] ? [NSURL URLWithString:configuredURL] : nil;
    if ([website.scheme.lowercaseString isEqualToString:@"https"] && website.host.length &&
        !website.user.length && !website.password.length) {
        NSMutableDictionary *linkAttributes = [attributes mutableCopy];
        linkAttributes[NSLinkAttributeName] = website;
        linkAttributes[NSForegroundColorAttributeName] = NSColor.linkColor;
        linkAttributes[NSUnderlineStyleAttributeName] = @(NSUnderlineStyleSingle);
        [credits appendAttributedString:[[NSAttributedString alloc] initWithString:website.absoluteString
            attributes:linkAttributes]];
    }
    [NSApp activate];
    [NSApp orderFrontStandardAboutPanelWithOptions:@{
        NSAboutPanelOptionApplicationName:L(@"随航助手"),
        NSAboutPanelOptionApplicationVersion:[version isEqualToString:L(@"版本未知")] ? version : [NSString stringWithFormat:L(@"版本 %@"), version],
        NSAboutPanelOptionVersion:@"", NSAboutPanelOptionCredits:credits
    }];
}
- (void)addToShortcuts:(id)sender {
    (void)sender;
    if (self.shortcutImportOpening) return;
    NSURL *templateURL = LocalizedShortcutURL();
    if (!templateURL || ![NSFileManager.defaultManager isReadableFileAtPath:templateURL.path]) {
        [self setFeedback:L(@"找不到快捷指令模板，请重新安装随航助手。") error:YES];
        return;
    }
    // Open only the bundled signed template in Apple's system Shortcuts app.
    // The system owns import confirmation and iCloud sync; opening is not proof of either.
    NSURL *applicationURL = [NSURL fileURLWithPath:@"/System/Applications/Shortcuts.app" isDirectory:YES];
    NSBundle *application = [NSBundle bundleWithURL:applicationURL];
    if (![application.bundleIdentifier isEqualToString:@"com.apple.shortcuts"] || !application.executableURL) {
        [self setFeedback:L(@"无法找到「快捷指令」App，请确认它已安装。") error:YES];
        return;
    }
    self.shortcutImportOpening = YES;
    [self setFeedback:L(@"正在打开快捷指令添加页面…") error:NO];
    NSWorkspaceOpenConfiguration *configuration = [NSWorkspaceOpenConfiguration configuration];
    configuration.activates = YES;
    configuration.addsToRecentItems = NO;
    configuration.createsNewApplicationInstance = NO;
    __weak SettingsController *weakSelf = self;
    [NSWorkspace.sharedWorkspace openURLs:@[templateURL] withApplicationAtURL:applicationURL
        configuration:configuration completionHandler:^(NSRunningApplication *app, NSError *error) {
            BOOL opened = app != nil && error == nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                SettingsController *controller = weakSelf;
                if (!controller) return;
                controller.shortcutImportOpening = NO;
                [controller setFeedback:opened
                    ? L(@"请完成添加。Mac 和 iPad 登录同一 Apple 账户并开启 iCloud 同步后，可在 iPad 上看到。")
                    : L(@"无法打开添加页面，请稍后重试，或手动添加包内的快捷指令模板。") error:!opened];
            });
        }];
}
- (void)scanDevices:(id)sender {
    (void)sender;
    if (self.busy) return;
    [self setWorking:YES];
    [self setFeedback:L(@"正在查找附近的 iPad…") error:NO];
    NSDictionary *settings = self.settings;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            NSError *error = nil;
            LoginServices *services = [[LoginServices alloc] initWithSettings:settings];
            NSArray *names = [services availableDeviceNames:&error] ?: @[];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self setWorking:NO];
                [self.deviceField removeAllItems];
                [self.deviceField addItemsWithObjectValues:names];
                if (names.count) {
                    if (names.count == 1) self.deviceField.stringValue = names[0];
                    [self updateControls];
                    [self setFeedback:L(@"已找到 iPad，选择后点击「保存设置」。") error:NO];
                } else {
                    if (error) Log([NSString stringWithFormat:L(@"查找设备失败：%@"), error.localizedDescription]);
                    [self setFeedback:L(@"暂未找到可用 iPad。请唤醒并解锁设备，或手动填写完整名称。") error:NO];
                }
            });
        }
    });
}
- (void)checkDisplays:(id)sender {
    (void)sender;
    if (self.busy) return;
    [self setWorking:YES];
    [self setFeedback:L(@"正在检查屏幕…") error:NO];
    NSDictionary *settings = self.settings;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            NSError *error = nil;
            NSDictionary *result = ReadDisplays(settings, &error);
            NSMutableArray *physical = [NSMutableArray array];
            for (NSDictionary *display in result[@"physicalExternalDisplays"]) [physical addObject:display[@"name"]];
            if (!result) Log([NSString stringWithFormat:L(@"检查显示器失败：%@"), error.localizedDescription]);
            NSString *message = !result ? L(@"暂时无法检查显示器，请稍后重试。") : physical.count
                ? [NSString stringWithFormat:L(@"检测到外接屏幕：%@。连接时无需 BetterDisplay。"), [physical componentsJoinedByString:@"、"]]
                : [result[@"builtInDisplays"] count]
                    ? L(@"检测到内置屏幕，连接时无需 BetterDisplay。")
                    : [result[@"virtualBaseDisplays"] count]
                        ? L(@"已有独立虚拟屏幕，可直接连接 iPad，无需启动 BetterDisplay。")
                        : L(@"当前没有可用屏幕，连接时需要 BetterDisplay 提供虚拟屏幕。");
            dispatch_async(dispatch_get_main_queue(), ^{ [self setWorking:NO]; [self setFeedback:message error:result == nil]; });
        }
    });
}
- (void)runOnce:(id)sender {
    (void)sender;
    [self startSidecarAction:SidecarActionAutomaticConnection];
}
- (void)directConnect:(id)sender {
    (void)sender;
    [self startSidecarAction:SidecarActionDirectConnection];
}
- (void)disconnectDevice:(id)sender {
    (void)sender;
    [self startSidecarAction:SidecarActionDisconnect];
}
- (void)startSidecarAction:(SidecarAction)action {
    if (self.busy) return;
    NSError *error = nil;
    NSDictionary *settings = ReadSettingsAtPath(SettingsPath(), &error);
    if (action == SidecarActionAutomaticConnection &&
        [AutomaticConnectionMode(settings) isEqualToString:AutomaticModeDisabled]) return;
    if (!settings || !HasConfiguredDevice(settings)) {
        [self showSettings:nil];
        if (error) Log([NSString stringWithFormat:L(@"读取操作设置失败：%@"), error.localizedDescription]);
        [self setFeedback:L(@"请先选择 iPad 并保存设置。") error:YES];
        return;
    }
    [self setWorking:YES];
    NSString *progress;
    if (action == SidecarActionDisconnect)
        progress = UsesAutomaticDeviceSelection(settings) ? L(@"正在断开当前 iPad…")
            : [NSString stringWithFormat:L(@"正在断开 %@…"), settings[@"targetDevice"]];
    else if (action == SidecarActionDirectConnection)
        progress = UsesAutomaticDeviceSelection(settings) ? L(@"正在查找可用 iPad 并连接…")
            : [NSString stringWithFormat:L(@"正在检查屏幕并连接 %@…"), settings[@"targetDevice"]];
    else progress = L(@"正在按已保存的自动连接方式执行…");
    [self setFeedback:progress error:NO];
    LoginServices *services = [[LoginServices alloc] initWithSettings:settings];
    self.activeServices = services;
    __weak SettingsController *weakSelf = self;
    __weak LoginServices *weakServices = services;
    services.discoveryProgress = ^(NSString *message, BOOL searching) {
        dispatch_async(dispatch_get_main_queue(), ^{
            SettingsController *controller = weakSelf;
            LoginServices *active = weakServices;
            if (!controller || !active || !controller.busy || controller.activeServices != active) return;
            if (!active.cancelDiscoveryRequested) [controller setFeedback:message error:NO];
            controller.stopDiscoveryButton.hidden = !searching;
            controller.stopDiscoveryButton.enabled = searching && !active.cancelDiscoveryRequested;
        });
    };
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            int lock = PrepareRun();
            int code = 1;
            if (lock >= 0) {
                if (action == SidecarActionDisconnect) code = RunDisconnection(services);
                else if (action == SidecarActionDirectConnection) code = RunDirectConnection(services);
                else code = RunWorkflow(services);
            }
            NSString *message = services.lastMessage ?: (lock == -2 ? L(@"另一个操作正在进行，请稍后再试。") : L(@"暂时无法开始操作，请稍后重试。"));
            if (lock >= 0) { close(lock); close(logFD); logFD = -1; }
            dispatch_async(dispatch_get_main_queue(), ^{
                [self setWorking:NO];
                [self setFeedback:message error:code != 0];
                self.statusGeneration++;
                [self updateConnectionSnapshot:ConnectionSnapshot(@"checking", services.targetDevice, nil)];
                [self refreshConnectionStatus:nil];
            });
        }
    });
}
@end

static int SettingsMain(BOOL forceSettings) {
    __attribute__((objc_precise_lifetime)) SettingsController *controller = [SettingsController new];
    controller.forceSettings = forceSettings;
    // Register before AppKit startup so duplicate launches can hand off to the owner as early as possible.
    [NSDistributedNotificationCenter.defaultCenter addObserver:controller selector:@selector(showExistingSettings:)
        name:ShowExistingSettingsNotification object:NSBundle.mainBundle.bundleIdentifier
        suspensionBehavior:NSNotificationSuspensionBehaviorDeliverImmediately];
    NSApplication *app = NSApplication.sharedApplication;
    [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
    app.delegate = controller;
    [app run];
    [NSDistributedNotificationCenter.defaultCenter removeObserver:controller];
    return 0;
}
