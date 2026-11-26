// language: Objective-C, file: ZLModAds.m, target: iOS 15.1+ (Zalo 26.10.02 & 26.11.01, arm64)
// Reversible Advertisement Visibility Management (MODULE 06):
//   - Layer 1 (network): ZLModURIFilter.m intercepts ad endpoints across NSURLProtocol & NSURLSessionConfiguration.
//   - Layer 2 (views): tracks live ad views (ZInstantFeedAdsView, LocationOAAdsCell, etc.) in a weak NSHashTable,
//     captures each view's original visual state before disarming, and cleanly restores visibility when toggled OFF.

#import "ZLMod.h"

typedef void (*ZLModV0)(id, SEL);
typedef void (*ZLModV1Bool)(id, SEL, BOOL);

static const void *kZLModAdOrigAlphaAssocKey = &kZLModAdOrigAlphaAssocKey;
static const void *kZLModAdOrigUserIntAssocKey = &kZLModAdOrigUserIntAssocKey;
static const void *kZLModAdOrigHiddenAssocKey = &kZLModAdOrigHiddenAssocKey;
static const void *kZLModAdDisarmedAssocKey = &kZLModAdDisarmedAssocKey;

static NSHashTable<UIView *> *gTrackedAdViews = nil;
static BOOL gAdsObserversInstalled = NO;

static BOOL ZLModAdsClassNameMatches(Class cls) {
    NSString *name = [NSString stringWithUTF8String:class_getName(cls)].lowercaseString;
    if ([name containsString:@"adsview"]) return YES;
    if ([name containsString:@"adscell"]) return YES;
    if ([name containsString:@"adsbanner"]) return YES;
    if ([name containsString:@"advert"]) return YES;
    if ([name containsString:@"promoted"]) return YES;
    return NO;
}

static BOOL ZLModAdsClassIsView(Class cls) {
    Class cursor = cls;
    while (cursor) {
        if (cursor == [UIView class]) return YES;
        cursor = class_getSuperclass(cursor);
    }
    return NO;
}

static void ZLModApplyHideStateToAdViewOnMain(UIView *view, BOOL hideAds) {
    if (!view || ![view isKindOfClass:[UIView class]]) return;
    if (!gTrackedAdViews) {
        gTrackedAdViews = [NSHashTable weakObjectsHashTable];
    }
    [gTrackedAdViews addObject:view];

    SEL setHiddenSel = @selector(setHidden:);
    IMP baseSetHidden = class_getMethodImplementation([UIView class], setHiddenSel);

    if (hideAds) {
        if (![objc_getAssociatedObject(view, kZLModAdDisarmedAssocKey) boolValue]) {
            objc_setAssociatedObject(view, kZLModAdOrigAlphaAssocKey, @(view.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(view, kZLModAdOrigUserIntAssocKey, @(view.userInteractionEnabled), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(view, kZLModAdOrigHiddenAssocKey, @(view.hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(view, kZLModAdDisarmedAssocKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        view.alpha = 0.0;
        view.userInteractionEnabled = NO;
        if (baseSetHidden) {
            ((void (*)(id, SEL, BOOL))baseSetHidden)(view, setHiddenSel, YES);
        }
    } else if ([objc_getAssociatedObject(view, kZLModAdDisarmedAssocKey) boolValue]) {
        NSNumber *origAlpha = objc_getAssociatedObject(view, kZLModAdOrigAlphaAssocKey);
        NSNumber *origUserInt = objc_getAssociatedObject(view, kZLModAdOrigUserIntAssocKey);
        NSNumber *origHidden = objc_getAssociatedObject(view, kZLModAdOrigHiddenAssocKey);
        view.alpha = origAlpha ? origAlpha.doubleValue : 1.0;
        view.userInteractionEnabled = origUserInt ? origUserInt.boolValue : YES;
        if (baseSetHidden) {
            ((void (*)(id, SEL, BOOL))baseSetHidden)(view, setHiddenSel, origHidden ? origHidden.boolValue : NO);
        }
        objc_setAssociatedObject(view, kZLModAdDisarmedAssocKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

static void ZLModRefreshAllTrackedAdViews(void) {
    BOOL hideAds = [[ZLModPreferences shared] boolForKey:kZLModHideAds];
    ZLModRunOnMainThread(^{
        for (UIView *view in gTrackedAdViews) {
            ZLModApplyHideStateToAdViewOnMain(view, hideAds);
        }
    });
}

static NSUInteger ZLModAdsHardenViews(void) {
    SEL didMoveSel = sel_registerName("didMoveToSuperview");
    SEL setHiddenSel = sel_registerName("setHidden:");
    __block NSUInteger hookCount = 0;

    ZLModEnumerateAppClasses(^(Class cls) {
        if (!ZLModAdsClassIsView(cls)) return;
        if (!ZLModAdsClassNameMatches(cls)) return;

        if (ZLModClassHasInstanceMethod(cls, didMoveSel)) {
            IMP original = class_getMethodImplementation(cls, didMoveSel);
            if (ZLModReplaceMethod(cls, didMoveSel, 0, "v", ^(id self) {
                if (original) ((ZLModV0)original)(self, didMoveSel);
                BOOL hide = [[ZLModPreferences shared] boolForKey:kZLModHideAds];
                ZLModRunOnMainThread(^{
                    ZLModApplyHideStateToAdViewOnMain((UIView *)self, hide);
                });
            })) {
                hookCount++;
            }
        }

        if (ZLModClassHasInstanceMethod(cls, setHiddenSel)) {
            IMP original = class_getMethodImplementation(cls, setHiddenSel);
            if (ZLModReplaceMethod(cls, setHiddenSel, 1, "v", ^(id self, BOOL hidden) {
                BOOL force = [[ZLModPreferences shared] boolForKey:kZLModHideAds];
                if (force) {
                    if ([self isKindOfClass:[UIView class]]) {
                        objc_setAssociatedObject(self, kZLModAdOrigHiddenAssocKey, @(hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    }
                    if (original) ((ZLModV1Bool)original)(self, setHiddenSel, YES);
                    ZLModRunOnMainThread(^{
                        ZLModApplyHideStateToAdViewOnMain((UIView *)self, YES);
                    });
                } else {
                    if (original) ((ZLModV1Bool)original)(self, setHiddenSel, hidden);
                }
            })) {
                hookCount++;
            }
        }
    });
    return hookCount;
}

void ZLModAdsInstall(void) {
    NSUInteger count = ZLModAdsHardenViews();
    if (!gAdsObserversInstalled) {
        gAdsObserversInstalled = YES;
        [[NSNotificationCenter defaultCenter] addObserverForName:ZLModPrefsDidChangeNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            NSString *key = [note.object isKindOfClass:[NSString class]] ? (NSString *)note.object : @"";
            if ([key isEqualToString:kZLModHideAds] || [key isEqualToString:@"*"]) {
                ZLModRefreshAllTrackedAdViews();
            }
        }];
    }
    ZLModSetModuleStatus(@"Ads",
                         count > 0 ? ZLModModuleStatusHookInstalled : ZLModModuleStatusNotInstalled,
                         [NSString stringWithFormat:@"viewHooks=%lu", (unsigned long)count]);
    ZLMOD_LOG(@"ads module installed (hooks=%lu)", (unsigned long)count);
}
