// language: Objective-C, file: ZLModTheme.m, target: iOS 15.1+ (Zalo 26.10.02 & 26.11.01, arm64)
// Unified Appearance Coordinator + Optional Theme Manager (MODULE 09).
//
// Coordinates Window / NavigationBar / TabBar appearance across both Theme presets/tint
// and Tab Bar blur material (ZLModGlass) using a SINGLE immutable baseline capture per
// UIKit chrome element. Composition is pure and idempotent:
//   OriginalBaseline -> Theme(preset, customTint) -> TabBarMaterial(glass or dark barBg)
// Toggling either Theme or Glass ON/OFF in any order never clobbers the other layer or
// corrupts Zalo's original appearance.

#import "ZLMod.h"

NSString *const ZLModThemeDidChangeNotification = @"ZLModThemeDidChangeNotification";

static const void *kZLModBaselineCapturedAssocKey    = &kZLModBaselineCapturedAssocKey;
static const void *kZLModBaselineStyleAssocKey       = &kZLModBaselineStyleAssocKey;
static const void *kZLModBaselineTintAssocKey        = &kZLModBaselineTintAssocKey;
static const void *kZLModBaselineBarTintAssocKey     = &kZLModBaselineBarTintAssocKey;
static const void *kZLModBaselineStdAppAssocKey      = &kZLModBaselineStdAppAssocKey;
static const void *kZLModBaselineScrollAppAssocKey   = &kZLModBaselineScrollAppAssocKey;
static const void *kZLModBaselineCompactAppAssocKey  = &kZLModBaselineCompactAppAssocKey;

#pragma mark - Color utilities

static NSString *ZLModNormalizeHexString(NSString *hexString) {
    if (![hexString isKindOfClass:[NSString class]]) return @"";
    NSString *clean = [[hexString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] uppercaseString];
    if ([clean hasPrefix:@"#"]) {
        clean = [clean substringFromIndex:1];
    }
    if ([clean hasPrefix:@"0X"]) {
        clean = [clean substringFromIndex:2];
    }
    if (clean.length != 6) return @"";
    NSCharacterSet *nonHex = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEF"] invertedSet];
    if ([clean rangeOfCharacterFromSet:nonHex].location != NSNotFound) {
        return @"";
    }
    return [NSString stringWithFormat:@"#%@", clean];
}

static UIColor *ZLModColorFromHexString(NSString *hexString) {
    NSString *normalized = ZLModNormalizeHexString(hexString);
    if (normalized.length != 7) return nil;
    NSString *hexDigits = [normalized substringFromIndex:1];

    unsigned int rgb = 0;
    NSScanner *scanner = [NSScanner scannerWithString:hexDigits];
    if (![scanner scanHexInt:&rgb]) return nil;

    CGFloat r = ((rgb >> 16) & 0xFF) / 255.0;
    CGFloat g = ((rgb >> 8) & 0xFF) / 255.0;
    CGFloat b = (rgb & 0xFF) / 255.0;
    return [UIColor colorWithRed:r green:g blue:b alpha:1.0];
}

#pragma mark - View hierarchy traversal

static void ZLModEnumerateSubviewsWithClass(UIView *root, Class targetClass, void (^block)(UIView *view)) {
    if (!root || !targetClass || !block) return;
    if ([root isKindOfClass:targetClass]) {
        block(root);
    }
    for (UIView *sub in root.subviews) {
        ZLModEnumerateSubviewsWithClass(sub, targetClass, block);
    }
}

static NSArray<UIWindow *> *ZLModAllApplicationWindows(void) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    UIApplication *app = [UIApplication sharedApplication];
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        for (UIWindow *win in ws.windows) {
            if (win) [windows addObject:win];
        }
    }
    return windows;
}

static BOOL ZLModNotificationTouchesKeys(NSNotification *note, NSSet<NSString *> *watchedKeys) {
    id obj = note.object;
    if ([obj isKindOfClass:[NSString class]]) {
        NSString *key = (NSString *)obj;
        if ([key isEqualToString:@"*"] || [watchedKeys containsObject:key]) return YES;
    }
    NSArray *changed = note.userInfo[ZLModPrefsChangedKeysUserInfoKey];
    if ([changed isKindOfClass:[NSArray class]]) {
        for (id item in changed) {
            if ([item isKindOfClass:[NSString class]]) {
                NSString *k = (NSString *)item;
                if ([k isEqualToString:@"*"] || [watchedKeys containsObject:k]) return YES;
            }
        }
    }
    return NO;
}

