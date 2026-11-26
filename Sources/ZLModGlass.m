// language: Objective-C, file: ZLModGlass.m, target: iOS 15.1+ (Zalo 26.10.02 & 26.11.01, arm64)
// Blur-style tab bar material (MODULE 09).
//
// Zalo opts out of the iOS 26 redesign (UIDesignRequiresCompatibility=YES), so the system
// tab bar cannot adopt Liquid Glass. Instead, ZLMod applies UIBlurEffectStyleSystemUltraThinMaterial
// through ZLModAppearanceCoordinator so Theme presets and Tab Bar blur compose cleanly on top
// of a single captured baseline and restore cleanly when switched off.

#import "ZLMod.h"

typedef void (*ZLModV1Bool)(id, SEL, BOOL);

static __weak id gTabBarController = nil;
static BOOL gGlassInstalled = NO;

NSString *ZLModGlassMaterialDescription(void) {
    return @"System ultra-thin blur material (UIBlurEffect)";
}

static UITabBar *ZLModFindUITabBar(UIView *root, NSUInteger depth) {
    if (!root || depth > 6) return nil;
    if ([root isKindOfClass:[UITabBar class]]) return (UITabBar *)root;
    for (UIView *sub in root.subviews) {
        UITabBar *found = ZLModFindUITabBar(sub, depth + 1);
        if (found) return found;
    }
    return nil;
}

static UITabBar *ZLModResolveTabBar(UIViewController *controller) {
    if ([controller isKindOfClass:[UITabBarController class]]) {
        return ((UITabBarController *)controller).tabBar;
    }
    return ZLModFindUITabBar(controller.view, 0);
}

static void ZLModRegisterCurrentTabBarIfAvailable(void) {
    id vc = gTabBarController;
    if (![vc isKindOfClass:[UIViewController class]]) return;
    UITabBar *bar = ZLModResolveTabBar((UIViewController *)vc);
    if (bar) {
        [[ZLModAppearanceCoordinator shared] registerTabBar:bar];
    }
}

static void ZLModGlassRemove(void) {
    ZLModRegisterCurrentTabBarIfAvailable();
    [[ZLModAppearanceCoordinator shared] reapplyAllAppearance];
    ZLMOD_LOG(@"glass appearance removed via coordinator");
}

static void ZLModGlassApply(void) {
    ZLModRunOnMainThread(^{
        ZLModRegisterCurrentTabBarIfAvailable();
        if (![[ZLModPreferences shared] boolForKey:kZLModGlassTabBar]) return;
        [[ZLModAppearanceCoordinator shared] reapplyAllAppearance];
        ZLMOD_LOG(@"glass appearance applied via coordinator — %@", ZLModGlassMaterialDescription());
    });
}

static void ZLModGlassRefreshForCurrentUI(void) {
    ZLModRunOnMainThread(^{
        if (![[ZLModPreferences shared] boolForKey:kZLModGlassTabBar]) {
            ZLModGlassRemove();
            return;
        }
        ZLModGlassApply();
    });
}

static BOOL ZLModNoteMentionsGlass(NSNotification *note) {
    id obj = note.object;
    if ([obj isKindOfClass:[NSString class]]) {
        NSString *key = (NSString *)obj;
        if ([key isEqualToString:kZLModGlassTabBar] || [key isEqualToString:@"*"]) return YES;
    }
    NSArray *changed = note.userInfo[ZLModPrefsChangedKeysUserInfoKey];
    if ([changed isKindOfClass:[NSArray class]]) {
        for (id item in changed) {
            if ([item isKindOfClass:[NSString class]]) {
                NSString *k = (NSString *)item;
                if ([k isEqualToString:kZLModGlassTabBar] || [k isEqualToString:@"*"]) return YES;
            }
        }
    }
    return NO;
}

void ZLModGlassInstall(void) {
    if (gGlassInstalled) return;
    gGlassInstalled = YES;

    Class tabCls = NSClassFromString(@"ZaloTabBarViewController");
    if (!tabCls) {
        ZLModSetModuleStatus(@"Glass", ZLModModuleStatusNotInstalled,
                             @"ZaloTabBarViewController not found");
        ZLMOD_LOG(@"tab bar class not found — glass module idle");
        return;
    }

    SEL appearSel = sel_registerName("viewDidAppear:");
    IMP appearOrig = class_getMethodImplementation(tabCls, appearSel);
    BOOL hooked = ZLModReplaceMethod(tabCls, appearSel, 1, "v", ^(id self, BOOL animated) {
        ((ZLModV1Bool)appearOrig)(self, appearSel, animated);
        gTabBarController = self;
        // Defer one runloop turn so UIKit finishes its own layout pass first.
        dispatch_async(dispatch_get_main_queue(), ^{
            ZLModRegisterCurrentTabBarIfAvailable();
            if ([[ZLModPreferences shared] boolForKey:kZLModGlassTabBar]) {
                ZLModGlassApply();
            } else {
                [[ZLModAppearanceCoordinator shared] reapplyAllAppearance];
            }
        });
    });

    [[NSNotificationCenter defaultCenter] addObserverForName:ZLModPrefsDidChangeNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        if (ZLModNoteMentionsGlass(note)) {
            ZLModGlassRefreshForCurrentUI();
        }
    }];

    ZLModSetModuleStatus(@"Glass",
                         hooked ? ZLModModuleStatusHookInstalled : ZLModModuleStatusNotInstalled,
                         ZLModGlassMaterialDescription());
    ZLMOD_LOG(@"glass installed — %@", ZLModGlassMaterialDescription());
}
