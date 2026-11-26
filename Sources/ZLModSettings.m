// language: Objective-C, file: ZLModSettings.m, target: iOS 15.1+ (Zalo 26.10.02 & 26.11.01, arm64)
// Safe Native Settings Integration (MODULE 04):
//   - Per-VC associated state (no stale static globals across recreated controllers).
//   - Safe property-based cloning (copyWithZone: / declared ObjC properties only — ZERO raw memcpy/CFRetain).
//   - Zero-index-shift fallback via UINavigationItem bar button (never shifts UITableView indexPaths).
//   - Configurable Shake Gesture respecting kZLModDisableShakeToOpen and active text input (Undo Typing safe).

#import "ZLMod.h"

static const void *kZLModSettingsVCStateAssocKey = &kZLModSettingsVCStateAssocKey;
static const NSUInteger kZLModMaxSafeBFNodes = 1500;
static const NSUInteger kZLModMaxSafeBFDepth = 5;
static Class gSettingsClass = Nil;

static NSArray<NSString *> *ZLModKnownAccountTitleValues(void) {
    return @[@"Tài khoản và bảo mật",
             @"Account and security",
             @"00Zh8W",
             @"tabme.section_items.account_security.title",
             @"tabme_account_security"];
}

#pragma mark - Per-VC Associated State

@interface ZLModSettingsVCState : NSObject
@property (nonatomic, strong) id injectedRow;
@property (nonatomic, strong) NSArray<NSArray *> *sectionSnapshot;
@property (nonatomic, assign) BOOL snapshotAligned;
@property (nonatomic, assign) BOOL navFallbackInstalled;
@property (nonatomic, assign) NSInteger retryCount;
@end

@implementation ZLModSettingsVCState
@end