#pragma mark - ZLModAppearanceCoordinator

@interface ZLModAppearanceCoordinator ()
@property (nonatomic, strong) NSHashTable<UITabBar *> *registeredTabBars;
@property (nonatomic, assign) BOOL hasAppliedAnyOverride;
@property (nonatomic, assign) BOOL isApplying;
@end

@implementation ZLModAppearanceCoordinator

+ (instancetype)shared {
    static ZLModAppearanceCoordinator *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ZLModAppearanceCoordinator alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _registeredTabBars = [NSHashTable weakObjectsHashTable];
    }
    return self;
}

- (void)captureBaselineForWindowIfNeeded:(UIWindow *)window {
    if (!window) return;
    if ([objc_getAssociatedObject(window, kZLModBaselineCapturedAssocKey) boolValue]) return;
    objc_setAssociatedObject(window, kZLModBaselineCapturedAssocKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(window, kZLModBaselineStyleAssocKey, @(window.overrideUserInterfaceStyle), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(window, kZLModBaselineTintAssocKey, window.tintColor ?: [NSNull null], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)captureBaselineForNavBarIfNeeded:(UINavigationBar *)navBar {
    if (!navBar) return;
    if ([objc_getAssociatedObject(navBar, kZLModBaselineCapturedAssocKey) boolValue]) return;
    objc_setAssociatedObject(navBar, kZLModBaselineCapturedAssocKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(navBar, kZLModBaselineTintAssocKey, navBar.tintColor ?: [NSNull null], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(navBar, kZLModBaselineBarTintAssocKey, navBar.barTintColor ?: [NSNull null], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(navBar, kZLModBaselineStdAppAssocKey, [navBar.standardAppearance copy] ?: [NSNull null], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(navBar, kZLModBaselineScrollAppAssocKey, [navBar.scrollEdgeAppearance copy] ?: [NSNull null], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(navBar, kZLModBaselineCompactAppAssocKey, [navBar.compactAppearance copy] ?: [NSNull null], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)captureBaselineForTabBarIfNeeded:(UITabBar *)tabBar {
    if (!tabBar) return;
    if ([objc_getAssociatedObject(tabBar, kZLModBaselineCapturedAssocKey) boolValue]) return;
    objc_setAssociatedObject(tabBar, kZLModBaselineCapturedAssocKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(tabBar, kZLModBaselineTintAssocKey, tabBar.tintColor ?: [NSNull null], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(tabBar, kZLModBaselineBarTintAssocKey, tabBar.barTintColor ?: [NSNull null], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(tabBar, kZLModBaselineStdAppAssocKey, [tabBar.standardAppearance copy] ?: [NSNull null], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(tabBar, kZLModBaselineScrollAppAssocKey, [tabBar.scrollEdgeAppearance copy] ?: [NSNull null], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)registerTabBar:(UITabBar *)tabBar {
    if (!tabBar) return;
    ZLModRunOnMainThread(^{
        [self captureBaselineForTabBarIfNeeded:tabBar];
        [self.registeredTabBars addObject:tabBar];
    });
}

- (void)restoreWindowBaseline:(UIWindow *)win {
    if (!win) return;
    if (![objc_getAssociatedObject(win, kZLModBaselineCapturedAssocKey) boolValue]) return;
    NSNumber *styleNum = objc_getAssociatedObject(win, kZLModBaselineStyleAssocKey);
    win.overrideUserInterfaceStyle = styleNum ? (UIUserInterfaceStyle)[styleNum integerValue] : UIUserInterfaceStyleUnspecified;
    id tintObj = objc_getAssociatedObject(win, kZLModBaselineTintAssocKey);
    win.tintColor = [tintObj isKindOfClass:[UIColor class]] ? (UIColor *)tintObj : nil;
}

- (void)restoreNavBarBaseline:(UINavigationBar *)navBar {
    if (!navBar) return;
    if (![objc_getAssociatedObject(navBar, kZLModBaselineCapturedAssocKey) boolValue]) return;
    id tintObj = objc_getAssociatedObject(navBar, kZLModBaselineTintAssocKey);
    id barTintObj = objc_getAssociatedObject(navBar, kZLModBaselineBarTintAssocKey);
    id stdApp = objc_getAssociatedObject(navBar, kZLModBaselineStdAppAssocKey);
    id scrollApp = objc_getAssociatedObject(navBar, kZLModBaselineScrollAppAssocKey);
    id compactApp = objc_getAssociatedObject(navBar, kZLModBaselineCompactAppAssocKey);
    navBar.tintColor = [tintObj isKindOfClass:[UIColor class]] ? (UIColor *)tintObj : nil;
    navBar.barTintColor = [barTintObj isKindOfClass:[UIColor class]] ? (UIColor *)barTintObj : nil;
    if ([stdApp isKindOfClass:[UINavigationBarAppearance class]]) {
        navBar.standardAppearance = [(UINavigationBarAppearance *)stdApp copy];
    }
    navBar.scrollEdgeAppearance = [scrollApp isKindOfClass:[UINavigationBarAppearance class]]
        ? [(UINavigationBarAppearance *)scrollApp copy]
        : nil;
    navBar.compactAppearance = [compactApp isKindOfClass:[UINavigationBarAppearance class]]
        ? [(UINavigationBarAppearance *)compactApp copy]
        : nil;
    [navBar setNeedsLayout];
}

- (void)restoreTabBarBaseline:(UITabBar *)tabBar {
    if (!tabBar) return;
    if (![objc_getAssociatedObject(tabBar, kZLModBaselineCapturedAssocKey) boolValue]) return;
    id tintObj = objc_getAssociatedObject(tabBar, kZLModBaselineTintAssocKey);
    id barTintObj = objc_getAssociatedObject(tabBar, kZLModBaselineBarTintAssocKey);
    id stdApp = objc_getAssociatedObject(tabBar, kZLModBaselineStdAppAssocKey);
    id scrollApp = objc_getAssociatedObject(tabBar, kZLModBaselineScrollAppAssocKey);
    tabBar.tintColor = [tintObj isKindOfClass:[UIColor class]] ? (UIColor *)tintObj : nil;
    tabBar.barTintColor = [barTintObj isKindOfClass:[UIColor class]] ? (UIColor *)barTintObj : nil;
    if ([stdApp isKindOfClass:[UITabBarAppearance class]]) {
        tabBar.standardAppearance = [(UITabBarAppearance *)stdApp copy];
    }
    tabBar.scrollEdgeAppearance = [scrollApp isKindOfClass:[UITabBarAppearance class]]
        ? [(UITabBarAppearance *)scrollApp copy]
        : nil;
    [tabBar setNeedsLayout];
}

- (NSMutableSet<UITabBar *> *)allKnownTabBarsInWindows:(NSArray<UIWindow *> *)windows {
    NSMutableSet<UITabBar *> *bars = [NSMutableSet set];
    for (UITabBar *bar in self.registeredTabBars.allObjects) {
        if (bar) [bars addObject:bar];
    }
    for (UIWindow *win in windows) {
        ZLModEnumerateSubviewsWithClass(win, [UITabBar class], ^(UIView *view) {
            if ([view isKindOfClass:[UITabBar class]]) {
                [bars addObject:(UITabBar *)view];
            }
        });
    }
    return bars;
}

- (void)restoreAllBaselines {
    ZLModRunOnMainThread(^{
        if (self.isApplying) return;
        if (!self.hasAppliedAnyOverride) return;
        self.isApplying = YES;
        @try {
            NSArray<UIWindow *> *windows = ZLModAllApplicationWindows();
            for (UIWindow *win in windows) {
                [self restoreWindowBaseline:win];
                ZLModEnumerateSubviewsWithClass(win, [UINavigationBar class], ^(UIView *view) {
                    [self restoreNavBarBaseline:(UINavigationBar *)view];
                });
            }
            for (UITabBar *tabBar in [self allKnownTabBarsInWindows:windows]) {
                [self restoreTabBarBaseline:tabBar];
            }
            self.hasAppliedAnyOverride = NO;
            ZLMOD_LOG(@"appearance baselines restored cleanly");
        } @finally {
            self.isApplying = NO;
        }
    });
}

- (void)reapplyAllAppearance {
    ZLModRunOnMainThread(^{
        if (self.isApplying) return;

        ZLModThemeManager *theme = [ZLModThemeManager shared];
        NSString *preset = [theme activePresetId];
        UIColor *customTint = ZLModColorFromHexString([theme customTintHex]);
        BOOL themeActive = (preset.length > 0) || (customTint != nil);
        BOOL glassTabBarActive = [[ZLModPreferences shared] boolForKey:kZLModGlassTabBar];

        if (!themeActive && !glassTabBarActive) {
            [self restoreAllBaselines];
            return;
        }

        self.isApplying = YES;
        @try {
            UIUserInterfaceStyle targetStyle = UIUserInterfaceStyleUnspecified;
            UIColor *accentColor = nil;
            UIColor *barBgColor = nil;

            if (themeActive) {
                accentColor = [UIColor colorWithRed:0.0 green:104.0 / 255.0 blue:1.0 alpha:1.0];
                if ([preset isEqualToString:@"classic_blue"]) {
                    accentColor = [UIColor colorWithRed:0.0 green:104.0 / 255.0 blue:1.0 alpha:1.0];
                } else if ([preset isEqualToString:@"dark_oled"]) {
                    targetStyle = UIUserInterfaceStyleDark;
                    accentColor = [UIColor colorWithRed:10.0 / 255.0 green:132.0 / 255.0 blue:1.0 alpha:1.0];
                    barBgColor = [UIColor colorWithRed:0.05 green:0.06 blue:0.08 alpha:0.96];
                } else if ([preset isEqualToString:@"pure_black"]) {
                    targetStyle = UIUserInterfaceStyleDark;
                    accentColor = [UIColor colorWithRed:48.0 / 255.0 green:209.0 / 255.0 blue:88.0 / 255.0 alpha:1.0];
                    barBgColor = [UIColor blackColor];
                } else if ([preset isEqualToString:@"ocean_teal"]) {
                    accentColor = [UIColor colorWithRed:0.0 green:180.0 / 255.0 blue:216.0 / 255.0 alpha:1.0];
                }
                if (customTint) {
                    accentColor = customTint;
                }
            }

            NSArray<UIWindow *> *windows = ZLModAllApplicationWindows();
            for (UIWindow *win in windows) {
                [self captureBaselineForWindowIfNeeded:win];
                if (themeActive) {
                    win.overrideUserInterfaceStyle = targetStyle;
                    win.tintColor = accentColor;
                } else {
                    [self restoreWindowBaseline:win];
                }

                ZLModEnumerateSubviewsWithClass(win, [UINavigationBar class], ^(UIView *view) {
                    UINavigationBar *navBar = (UINavigationBar *)view;
                    [self captureBaselineForNavBarIfNeeded:navBar];
                    if (!themeActive) {
                        [self restoreNavBarBaseline:navBar];
                        return;
                    }
                    // Start from clean baseline appearance before layering theme background.
                    id baseStd = objc_getAssociatedObject(navBar, kZLModBaselineStdAppAssocKey);
                    id baseScroll = objc_getAssociatedObject(navBar, kZLModBaselineScrollAppAssocKey);
                    navBar.tintColor = accentColor;
                    if (barBgColor) {
                        UINavigationBarAppearance *app = [baseStd isKindOfClass:[UINavigationBarAppearance class]]
                            ? [(UINavigationBarAppearance *)baseStd copy]
                            : [[UINavigationBarAppearance alloc] init];
                        [app configureWithOpaqueBackground];
                        app.backgroundColor = barBgColor;
                        navBar.standardAppearance = app;
                        navBar.scrollEdgeAppearance = app;
                        navBar.barTintColor = barBgColor;
                    } else {
                        id baseBarTint = objc_getAssociatedObject(navBar, kZLModBaselineBarTintAssocKey);
                        navBar.barTintColor = [baseBarTint isKindOfClass:[UIColor class]] ? (UIColor *)baseBarTint : nil;
                        if ([baseStd isKindOfClass:[UINavigationBarAppearance class]]) {
                            navBar.standardAppearance = [(UINavigationBarAppearance *)baseStd copy];
                        }
                        navBar.scrollEdgeAppearance = [baseScroll isKindOfClass:[UINavigationBarAppearance class]]
                            ? [(UINavigationBarAppearance *)baseScroll copy]
                            : nil;
                    }
                    [navBar setNeedsLayout];
                });
            }

            // Coordinate all tab bars cleanly: always compose from baseline -> theme -> glass material.
            for (UITabBar *tabBar in [self allKnownTabBarsInWindows:windows]) {
                [self captureBaselineForTabBarIfNeeded:tabBar];
                [self.registeredTabBars addObject:tabBar];

                id baseTint = objc_getAssociatedObject(tabBar, kZLModBaselineTintAssocKey);
                id baseBarTint = objc_getAssociatedObject(tabBar, kZLModBaselineBarTintAssocKey);
                id baseStd = objc_getAssociatedObject(tabBar, kZLModBaselineStdAppAssocKey);
                id baseScroll = objc_getAssociatedObject(tabBar, kZLModBaselineScrollAppAssocKey);

                tabBar.tintColor = themeActive
                    ? accentColor
                    : ([baseTint isKindOfClass:[UIColor class]] ? (UIColor *)baseTint : nil);

                if (glassTabBarActive) {
                    UITabBarAppearance *glassApp = [baseStd isKindOfClass:[UITabBarAppearance class]]
                        ? [(UITabBarAppearance *)baseStd copy]
                        : [[UITabBarAppearance alloc] init];
                    [glassApp configureWithDefaultBackground];
                    glassApp.backgroundEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial];
                    glassApp.backgroundColor = barBgColor
                        ? [barBgColor colorWithAlphaComponent:0.25]
                        : [UIColor colorWithWhite:1.0 alpha:0.12];
                    tabBar.standardAppearance = glassApp;
                    tabBar.scrollEdgeAppearance = glassApp;
                    tabBar.barTintColor = nil;
                } else if (themeActive && barBgColor) {
                    UITabBarAppearance *themeApp = [baseStd isKindOfClass:[UITabBarAppearance class]]
                        ? [(UITabBarAppearance *)baseStd copy]
                        : [[UITabBarAppearance alloc] init];
                    [themeApp configureWithOpaqueBackground];
                    themeApp.backgroundColor = barBgColor;
                    tabBar.standardAppearance = themeApp;
                    tabBar.scrollEdgeAppearance = themeApp;
                    tabBar.barTintColor = barBgColor;
                } else {
                    tabBar.barTintColor = [baseBarTint isKindOfClass:[UIColor class]] ? (UIColor *)baseBarTint : nil;
                    if ([baseStd isKindOfClass:[UITabBarAppearance class]]) {
                        tabBar.standardAppearance = [(UITabBarAppearance *)baseStd copy];
                    }
                    tabBar.scrollEdgeAppearance = [baseScroll isKindOfClass:[UITabBarAppearance class]]
                        ? [(UITabBarAppearance *)baseScroll copy]
                        : nil;
                }
                [tabBar setNeedsLayout];
            }

            self.hasAppliedAnyOverride = YES;
        } @finally {
            self.isApplying = NO;
        }
    });
}

@end

#pragma mark - ZLModThemeManager

@implementation ZLModThemeManager

+ (instancetype)shared {
    static ZLModThemeManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ZLModThemeManager alloc] init];
    });
    return instance;
}

- (NSArray<NSString *> *)availablePresetIds {
    return @[
        @"",
        @"classic_blue",
        @"dark_oled",
        @"pure_black",
        @"ocean_teal"
    ];
}

- (NSString *)displayNameForPreset:(NSString *)presetId {
    if (!presetId || presetId.length == 0) return @"Mặc định hệ thống (Tắt)";
    if ([presetId isEqualToString:@"classic_blue"]) return @"Zalo Classic Blue (#0068FF)";
    if ([presetId isEqualToString:@"dark_oled"]) return @"Dark OLED (#0A84FF)";
    if ([presetId isEqualToString:@"pure_black"]) return @"Pure Black (#30D158)";
    if ([presetId isEqualToString:@"ocean_teal"]) return @"Ocean Teal (#00B4D8)";
    return presetId;
}

- (NSString *)activePresetId {
    NSString *preset = [[ZLModPreferences shared] stringForKey:kZLModThemePreset defaultValue:@""];
    if (![[self availablePresetIds] containsObject:preset]) return @"";
    return preset ?: @"";
}

- (NSString *)customTintHex {
    NSString *raw = [[ZLModPreferences shared] stringForKey:kZLModThemeTintHex defaultValue:@""];
    return ZLModNormalizeHexString(raw);
}

- (BOOL)applyPresetNamed:(NSString *)presetId {
    NSString *normalized = presetId ?: @"";
    if (![[self availablePresetIds] containsObject:normalized]) {
        return NO;
    }
    [[ZLModPreferences shared] setString:normalized forKey:kZLModThemePreset];
    [[ZLModAppearanceCoordinator shared] reapplyAllAppearance];
    [[NSNotificationCenter defaultCenter] postNotificationName:ZLModThemeDidChangeNotification object:nil];
    return YES;
}

- (BOOL)applyCustomTintHex:(NSString *)hex {
    NSString *trimmed = [hex isKindOfClass:[NSString class]]
        ? [hex stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
        : @"";

    if (trimmed.length == 0) {
        [[ZLModPreferences shared] removeObjectForKey:kZLModThemeTintHex];
        [[ZLModAppearanceCoordinator shared] reapplyAllAppearance];
        [[NSNotificationCenter defaultCenter] postNotificationName:ZLModThemeDidChangeNotification object:nil];
        return YES;
    }

    NSString *normalized = ZLModNormalizeHexString(trimmed);
    if (normalized.length == 0) {
        ZLMOD_LOG(@"theme rejected invalid hex tint input");
        return NO;
    }

    [[ZLModPreferences shared] setString:normalized forKey:kZLModThemeTintHex];
    [[ZLModAppearanceCoordinator shared] reapplyAllAppearance];
    [[NSNotificationCenter defaultCenter] postNotificationName:ZLModThemeDidChangeNotification object:nil];
    return YES;
}

- (void)resetTheme {
    [[ZLModPreferences shared] performBatchUpdates:^{
        [[ZLModPreferences shared] removeObjectForKey:kZLModThemePreset];
        [[ZLModPreferences shared] removeObjectForKey:kZLModThemeTintHex];
    }];
    [[ZLModAppearanceCoordinator shared] reapplyAllAppearance];
    [[NSNotificationCenter defaultCenter] postNotificationName:ZLModThemeDidChangeNotification object:nil];
}

- (void)refreshAppChrome {
    [[ZLModAppearanceCoordinator shared] reapplyAllAppearance];
}

@end

#pragma mark - Installer

static BOOL gThemeInstalled = NO;

void ZLModThemeInstall(void) {
    if (gThemeInstalled) return;
    gThemeInstalled = YES;

    ZLModThemeManager *mgr = [ZLModThemeManager shared];
    NSSet<NSString *> *watchedKeys = [NSSet setWithObjects:
                                      kZLModThemePreset,
                                      kZLModThemeTintHex,
                                      kZLModGlassTabBar,
                                      nil];

    [[NSNotificationCenter defaultCenter] addObserverForName:ZLModPrefsDidChangeNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        if (ZLModNotificationTouchesKeys(note, watchedKeys)) {
            [[ZLModAppearanceCoordinator shared] reapplyAllAppearance];
        }
    }];

    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        BOOL hasTheme = (mgr.activePresetId.length > 0 || mgr.customTintHex.length > 0);
        BOOL hasGlass = [[ZLModPreferences shared] boolForKey:kZLModGlassTabBar];
        if (hasTheme || hasGlass) {
            [[ZLModAppearanceCoordinator shared] reapplyAllAppearance];
        }
    }];

    [[NSNotificationCenter defaultCenter] addObserverForName:ZLModAccountDidChangeNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *note) {
        [[ZLModAppearanceCoordinator shared] reapplyAllAppearance];
    }];

    if (mgr.activePresetId.length > 0 ||
        mgr.customTintHex.length > 0 ||
        [[ZLModPreferences shared] boolForKey:kZLModGlassTabBar]) {
        ZLModRunOnMainThread(^{
            [[ZLModAppearanceCoordinator shared] reapplyAllAppearance];
        });
    }

    ZLModSetModuleStatus(@"Theme",
                         ZLModModuleStatusHookInstalled,
                         [NSString stringWithFormat:@"preset=%@ tint=%@ (unified coordinator)",
                          mgr.activePresetId.length > 0 ? mgr.activePresetId : @"default",
                          mgr.customTintHex.length > 0 ? mgr.customTintHex : @"default"]);
    ZLMOD_LOG(@"theme installed (preset=%@)", mgr.activePresetId.length > 0 ? mgr.activePresetId : @"default");
}
