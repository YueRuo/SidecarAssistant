//
//  Created by YueRuo on 2026/11/2.
//

// Native controls and adaptive system colors keep the settings readable in light and dark appearances.
// Bind only interface properties; editable device names and stable option IDs are never translated.
static NSMapTable *SettingsLocalizationBindings(void) {
    static NSMapTable *bindings;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ bindings = [NSMapTable weakToStrongObjectsMapTable]; });
    return bindings;
}

static void BindLocalizedProperty(id object, NSString *property, NSString *key) {
    if (!object || !key.length) return;
    NSMutableDictionary *bindings = [SettingsLocalizationBindings() objectForKey:object];
    if (!bindings) {
        bindings = [NSMutableDictionary dictionary];
        [SettingsLocalizationBindings() setObject:bindings forKey:object];
    }
    bindings[property] = key;
    [object setValue:L(key) forKey:property];
}

static void RefreshLocalizedProperties(void) {
    for (id object in SettingsLocalizationBindings().keyEnumerator) {
        NSDictionary *bindings = [SettingsLocalizationBindings() objectForKey:object];
        for (NSString *property in bindings) [object setValue:L(bindings[property]) forKey:property];
    }
}
@interface SettingsSectionView : NSView
@end
@implementation SettingsSectionView
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5)
        xRadius:12 yRadius:12];
    [NSColor.controlBackgroundColor setFill];
    [path fill];
    [[NSColor.separatorColor colorWithAlphaComponent:0.55] setStroke];
    path.lineWidth = 0.5;
    [path stroke];
}
- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    self.needsDisplay = YES;
}
@end

@interface SettingsDocumentView : NSView
@end
@implementation SettingsDocumentView
- (BOOL)isFlipped { return YES; }
@end

static NSTextField *SettingsText(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color) {
    NSTextField *field = [NSTextField wrappingLabelWithString:L(text)];
    BindLocalizedProperty(field, @"stringValue", text);
    field.font = [NSFont systemFontOfSize:size weight:weight];
    field.textColor = color;
    field.translatesAutoresizingMaskIntoConstraints = NO;
    [field setContentCompressionResistancePriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationVertical];
    return field;
}

static NSButton *SettingsButton(NSString *title, id target, SEL action) {
    NSButton *button = [NSButton buttonWithTitle:L(title) target:target action:action];
    BindLocalizedProperty(button, @"title", title);
    button.bezelStyle = NSBezelStyleRounded;
    button.font = [NSFont systemFontOfSize:13];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:30].active = YES;
    return button;
}

static NSStackView *SettingsRow(NSArray<NSView *> *views, CGFloat spacing) {
    NSStackView *stack = [NSStackView stackViewWithViews:views];
    stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    stack.alignment = NSLayoutAttributeCenterY;
    stack.distribution = NSStackViewDistributionFill;
    stack.spacing = spacing;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSView *view in views) view.translatesAutoresizingMaskIntoConstraints = NO;
    return stack;
}

static NSStackView *SettingsColumn(NSArray<NSView *> *views, CGFloat spacing) {
    NSStackView *stack = [NSStackView stackViewWithViews:views];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.distribution = NSStackViewDistributionFill;
    stack.spacing = spacing;
    stack.detachesHiddenViews = YES;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    for (NSView *view in views) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [view.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    }
    return stack;
}

static NSView *SettingsSpace(void) {
    NSView *view = [[NSView alloc] init];
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [view.widthAnchor constraintGreaterThanOrEqualToConstant:0].active = YES;
    [view.heightAnchor constraintGreaterThanOrEqualToConstant:0].active = YES;
    [view setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [view setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationVertical];
    return view;
}

static NSView *SettingsSection(NSArray<NSView *> *views) {
    SettingsSectionView *section = [[SettingsSectionView alloc] init];
    section.translatesAutoresizingMaskIntoConstraints = NO;
    NSStackView *body = SettingsColumn(views, 10);
    [section addSubview:body];
    [NSLayoutConstraint activateConstraints:@[
        [body.leadingAnchor constraintEqualToAnchor:section.leadingAnchor constant:18],
        [body.trailingAnchor constraintEqualToAnchor:section.trailingAnchor constant:-18],
        [body.topAnchor constraintEqualToAnchor:section.topAnchor constant:16],
        [body.bottomAnchor constraintEqualToAnchor:section.bottomAnchor constant:-16]
    ]];
    return section;
}