static ZLModSettingsVCState *ZLModStateForSettingsVC(id vc) {
    if (!vc) return nil;
    ZLModSettingsVCState *state = objc_getAssociatedObject(vc, kZLModSettingsVCStateAssocKey);
    if (!state) {
        state = [[ZLModSettingsVCState alloc] init];
        objc_setAssociatedObject(vc, kZLModSettingsVCStateAssocKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return state;
}

#pragma mark - Safe Property-Based Cloning (Zero raw memcpy / CFRetain)

static id ZLModSafeCloneCellObject(id source) {
    if (!source) return nil;
    Class cls = object_getClass(source);
    if (!cls) return nil;

    // 1. Prefer genuine NSCopying implementation if it returns a distinct instance.
    if ([source respondsToSelector:@selector(copyWithZone:)]) {
        @try {
            id copy = [source copy];
            if (copy && copy != source && object_getClass(copy) == cls) {
                return copy;
            }
        } @catch (__unused NSException *e) {}
    }

    // 2. Safe KVC property copy across class hierarchy using declared ObjC properties only.
    id clone = nil;
    @try {
        clone = [[cls alloc] init];
    } @catch (__unused NSException *e) {
        return nil;
    }
    if (!clone) return nil;

    Class cursor = cls;
    while (cursor && cursor != [NSObject class]) {
        unsigned int propCount = 0;
        objc_property_t *props = class_copyPropertyList(cursor, &propCount);
        for (unsigned int i = 0; i < propCount; i++) {
            const char *rawName = property_getName(props[i]);
            if (!rawName || rawName[0] == '\0') continue;

            // Skip readonly or weak properties to preserve ARC invariants.
            const char *attrs = property_getAttributes(props[i]);
            if (attrs && (strstr(attrs, ",R") != NULL || strstr(attrs, ",W") != NULL)) {
                continue;
            }

            NSString *propName = [NSString stringWithUTF8String:rawName];
            if (propName.length == 0) continue;

            SEL getterSel = NSSelectorFromString(propName);
            NSString *setterName = [NSString stringWithFormat:@"set%@%@:",
                                    [[propName substringToIndex:1] uppercaseString],
                                    [propName substringFromIndex:1]];
            SEL setterSel = NSSelectorFromString(setterName);

            if (![source respondsToSelector:getterSel] || ![clone respondsToSelector:setterSel]) {
                continue;
            }

            @try {
                id val = [source valueForKey:propName];
                if (val && val != [NSNull null]) {
                    [clone setValue:val forKey:propName];
                }
            } @catch (__unused NSException *e) {}
        }
        if (props) free(props);
        cursor = class_getSuperclass(cursor);
    }
    return clone;
}

static BOOL ZLModSafeRetitleCellObject(id object, NSString *newTitle, NSString **outOldValue) {
    if (!object || newTitle.length == 0) return NO;
    NSArray<NSString *> *known = ZLModKnownAccountTitleValues();

    NSArray<NSString *> *titleKeys = @[
        @"title", @"name", @"text", @"cellTitle", @"localizedTitle", @"mainTitle"
    ];
    for (NSString *key in titleKeys) {
        @try {
            id value = [object valueForKey:key];
            if ([value isKindOfClass:[NSString class]]) {
                NSString *strVal = (NSString *)value;
                if ([known containsObject:strVal] ||
                    [strVal localizedCaseInsensitiveContainsString:@"account_security"] ||
                    [strVal localizedCaseInsensitiveContainsString:@"tài khoản và bảo mật"]) {
                    if (outOldValue) *outOldValue = strVal;
                    [object setValue:newTitle forKey:key];
                    return YES;
                }
            }
        } @catch (__unused NSException *e) {}
    }

    // Fallback: scan declared NSString properties with safe setter.
    Class cursor = object_getClass(object);
    while (cursor && cursor != [NSObject class]) {
        unsigned int count = 0;
        objc_property_t *props = class_copyPropertyList(cursor, &count);
        for (unsigned int i = 0; i < count; i++) {
            const char *attrs = property_getAttributes(props[i]);
            if (!attrs || strstr(attrs, ",R") != NULL || strstr(attrs, "NSString") == NULL) continue;
            const char *rawName = property_getName(props[i]);
            if (!rawName) continue;
            NSString *propName = [NSString stringWithUTF8String:rawName];
            @try {
                id val = [object valueForKey:propName];
                if ([val isKindOfClass:[NSString class]] && [known containsObject:(NSString *)val]) {
                    if (outOldValue) *outOldValue = (NSString *)val;
                    [object setValue:newTitle forKey:propName];
                    free(props);
                    return YES;
                }
            } @catch (__unused NSException *e) {}
        }
        if (props) free(props);
        cursor = class_getSuperclass(cursor);
    }
    return NO;
}

#pragma mark - Bounded Model Discovery

@interface ZLModSettingsBFSNode : NSObject
@property (nonatomic, strong) id node;
@property (nonatomic, strong) id parent;
@property (nonatomic, strong) ZLModSettingsBFSNode *parentEntry;
@property (nonatomic, assign) NSUInteger indexInParent;
@property (nonatomic, strong) id keyInParent;
@property (nonatomic, copy) NSString *parentPropertyName;
@end

@implementation ZLModSettingsBFSNode
@end

static BOOL ZLModShouldSkipSettingsNode(id node) {
    return [node isKindOfClass:[NSString class]] || [node isKindOfClass:[NSNumber class]] ||
           [node isKindOfClass:[NSData class]] || [node isKindOfClass:[NSDate class]] ||
           [node isKindOfClass:[NSURL class]] || [node isKindOfClass:[NSSet class]] ||
           [node isKindOfClass:[NSValue class]] || [node isKindOfClass:[NSNull class]] ||
           [node isKindOfClass:[UIView class]] || [node isKindOfClass:[UIViewController class]];
}

static NSMutableArray<ZLModSettingsBFSNode *> *ZLModCollectSettingsNodes(id root, NSUInteger maxDepth) {
    NSMutableArray<ZLModSettingsBFSNode *> *all = [NSMutableArray array];
    NSMutableArray<ZLModSettingsBFSNode *> *queue = [NSMutableArray array];
    NSMutableSet<NSValue *> *seen = [NSMutableSet set];

    ZLModSettingsBFSNode *rootNode = [ZLModSettingsBFSNode new];
    rootNode.node = root;
    [queue addObject:rootNode];

    NSUInteger depth = 0;
    while (queue.count > 0 && depth < maxDepth && all.count < kZLModMaxSafeBFNodes) {
        NSMutableArray<ZLModSettingsBFSNode *> *next = [NSMutableArray array];
        for (ZLModSettingsBFSNode *entry in queue) {
            if (all.count >= kZLModMaxSafeBFNodes) break;
            id node = entry.node;
            if (!node || ZLModShouldSkipSettingsNode(node)) continue;
            NSValue *ptr = [NSValue valueWithPointer:(__bridge const void *)node];
            if ([seen containsObject:ptr]) continue;
            [seen addObject:ptr];
            [all addObject:entry];

            if ([node isKindOfClass:[NSArray class]]) {
                NSArray *array = (NSArray *)node;
                for (NSUInteger i = 0; i < array.count; i++) {
                    id child = array[i];
                    if (!child || ZLModShouldSkipSettingsNode(child)) continue;
                    ZLModSettingsBFSNode *n = [ZLModSettingsBFSNode new];
                    n.node = child;
                    n.parent = node;
                    n.parentEntry = entry;
                    n.indexInParent = i;
                    [next addObject:n];
                }
            } else if ([node isKindOfClass:[NSDictionary class]]) {
                NSDictionary *dict = (NSDictionary *)node;
                for (id key in dict) {
                    id child = dict[key];
                    if (!child || ZLModShouldSkipSettingsNode(child)) continue;
                    ZLModSettingsBFSNode *n = [ZLModSettingsBFSNode new];
                    n.node = child;
                    n.parent = node;
                    n.parentEntry = entry;
                    n.keyInParent = key;
                    [next addObject:n];
                }
            } else {
                Class cursor = object_getClass(node);
                while (cursor && cursor != [NSObject class]) {
                    unsigned int propCount = 0;
                    objc_property_t *props = class_copyPropertyList(cursor, &propCount);
                    for (unsigned int i = 0; i < propCount; i++) {
                        const char *attrs = property_getAttributes(props[i]);
                        if (!attrs || attrs[1] != '@') continue;
                        const char *rawName = property_getName(props[i]);
                        if (!rawName) continue;
                        NSString *propName = [NSString stringWithUTF8String:rawName];
                        id child = nil;
                        @try { child = [node valueForKey:propName]; } @catch (__unused NSException *e) { continue; }
                        if (!child || ZLModShouldSkipSettingsNode(child)) continue;
                        ZLModSettingsBFSNode *n = [ZLModSettingsBFSNode new];
                        n.node = child;
                        n.parent = node;
                        n.parentEntry = entry;
                        n.parentPropertyName = propName;
                        [next addObject:n];
                    }
                    if (props) free(props);
                    cursor = class_getSuperclass(cursor);
                }
            }
        }
        [queue setArray:next];
        depth++;
    }
    return all;
}

static BOOL ZLModPlaceSettingsValue(id value, ZLModSettingsBFSNode *child) {
    id parent = child.parent;
    @try {
        if ([parent isKindOfClass:[NSMutableArray class]]) {
            [(NSMutableArray *)parent replaceObjectAtIndex:child.indexInParent withObject:value];
            return YES;
        }
        if ([parent isKindOfClass:[NSMutableDictionary class]] && child.keyInParent) {
            [(NSMutableDictionary *)parent setObject:value forKey:child.keyInParent];
            return YES;
        }
        if (child.parentPropertyName.length > 0) {
            [parent setValue:value forKey:child.parentPropertyName];
            return YES;
        }
    } @catch (__unused NSException *e) {}
    return NO;
}

static NSMutableArray *ZLModMakeMutableSettingsChain(ZLModSettingsBFSNode *match) {
    id node = match.node;
    if (![node isKindOfClass:[NSArray class]]) return nil;
    id value = [node isKindOfClass:[NSMutableArray class]] ? node : [node mutableCopy];
    if (![value isKindOfClass:[NSMutableArray class]]) return nil;

    ZLModSettingsBFSNode *child = match;
    while (child) {
        if (ZLModPlaceSettingsValue(value, child)) return (NSMutableArray *)value;
        id parent = child.parent;
        if (![parent isKindOfClass:[NSArray class]] && ![parent isKindOfClass:[NSDictionary class]]) return nil;
        id newParent = [parent mutableCopy];
        if (!newParent) return nil;
        if ([newParent isKindOfClass:[NSMutableArray class]]) {
            [(NSMutableArray *)newParent replaceObjectAtIndex:child.indexInParent withObject:value];
        } else if ([newParent isKindOfClass:[NSMutableDictionary class]] && child.keyInParent) {
            [(NSMutableDictionary *)newParent setObject:value forKey:child.keyInParent];
        } else {
            return nil;
        }
        value = newParent;
        child = child.parentEntry;
    }
    return nil;
}

static id ZLModFetchAccountObject(id vc) {
    if (!vc) return nil;
    @try {
        id val = [vc valueForKey:@"accountAndSecurityObject"];
        if (val) return val;
    } @catch (__unused NSException *e) {}
    return nil;
}

static NSMutableArray *ZLModFindContainerForAccountObject(id vc, id target, NSUInteger *outIndex) {
    if (!vc || !target) return nil;
    // Stage 1: Direct getter getArrangedTableContent (fast, avoids deep BFS)
    SEL arrangedSel = sel_registerName("getArrangedTableContent");
    if ([vc respondsToSelector:arrangedSel]) {
        id arranged = nil;
        @try {
            IMP imp = [vc methodForSelector:arrangedSel];
            if (imp) arranged = ((id (*)(id, SEL))imp)(vc, arrangedSel);
        } @catch (__unused NSException *e) {}
        if ([arranged isKindOfClass:[NSMutableArray class]] &&
            [arranged indexOfObjectIdenticalTo:target] != NSNotFound) {
            if (outIndex) *outIndex = [arranged indexOfObjectIdenticalTo:target];
            return arranged;
        }
        if (arranged && arranged != vc) {
            for (ZLModSettingsBFSNode *entry in ZLModCollectSettingsNodes(arranged, 4)) {
                if ([entry.node isKindOfClass:[NSArray class]] &&
                    [(NSArray *)entry.node indexOfObjectIdenticalTo:target] != NSNotFound) {
                    NSMutableArray *container = ZLModMakeMutableSettingsChain(entry);
                    if (container) {
                        if (outIndex) *outIndex = [container indexOfObjectIdenticalTo:target];
                        return container;
                    }
                }
            }
        }
    }

    // Stage 2: Bounded property graph BFS on vc
    for (ZLModSettingsBFSNode *entry in ZLModCollectSettingsNodes(vc, kZLModMaxSafeBFDepth)) {
        if ([entry.node isKindOfClass:[NSArray class]] &&
            [(NSArray *)entry.node indexOfObjectIdenticalTo:target] != NSNotFound) {
            NSMutableArray *container = ZLModMakeMutableSettingsChain(entry);
            if (container) {
                if (outIndex) *outIndex = [container indexOfObjectIdenticalTo:target];
                return container;
            }
        }
    }
    return nil;
}

static UITableView *ZLModTableViewForVC(id vc) {
    if ([vc isKindOfClass:[UITableViewController class]]) {
        return [(UITableViewController *)vc tableView];
    }
    if ([vc isKindOfClass:[UIViewController class]]) {
        for (UIView *sub in [(UIViewController *)vc view].subviews) {
            if ([sub isKindOfClass:[UITableView class]]) return (UITableView *)sub;
        }
    }
    return nil;
}

static void ZLModRefreshSnapshotForVC(id vc, ZLModSettingsVCState *state) {
    NSMutableArray<NSArray *> *sections = [NSMutableArray array];
    for (ZLModSettingsBFSNode *entry in ZLModCollectSettingsNodes(vc, kZLModMaxSafeBFDepth)) {
        if (![entry.node isKindOfClass:[NSArray class]]) continue;
        NSArray *array = (NSArray *)entry.node;
        if (array.count == 0) continue;
        BOOL cellObjectLike = YES;
        for (id element in array) {
            if ([element isKindOfClass:[NSArray class]] || [element isKindOfClass:[NSDictionary class]]) {
                cellObjectLike = NO;
                break;
            }
            NSString *clsName = NSStringFromClass(object_getClass(element));
            if (!([clsName containsString:@"CellObject"] || [clsName containsString:@"Object"])) {
                cellObjectLike = NO;
                break;
            }
        }
        if (cellObjectLike) [sections addObject:array];
    }
    state.sectionSnapshot = [sections copy];
    state.snapshotAligned = NO;

    UITableView *tv = ZLModTableViewForVC(vc);
    if (tv && [tv numberOfSections] == (NSInteger)sections.count) {
        state.snapshotAligned = YES;
        for (NSInteger s = 0; s < (NSInteger)sections.count; s++) {
            if ([tv numberOfRowsInSection:s] != (NSInteger)sections[(NSUInteger)s].count) {
                state.snapshotAligned = NO;
                break;
            }
        }
    }
}

#pragma mark - Zero-Index-Shift Navigation Bar Entry (Safe Fallback)

@interface ZLModNavBarTrigger : NSObject
@property (nonatomic, weak) UIViewController *hostVC;
- (void)openDashboard:(id)sender;
@end

@implementation ZLModNavBarTrigger
- (void)openDashboard:(__unused id)sender {
    UIViewController *host = self.hostVC ?: ZLModTopPresenterViewController();
    if (host) {
        [ZLModSettingsViewController pushFrom:host];
    }
}
@end

static const void *kZLModNavTriggerAssocKey = &kZLModNavTriggerAssocKey;

static void ZLModInstallSafeNavBarEntry(UIViewController *vc, ZLModSettingsVCState *state) {
    if (![vc isKindOfClass:[UIViewController class]] || state.navFallbackInstalled) return;
    UINavigationItem *navItem = vc.navigationItem;
    if (!navItem) return;

    for (UIBarButtonItem *item in navItem.rightBarButtonItems) {
        if (item.tag == kZLModSettingsButtonTag) {
            state.navFallbackInstalled = YES;
            return;
        }
    }

    ZLModNavBarTrigger *trigger = [[ZLModNavBarTrigger alloc] init];
    trigger.hostVC = vc;
    objc_setAssociatedObject(vc, kZLModNavTriggerAssocKey, trigger, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIBarButtonItem *btn = nil;
    UIImage *gear = [UIImage systemImageNamed:@"slider.horizontal.3"];
    if (gear) {
        btn = [[UIBarButtonItem alloc] initWithImage:gear
                                               style:UIBarButtonItemStylePlain
                                              target:trigger
                                              action:@selector(openDashboard:)];
    } else {
        btn = [[UIBarButtonItem alloc] initWithTitle:@"ZLMod"
                                               style:UIBarButtonItemStylePlain
                                              target:trigger
                                              action:@selector(openDashboard:)];
    }
    btn.tag = kZLModSettingsButtonTag;
    btn.accessibilityLabel = @"ZLMod Customize";
    btn.accessibilityIdentifier = @"zlmod.settings.navbutton";

    NSMutableArray<UIBarButtonItem *> *items = navItem.rightBarButtonItems
        ? [navItem.rightBarButtonItems mutableCopy]
        : [NSMutableArray array];
    [items addObject:btn];
    navItem.rightBarButtonItems = [items copy];
    state.navFallbackInstalled = YES;
    ZLMOD_LOG(@"settings: installed safe zero-index-shift navigation bar button");
}

#pragma mark - Per-VC Injection Lifecycle

static void ZLModEnsureSettingsEntryOnMain(id vc) {
    if (!vc || ![vc isKindOfClass:[UIViewController class]]) return;
    ZLModSettingsVCState *state = ZLModStateForSettingsVC(vc);

    // Always attach the zero-index-shift nav button as a guaranteed entry point.
    ZLModInstallSafeNavBarEntry((UIViewController *)vc, state);

    if (state.injectedRow) {
        BOOL stillPresent = NO;
        for (NSArray *section in state.sectionSnapshot) {
            if ([section indexOfObjectIdenticalTo:state.injectedRow] != NSNotFound) {
                stillPresent = YES;
                break;
            }
        }
        if (stillPresent) return;

        id accountObject = ZLModFetchAccountObject(vc);
        NSUInteger idx = 0;
        NSMutableArray *container = ZLModFindContainerForAccountObject(vc, accountObject, &idx);
        if (container && [container indexOfObjectIdenticalTo:state.injectedRow] == NSNotFound) {
            @try {
                [container insertObject:state.injectedRow atIndex:MIN(idx, container.count)];
                ZLModRefreshSnapshotForVC(vc, state);
                [ZLModTableViewForVC(vc) reloadData];
                return;
            } @catch (__unused NSException *e) {}
        }
        state.injectedRow = nil;
    }

    if (state.retryCount >= 2) return;

    id accountObject = ZLModFetchAccountObject(vc);
    NSUInteger accountIdx = 0;
    NSMutableArray *container = ZLModFindContainerForAccountObject(vc, accountObject, &accountIdx);
    if (accountObject && container) {
        id clone = ZLModSafeCloneCellObject(accountObject);
        NSString *oldTitle = nil;
        if (clone && ZLModSafeRetitleCellObject(clone, @"ZLMod Customize", &oldTitle)) {
            @try {
                [container insertObject:clone atIndex:MIN(accountIdx, container.count)];
                state.injectedRow = clone;
                state.retryCount = 0;
                ZLModRefreshSnapshotForVC(vc, state);
                [ZLModTableViewForVC(vc) reloadData];
                ZLMOD_LOG(@"settings: native row injected via safe property clone (replaced=%@)", oldTitle ?: @"?");
                return;
            } @catch (__unused NSException *e) {}
        }
    }

    state.retryCount++;
    if (state.retryCount == 1) {
        __weak id weakVC = vc;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (weakVC) ZLModEnsureSettingsEntryOnMain(weakVC);
        });
    }
}

static BOOL ZLModHandleSettingsSelection(id vc, NSIndexPath *indexPath, UITableView *tv) {
    ZLModSettingsVCState *state = ZLModStateForSettingsVC(vc);
    if (!state.injectedRow) return NO;

    id tapped = nil;
    if (state.snapshotAligned && indexPath.section < (NSInteger)state.sectionSnapshot.count) {
        NSArray *section = state.sectionSnapshot[(NSUInteger)indexPath.section];
        if (indexPath.row < (NSInteger)section.count) {
            tapped = section[(NSUInteger)indexPath.row];
        }
    }
    if (!tapped) {
        for (NSArray *section in state.sectionSnapshot) {
            NSUInteger idx = [section indexOfObjectIdenticalTo:state.injectedRow];
            if (idx != NSNotFound &&
                (NSInteger)idx == indexPath.row &&
                [tv numberOfRowsInSection:indexPath.section] == (NSInteger)section.count) {
                tapped = section[idx];
                break;
            }
        }
    }
    if (tapped == state.injectedRow) {
        [ZLModSettingsViewController pushFrom:vc];
        [tv deselectRowAtIndexPath:indexPath animated:YES];
        return YES;
    }
    return NO;
}

#pragma mark - Universal Shake Presenter & Install

typedef void (*ZLModV0)(id, SEL);
typedef void (*ZLModV1Bool)(id, SEL, BOOL);
typedef void (*ZLModV2)(id, SEL, id, id);

void ZLModPresentSettingsUniversal(void) {
    ZLModRunOnMainThread(^{
        if ([[ZLModPreferences shared] boolForKey:kZLModDisableShakeToOpen]) {
            return;
        }
        // Respect iOS standard "Shake to Undo Typing" when user is editing text.
        if (ZLModIsAnyTextInputActive()) {
            ZLMOD_LOG(@"settings: shake ignored because a text input is active (Undo Typing safe)");
            return;
        }
        UIWindow *win = ZLModActiveKeyWindow();
        if (!win) return;
        UIViewController *top = win.rootViewController;
        if (!top) return;
        while (top.presentedViewController && !top.presentedViewController.isBeingDismissed) {
            top = top.presentedViewController;
        }
        if ([top isKindOfClass:[ZLModSettingsViewController class]] ||
            ([top isKindOfClass:[UINavigationController class]] &&
             [[(UINavigationController *)top visibleViewController] isKindOfClass:[ZLModSettingsViewController class]])) {
            return;
        }
        [ZLModSettingsViewController pushFrom:top];
    });
}

void ZLModSettingsInstall(void) {
    // 1. Universal Shake Gesture (opt-out via kZLModDisableShakeToOpen; Undo-Typing safe)
    Class winCls = [UIWindow class];
    SEL motionSel = sel_registerName("motionEnded:withEvent:");
    BOOL okShake = NO;
    if (ZLModClassHasInstanceMethod(winCls, motionSel)) {
        IMP motionOrig = class_getMethodImplementation(winCls, motionSel);
        okShake = ZLModReplaceMethod(winCls, motionSel, 2, "v", ^(UIWindow *self, UIEventSubtype motion, UIEvent *event) {
            if (motionOrig) ((void (*)(id, SEL, UIEventSubtype, id))motionOrig)(self, motionSel, motion, event);
            if (motion == UIEventSubtypeMotionShake) {
                ZLModPresentSettingsUniversal();
            }
        });
    }

    // 2. Discover Settings Hub Class
    NSArray<NSString *> *candidates = @[
        @"SettingUI40TableViewController",
        @"SettingUITableViewController",
        @"BasicSettingTableViewController",
        @"ZaloSettingViewController",
        @"SettingTableViewController"
    ];
    for (NSString *name in candidates) {
        Class c = NSClassFromString(name);
        if (c) {
            gSettingsClass = c;
            break;
        }
    }

    if (!gSettingsClass) {
        ZLModSetModuleStatus(@"Settings", ZLModModuleStatusNotInstalled,
                             okShake ? @"settings VC not found; shake active" : @"settings VC not found");
        ZLMOD_LOG(@"settings table class not found — relying on shake gesture (ok=%d)", okShake);
        return;
    }

    SEL viewDidLoadSel = sel_registerName("viewDidLoad");
    IMP viewDidLoadOrig = class_getMethodImplementation(gSettingsClass, viewDidLoadSel);
    BOOL okViewDidLoad = ZLModReplaceMethod(gSettingsClass, viewDidLoadSel, 0, "v", ^(id self) {
        if (viewDidLoadOrig) ((ZLModV0)viewDidLoadOrig)(self, viewDidLoadSel);
        ZLModRunOnMainThread(^{ ZLModEnsureSettingsEntryOnMain(self); });
    });

    SEL willAppearSel = sel_registerName("viewWillAppear:");
    IMP willAppearOrig = class_getMethodImplementation(gSettingsClass, willAppearSel);
    BOOL okViewWillAppear = ZLModReplaceMethod(gSettingsClass, willAppearSel, 1, "v", ^(id self, BOOL animated) {
        if (willAppearOrig) ((ZLModV1Bool)willAppearOrig)(self, willAppearSel, animated);
        ZLModEnsureSettingsEntryOnMain(self);
    });

    SEL updateTitleSel = sel_registerName("updateTitleObjects");
    BOOL okUpdateTitle = NO;
    if (ZLModClassHasInstanceMethod(gSettingsClass, updateTitleSel)) {
        IMP updateTitleOrig = class_getMethodImplementation(gSettingsClass, updateTitleSel);
        okUpdateTitle = ZLModReplaceMethod(gSettingsClass, updateTitleSel, 0, "v", ^(id self) {
            if (updateTitleOrig) ((ZLModV0)updateTitleOrig)(self, updateTitleSel);
            ZLModRunOnMainThread(^{ ZLModEnsureSettingsEntryOnMain(self); });
        });
    }

    SEL didSelectSel = sel_registerName("tableView:didSelectRowAtIndexPath:");
    IMP didSelectOrig = class_getMethodImplementation(gSettingsClass, didSelectSel);
    BOOL okDidSelect = ZLModReplaceMethod(gSettingsClass, didSelectSel, 2, "v", ^(id self, UITableView *tv, NSIndexPath *indexPath) {
        if (ZLModHandleSettingsSelection(self, indexPath, tv)) return;
        if (didSelectOrig) ((ZLModV2)didSelectOrig)(self, didSelectSel, tv, indexPath);
    });

    // Late install check if Settings is already visible on screen.
    ZLModRunOnMainThread(^{
        UIWindow *window = ZLModActiveKeyWindow();
        UIViewController *root = window.rootViewController;
        if (!root) return;
        NSMutableArray<UIViewController *> *stack = [NSMutableArray arrayWithObject:root];
        while (stack.count > 0) {
            UIViewController *cursor = stack.firstObject;
            [stack removeObjectAtIndex:0];
            if (object_getClass(cursor) == gSettingsClass) {
                @try { ZLModEnsureSettingsEntryOnMain(cursor); } @catch (__unused NSException *e) {}
                break;
            }
            [stack addObjectsFromArray:cursor.childViewControllers];
            if (cursor.presentedViewController) [stack addObject:cursor.presentedViewController];
            if ([cursor isKindOfClass:[UINavigationController class]]) {
                [stack addObjectsFromArray:[(UINavigationController *)cursor viewControllers]];
            }
        }
    });

    BOOL installed = (okViewDidLoad || okViewWillAppear || okDidSelect);
    ZLModSetModuleStatus(@"Settings",
                         installed ? ZLModModuleStatusHookInstalled : ZLModModuleStatusNotInstalled,
                         [NSString stringWithFormat:@"cls=%@ load=%d appear=%d select=%d update=%d shake=%d",
                          NSStringFromClass(gSettingsClass), okViewDidLoad, okViewWillAppear,
                          okDidSelect, okUpdateTitle, okShake]);
    ZLMOD_LOG(@"settings integration installed (%@)", NSStringFromClass(gSettingsClass));
}
