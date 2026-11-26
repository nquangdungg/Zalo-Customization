// language: Objective-C, file: ZLModFeatures.m, target: iOS 15.1+ (Zalo 26.10.02 & 26.11.01, arm64)
// Feature restoration (MODULE 09) — clean-room iOS implementation anchored on runtime
// selectors and preference keys present in Zalo 26.10.02 / 26.11.01:
//   - Profile Music: getters enableProfileMusic / enableProfileMusicRBT /
//     enableShareProfileMusic / newFlagEnableProfileMusic + setEnableProfileMusicLocal:
//     and reversible external preference mirrors.
//   - Google Drive Backup: bidirectional fallback bridge between
//     __basicBackupGDriveSectionZInstantData and _basicBackupGDriveSectionZInstantData
//     plus reversible restore_gdrive_photo_csc mirror.
//   - More Tab: reversible enable_tabmore mirror.

#import "ZLMod.h"

static BOOL gFeaturesInstalled = NO;

#pragma mark - Generic BOOL getter forcing (single-pass selector index)

static NSUInteger ZLModForceBoolGetter(const char *selName, NSString *toggleKey, BOOL (^predicate)(Class)) {
    SEL sel = sel_registerName(selName);
    NSUInteger hooked = 0;
    for (Class cls in ZLModClassesImplementingInstanceSelector(sel)) {
        if (predicate && !predicate(cls)) continue;
        IMP original = class_getMethodImplementation(cls, sel);
        if (!original) continue;
        if (ZLModReplaceMethod(cls, sel, 0, "Bc", ^BOOL(id self) {
            if ([[ZLModPreferences shared] boolForKey:toggleKey]) return YES;
            return ((BOOL (*)(id, SEL))original)(self, sel);
        })) {
            hooked++;
        }
    }
    return hooked;
}

static BOOL ZLModClassLooksProfileMusic(Class cls) {
    if (ZLModClassHasIvar(cls, "_enableProfileMusic")) return YES;
    if (ZLModClassHasIvar(cls, "_enableProfileMusicRBT")) return YES;
    if (ZLModClassHasIvar(cls, "_enableShareProfileMusic")) return YES;
    NSString *name = [NSString stringWithUTF8String:class_getName(cls)];
    return [name containsString:@"ProfileMusic"];
}

#pragma mark - Profile Music

static NSArray<NSString *> *ZLModProfileMusicExternalKeys(void) {
    return @[@"kProfileMusicSetting", @"profile_music", @"features@profile_music", @"enable_rbt"];
}

static void ZLModApplyProfileMusicState(void) {
    ZLModPreferences *prefs = [ZLModPreferences shared];
    BOOL enabled = [prefs boolForKey:kZLModRestoreProfileMusic];
    for (NSString *key in ZLModProfileMusicExternalKeys()) {
        if (enabled) {
            [prefs writeExternalValue:@YES forKey:key];
        } else {
            [prefs restoreExternalValueForKey:key];
        }
    }
}

static NSUInteger ZLModInstallProfileMusicHooks(void) {
    NSUInteger hooked = 0;
    NSArray<NSString *> *getters = @[@"enableProfileMusic",
                                     @"enableProfileMusicRBT",
                                     @"enableShareProfileMusic",
                                     @"newFlagEnableProfileMusic"];
    for (NSString *getter in getters) {
        hooked += ZLModForceBoolGetter(getter.UTF8String, kZLModRestoreProfileMusic, ^BOOL(Class cls) {
            return ZLModClassLooksProfileMusic(cls);
        });
    }

    SEL localSetter = sel_registerName("setEnableProfileMusicLocal:");
    for (Class cls in ZLModClassesImplementingInstanceSelector(localSetter)) {
        IMP original = class_getMethodImplementation(cls, localSetter);
        if (!original) continue;
        if (ZLModReplaceMethod(cls, localSetter, 1, "v", ^(id self, BOOL value) {
            BOOL force = [[ZLModPreferences shared] boolForKey:kZLModRestoreProfileMusic];
            ((void (*)(id, SEL, BOOL))original)(self, localSetter, force ? YES : value);
        })) {
            hooked++;
        }
    }
    return hooked;
}

#pragma mark - Google Drive Backup

static NSUInteger ZLModInstallGDriveBridge(void) {
    SEL modern = sel_registerName("__basicBackupGDriveSectionZInstantData");
    SEL legacy = sel_registerName("_basicBackupGDriveSectionZInstantData");

    NSMutableSet<Class> *candidates = [NSMutableSet set];
    [candidates addObjectsFromArray:ZLModClassesImplementingInstanceSelector(modern)];
    [candidates addObjectsFromArray:ZLModClassesImplementingInstanceSelector(legacy)];

    NSUInteger hooked = 0;
    for (Class cls in candidates) {
        BOOL hasModern = ZLModClassHasInstanceMethod(cls, modern);
        BOOL hasLegacy = ZLModClassHasInstanceMethod(cls, legacy);
        if (!hasModern && !hasLegacy) continue;

        // Capture both originals BEFORE replacing either, then call them directly —
        // never objc_msgSend on self, which would recurse into our own replacement.
        IMP modernOrig = hasModern ? class_getMethodImplementation(cls, modern) : NULL;
        IMP legacyOrig = hasLegacy ? class_getMethodImplementation(cls, legacy) : NULL;

        if (hasModern && modernOrig) {
            if (ZLModReplaceMethod(cls, modern, 0, "@", ^id(id self) {
                id result = ((id (*)(id, SEL))modernOrig)(self, modern);
                if (result) return result;
                if (![[ZLModPreferences shared] boolForKey:kZLModRestoreGDrive]) return nil;
                if (legacyOrig) {
                    id fallback = ((id (*)(id, SEL))legacyOrig)(self, legacy);
                    if (fallback) {
                        ZLMOD_LOG(@"gdrive section restored (legacy path)");
                        return fallback;
                    }
                }
                return nil;
            })) {
                hooked++;
            }
        }

        if (hasLegacy && legacyOrig) {
            if (ZLModReplaceMethod(cls, legacy, 0, "@", ^id(id self) {
                id result = ((id (*)(id, SEL))legacyOrig)(self, legacy);
                if (result) return result;
                if (![[ZLModPreferences shared] boolForKey:kZLModRestoreGDrive]) return nil;
                if (modernOrig) {
                    id fallback = ((id (*)(id, SEL))modernOrig)(self, modern);
                    if (fallback) {
                        ZLMOD_LOG(@"gdrive section restored (modern path)");
                        return fallback;
                    }
                }
                return nil;
            })) {
                hooked++;
            }
        }
    }
    return hooked;
}

static void ZLModApplyGDriveState(void) {
    ZLModPreferences *prefs = [ZLModPreferences shared];
    if ([prefs boolForKey:kZLModRestoreGDrive]) {
        [prefs writeExternalValue:@YES forKey:@"restore_gdrive_photo_csc"];
    } else {
        [prefs restoreExternalValueForKey:@"restore_gdrive_photo_csc"];
    }
}

#pragma mark - More Tab

static void ZLModApplyMoreTabState(void) {
    ZLModPreferences *prefs = [ZLModPreferences shared];
    if ([prefs boolForKey:kZLModRestoreMoreTab]) {
        [prefs writeExternalValue:@YES forKey:@"enable_tabmore"];
    } else {
        [prefs restoreExternalValueForKey:@"enable_tabmore"];
    }
}

static void ZLModHandleFeaturesPreferenceNotification(NSNotification *note) {
    NSMutableSet<NSString *> *keys = [NSMutableSet set];
    if ([note.object isKindOfClass:[NSString class]]) {
        [keys addObject:(NSString *)note.object];
    }
    NSArray *batch = note.userInfo[ZLModPrefsChangedKeysUserInfoKey];
    if ([batch isKindOfClass:[NSArray class]]) {
        for (id k in batch) {
            if ([k isKindOfClass:[NSString class]]) [keys addObject:(NSString *)k];
        }
    }

    BOOL all = [keys containsObject:@"*"];
    if (all || [keys containsObject:kZLModRestoreProfileMusic]) ZLModApplyProfileMusicState();
    if (all || [keys containsObject:kZLModRestoreGDrive]) ZLModApplyGDriveState();
    if (all || [keys containsObject:kZLModRestoreMoreTab]) ZLModApplyMoreTabState();
}

#pragma mark - Install

void ZLModFeaturesInstall(void) {
    if (gFeaturesInstalled) return;
    gFeaturesInstalled = YES;

    NSUInteger pmCount = ZLModInstallProfileMusicHooks();
    NSUInteger gdCount = ZLModInstallGDriveBridge();

    ZLModApplyProfileMusicState();
    ZLModApplyGDriveState();
    ZLModApplyMoreTabState();

    [[NSNotificationCenter defaultCenter] addObserverForName:ZLModPrefsDidChangeNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        ZLModHandleFeaturesPreferenceNotification(note);
    }];

    ZLModSetModuleStatus(@"Features",
                         (pmCount + gdCount) > 0 ? ZLModModuleStatusHookInstalled : ZLModModuleStatusNotInstalled,
                         [NSString stringWithFormat:@"profileMusic=%lu gdrive=%lu",
                          (unsigned long)pmCount, (unsigned long)gdCount]);
    ZLMOD_LOG(@"features installed (profileMusic=%lu gdrive=%lu)",
              (unsigned long)pmCount, (unsigned long)gdCount);
}
