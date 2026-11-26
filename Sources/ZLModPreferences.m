// language: Objective-C, file: ZLModPreferences.m, target: iOS 15.1+ (Zalo 26.10.02 & 26.11.01, arm64)
// Persistent configuration. Primary suite: vn.com.vng.zingalo.zlmod.
// Secret credentials (kZLModBridgeToken, kZLModBridgeWebhook) are NEVER persisted in
// NSUserDefaults or App Group; they are routed exclusively to ZLModSecretStore (iOS Keychain)
// with automatic one-time migration and plaintext purge.
// Uses transactional batching (single coalesced notification) and omits deprecated synchronize calls.

#import "ZLMod.h"
#import <os/lock.h>

NSString *const ZLModPrefsDidChangeNotification  = @"ZLModPrefsDidChangeNotification";
NSString *const ZLModPrefsChangedKeysUserInfoKey = @"changedKeys";

NSString *const kZLModGlassTabBar         = @"zlmod.appearance.glass";
NSString *const kZLModThemePreset         = @"zlmod.appearance.themePreset";
NSString *const kZLModThemeTintHex        = @"zlmod.appearance.themeTintHex";
NSString *const kZLModHideTyping          = @"zlmod.privacy.hideTyping";
NSString *const kZLModHideSeen            = @"zlmod.privacy.hideSeen";
NSString *const kZLModHideReadReceipts    = @"zlmod.privacy.hideReadReceipts";
NSString *const kZLModBlockTracking       = @"zlmod.privacy.blockTracking";
NSString *const kZLModBlockFirebase       = @"zlmod.privacy.blockFirebase";
NSString *const kZLModHideAds             = @"zlmod.ads.hide";
NSString *const kZLModBlockAdRequests     = @"zlmod.ads.blockRequests";
NSString *const kZLModRestoreProfileMusic = @"zlmod.features.profileMusic";
NSString *const kZLModRestoreGDrive       = @"zlmod.features.gdriveBackup";
NSString *const kZLModRestoreMoreTab      = @"zlmod.features.moreTab";
NSString *const kZLModAntiRecall          = @"zlmod.messaging.antiRecall";
NSString *const kZLModDelaySend           = @"zlmod.utilities.delaySend";
NSString *const kZLModDelaySendSeconds    = @"zlmod.utilities.delaySendSeconds";
NSString *const kZLModDisableShakeToOpen  = @"zlmod.settings.disableShakeToOpen";
NSString *const kZLModBridgeServerURL     = @"zlmod.bridge.serverUrl";
NSString *const kZLModBridgeToken         = @"zlmod.bridge.token";
NSString *const kZLModBridgeWebhook       = @"zlmod.bridge.webhook";
NSString *const kZLModBridgeSaving        = @"zlmod.bridge.savingEnabled";
NSString *const kZLModBridgeDiscordRelay  = @"zlmod.bridge.discordRelayEnabled";
NSString *const kZLModBridgeLastSync      = @"zlmod.bridge.lastSyncTime";

static NSArray<NSString *> *ZLModAllPreferenceKeys(void) {
    return @[
        kZLModGlassTabBar,
        kZLModThemePreset,
        kZLModThemeTintHex,
        kZLModHideTyping,
        kZLModHideSeen,
        kZLModHideReadReceipts,
        kZLModBlockTracking,
        kZLModBlockFirebase,
        kZLModHideAds,
        kZLModBlockAdRequests,
        kZLModRestoreProfileMusic,
        kZLModRestoreGDrive,
        kZLModRestoreMoreTab,
        kZLModAntiRecall,
        kZLModDelaySend,
        kZLModDelaySendSeconds,
        kZLModDisableShakeToOpen,
        kZLModBridgeServerURL,
        kZLModBridgeToken,
        kZLModBridgeWebhook,
        kZLModBridgeSaving,
        kZLModBridgeDiscordRelay,
        kZLModBridgeLastSync
    ];
}

static NSArray<NSString *> *ZLModKnownExternalKeys(void) {
    return @[
        @"kProfileMusicSetting",
        @"profile_music",
        @"features@profile_music",
        @"enable_rbt",
        @"restore_gdrive_photo_csc",
        @"enable_tabmore"
    ];
}

@interface ZLModPreferences () {
    os_unfair_lock _batchLock;
    NSInteger _batchDepth;
    NSMutableArray<NSString *> *_pendingChangedKeys;
    BOOL _secretsMigrated;
}
@property (nonatomic, strong) NSUserDefaults *own;
@property (nonatomic, strong) NSUserDefaults *group;
@property (nonatomic, strong) NSUserDefaults *standard;
@end

@implementation ZLModPreferences

+ (instancetype)shared {
    static ZLModPreferences *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[ZLModPreferences alloc] init]; });
    return shared;
}

+ (NSSet<NSString *> *)secretPreferenceKeys {
    static NSSet<NSString *> *keys = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = [NSSet setWithArray:@[kZLModBridgeToken, kZLModBridgeWebhook]];
    });
    return keys;
}

+ (NSSet<NSString *> *)remoteDeployAllowedKeys {
    static NSSet<NSString *> *allowed = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Strict allowlist for CDeploy remote push: NEVER permits serverUrl, token,
        // webhook, lastSync, or internal backup keys (zlmod.internal.*).
        allowed = [NSSet setWithArray:@[
            kZLModGlassTabBar,
            kZLModThemePreset,
            kZLModThemeTintHex,
            kZLModHideTyping,
            kZLModHideSeen,
            kZLModHideReadReceipts,
            kZLModBlockTracking,
            kZLModBlockFirebase,
            kZLModHideAds,
            kZLModBlockAdRequests,
            kZLModRestoreProfileMusic,
            kZLModRestoreGDrive,
            kZLModRestoreMoreTab,
            kZLModAntiRecall,
            kZLModDelaySend,
            kZLModDelaySendSeconds,
            kZLModDisableShakeToOpen,
            kZLModBridgeSaving,
            kZLModBridgeDiscordRelay
        ]];
    });
    return allowed;
}

+ (BOOL)isSecretPreferenceKey:(NSString *)key {
    if (![key isKindOfClass:[NSString class]] || key.length == 0) return NO;
    return [[self secretPreferenceKeys] containsObject:key];
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _batchLock = OS_UNFAIR_LOCK_INIT;
        _batchDepth = 0;
        _pendingChangedKeys = [NSMutableArray array];
        _secretsMigrated = NO;
        _own      = [[NSUserDefaults alloc] initWithSuiteName:kZLModPreferencesSuiteName] ?: [NSUserDefaults standardUserDefaults];
        _group    = [[NSUserDefaults alloc] initWithSuiteName:kZLModAppGroupSuiteName];
        _standard = [NSUserDefaults standardUserDefaults];
    }
    return self;
}

- (void)migrateLegacySecretsToKeychainIfNeeded {
    os_unfair_lock_lock(&_batchLock);
    if (_secretsMigrated) {
        os_unfair_lock_unlock(&_batchLock);
        return;
    }
    _secretsMigrated = YES;
    os_unfair_lock_unlock(&_batchLock);

    ZLModSecretStore *secretStore = [ZLModSecretStore shared];
    for (NSString *secretKey in [[self class] secretPreferenceKeys]) {
        id ownVal = [self.own objectForKey:secretKey];
        id grpVal = self.group ? [self.group objectForKey:secretKey] : nil;
        id stdVal = [self.standard objectForKey:secretKey];

        NSString *legacy = nil;
        if ([ownVal isKindOfClass:[NSString class]] && [(NSString *)ownVal length] > 0) {
            legacy = (NSString *)ownVal;
        } else if ([grpVal isKindOfClass:[NSString class]] && [(NSString *)grpVal length] > 0) {
            legacy = (NSString *)grpVal;
        } else if ([stdVal isKindOfClass:[NSString class]] && [(NSString *)stdVal length] > 0) {
            legacy = (NSString *)stdVal;
        }

        if (legacy.length > 0) {
            NSString *existing = [secretStore secretForKey:secretKey];
            BOOL migratedOrPresent = (existing.length > 0);
            if (!migratedOrPresent) {
                OSStatus st = errSecSuccess;
                migratedOrPresent = [secretStore setSecret:legacy forKey:secretKey errorStatus:&st];
                if (migratedOrPresent) {
                    ZLMOD_LOG(@"prefs: migrated legacy secret %@ to Keychain", secretKey);
                } else {
                    ZLMOD_LOG(@"prefs: failed migrating legacy secret %@ to Keychain (OSStatus=%d)", secretKey, (int)st);
                }
            }
            // Always purge plaintext copies from NSUserDefaults / App Group.
            [self.own removeObjectForKey:secretKey];
            if (self.group) [self.group removeObjectForKey:secretKey];
            [self.standard removeObjectForKey:secretKey];
        } else if (ownVal != nil || grpVal != nil || stdVal != nil) {
            [self.own removeObjectForKey:secretKey];
            if (self.group) [self.group removeObjectForKey:secretKey];
            [self.standard removeObjectForKey:secretKey];
        }
    }
}

- (void)notifyPreferenceChangedForKey:(NSString *)key {
    if (key.length == 0) return;

    os_unfair_lock_lock(&_batchLock);
    if (_batchDepth > 0) {
        if (![_pendingChangedKeys containsObject:key]) {
            [_pendingChangedKeys addObject:[key copy]];
        }
        os_unfair_lock_unlock(&_batchLock);
        return;
    }
    os_unfair_lock_unlock(&_batchLock);

    [[NSNotificationCenter defaultCenter] postNotificationName:ZLModPrefsDidChangeNotification
                                                        object:key
                                                      userInfo:@{ ZLModPrefsChangedKeysUserInfoKey: @[key] }];
}

- (void)performBatchUpdates:(void (^)(void))block {
    if (!block) return;

    os_unfair_lock_lock(&_batchLock);
    _batchDepth++;
    os_unfair_lock_unlock(&_batchLock);

    @try {
        block();
    } @finally {
        NSArray<NSString *> *changed = nil;
        os_unfair_lock_lock(&_batchLock);
        _batchDepth--;
        if (_batchDepth <= 0) {
            _batchDepth = 0;
            if (_pendingChangedKeys.count > 0) {
                changed = [_pendingChangedKeys copy];
                [_pendingChangedKeys removeAllObjects];
            }
        }
        os_unfair_lock_unlock(&_batchLock);

        if (changed.count > 0) {
            NSString *notifObj = (changed.count == 1) ? changed.firstObject : @"*";
            [[NSNotificationCenter defaultCenter] postNotificationName:ZLModPrefsDidChangeNotification
                                                                object:notifObj
                                                              userInfo:@{ ZLModPrefsChangedKeysUserInfoKey: changed }];
        }
    }
}

- (NSArray<NSString *> *)applyRemoteSettingsBatch:(NSDictionary<NSString *, id> *)settings
                                      allowedKeys:(NSSet<NSString *> *)allowedKeys {
    if (![settings isKindOfClass:[NSDictionary class]] || settings.count == 0) return @[];
    NSSet<NSString *> *effectiveAllowlist = allowedKeys ?: [[self class] remoteDeployAllowedKeys];
    NSMutableArray<NSString *> *applied = [NSMutableArray array];

    [self performBatchUpdates:^{
        for (id rawKey in settings) {
            if (![rawKey isKindOfClass:[NSString class]]) continue;
            NSString *key = (NSString *)rawKey;
            if ([[self class] isSecretPreferenceKey:key]) continue;
            if ([key hasPrefix:kZLModPrevExternalPrefix]) continue;
            if (![effectiveAllowlist containsObject:key]) continue;

            id val = settings[key];
            if ([key isEqualToString:kZLModThemePreset] || [key isEqualToString:kZLModThemeTintHex]) {
                if ([val isKindOfClass:[NSString class]]) {
                    [self setString:(NSString *)val forKey:key];
                    [applied addObject:key];
                }
            } else if ([key isEqualToString:kZLModDelaySendSeconds]) {
                if ([val isKindOfClass:[NSNumber class]]) {
                    double sec = [(NSNumber *)val doubleValue];
                    if (sec < kZLModDelaySendMinSeconds) sec = kZLModDelaySendMinSeconds;
                    if (sec > kZLModDelaySendMaxSeconds) sec = kZLModDelaySendMaxSeconds;
                    [self setDouble:sec forKey:key];
                    [applied addObject:key];
                }
            } else if ([val isKindOfClass:[NSNumber class]]) {
                [self setBool:[(NSNumber *)val boolValue] forKey:key];
                [applied addObject:key];
            }
        }
    }];
    return [applied copy];
}

- (BOOL)boolForKey:(NSString *)key {
    if (!key) return NO;
    if ([[self class] isSecretPreferenceKey:key]) return NO;
    if ([self.own objectForKey:key] != nil) return [self.own boolForKey:key];
    if (self.group && [self.group objectForKey:key] != nil) return [self.group boolForKey:key];
    return NO;
}

- (void)setBool:(BOOL)value forKey:(NSString *)key {
    if (!key || [[self class] isSecretPreferenceKey:key]) return;
    [self.own setBool:value forKey:key];
    if (self.group) [self.group setBool:value forKey:key];
    [self notifyPreferenceChangedForKey:key];
    ZLMOD_LOG(@"pref %@ = %@", key, value ? @"ON" : @"OFF");
}

- (double)doubleForKey:(NSString *)key defaultValue:(double)defaultValue {
    if (!key || [[self class] isSecretPreferenceKey:key]) return defaultValue;
    id val = [self.own objectForKey:key];
    if (!val && self.group) val = [self.group objectForKey:key];
    if ([val isKindOfClass:[NSNumber class]] || [val isKindOfClass:[NSString class]]) {
        return [val doubleValue];
    }
    return defaultValue;
}

- (void)setDouble:(double)value forKey:(NSString *)key {
    if (!key || [[self class] isSecretPreferenceKey:key]) return;
    [self.own setDouble:value forKey:key];
    if (self.group) [self.group setDouble:value forKey:key];
    [self notifyPreferenceChangedForKey:key];
    ZLMOD_LOG(@"pref %@ = %.1f", key, value);
}

- (NSString *)stringForKey:(NSString *)key defaultValue:(NSString *)defaultValue {
    if (!key) return defaultValue;
    if ([[self class] isSecretPreferenceKey:key]) {
        [self migrateLegacySecretsToKeychainIfNeeded];
        NSString *secret = [[ZLModSecretStore shared] secretForKey:key];
        return secret.length > 0 ? secret : defaultValue;
    }
    id val = [self.own objectForKey:key];
    if (!val && self.group) val = [self.group objectForKey:key];
    if ([val isKindOfClass:[NSString class]]) {
        return (NSString *)val;
    }
    return defaultValue;
}

- (void)setString:(NSString *)value forKey:(NSString *)key {
    if (!key) return;
    if ([[self class] isSecretPreferenceKey:key]) {
        // Ensure no plaintext copy can ever linger in NSUserDefaults or App Group.
        [self.own removeObjectForKey:key];
        if (self.group) [self.group removeObjectForKey:key];
        [self.standard removeObjectForKey:key];

        OSStatus st = errSecSuccess;
        if (value.length > 0) {
            [[ZLModSecretStore shared] setSecret:value forKey:key errorStatus:&st];
        } else {
            [[ZLModSecretStore shared] removeSecretForKey:key];
        }
        [self notifyPreferenceChangedForKey:key];
        ZLMOD_LOG(@"pref secret %@ updated in Keychain", key);
        return;
    }

    if (value) {
        [self.own setObject:value forKey:key];
        if (self.group) [self.group setObject:value forKey:key];
    } else {
        [self.own removeObjectForKey:key];
        if (self.group) [self.group removeObjectForKey:key];
    }
    [self notifyPreferenceChangedForKey:key];
    ZLMOD_LOG(@"pref %@ updated", key);
}

- (void)removeObjectForKey:(NSString *)key {
    if (!key) return;
    [self.own removeObjectForKey:key];
    if (self.group) [self.group removeObjectForKey:key];
    if ([[self class] isSecretPreferenceKey:key]) {
        [self.standard removeObjectForKey:key];
        [[ZLModSecretStore shared] removeSecretForKey:key];
    }
    [self notifyPreferenceChangedForKey:key];
}

- (void)resetAllPreferences {
    [self performBatchUpdates:^{
        for (NSString *extKey in ZLModKnownExternalKeys()) {
            [self restoreExternalValueForKey:extKey];
        }
        [[ZLModSecretStore shared] clearAllSecrets];
        for (NSString *key in ZLModAllPreferenceKeys()) {
            [self.own removeObjectForKey:key];
            if (self.group) [self.group removeObjectForKey:key];
            if ([[self class] isSecretPreferenceKey:key]) {
                [self.standard removeObjectForKey:key];
            }
            [self notifyPreferenceChangedForKey:key];
        }
    }];
    ZLMOD_LOG(@"all preferences and Keychain secrets reset to default (single batch transaction)");
}

- (void)writeExternalValue:(id)value forKey:(NSString *)key {
    [self rememberExternalValueForKey:key];
    [self writeValue:value toExternalKey:key];
    ZLMOD_LOG(@"external %@ written", key);
}

- (void)restoreExternalValueForKey:(NSString *)key {
    NSString *slot = [kZLModPrevExternalPrefix stringByAppendingString:key];
    if ([self.own objectForKey:slot] == nil) return;
    id previous = [self.own objectForKey:slot];
    if ([previous isKindOfClass:[NSNumber class]] && [previous boolValue] == NO &&
        ![self wasExternalKeyPresentBeforeWrite:key]) {
        [self.standard removeObjectForKey:key];
        if (self.group) [self.group removeObjectForKey:key];
    } else if (previous) {
        [self writeValue:previous toExternalKey:key];
    } else {
        [self.standard removeObjectForKey:key];
        if (self.group) [self.group removeObjectForKey:key];
    }
    [self.own removeObjectForKey:slot];
    NSString *flag = [kZLModPrevExternalPrefix stringByAppendingFormat:@"present.%@", key];
    [self.own removeObjectForKey:flag];
    ZLMOD_LOG(@"external %@ restored", key);
}

- (BOOL)wasExternalKeyPresentBeforeWrite:(NSString *)key {
    NSString *flag = [kZLModPrevExternalPrefix stringByAppendingFormat:@"present.%@", key];
    return [[self.own objectForKey:flag] boolValue];
}

- (void)rememberExternalValueForKey:(NSString *)key {
    NSString *slot = [kZLModPrevExternalPrefix stringByAppendingString:key];
    if ([self.own objectForKey:slot] != nil) return;
    id current = [self readExternalKey:key];
    NSString *flag = [kZLModPrevExternalPrefix stringByAppendingFormat:@"present.%@", key];
    if (current) {
        [self.own setObject:current forKey:slot];
        [self.own setBool:YES forKey:flag];
    } else {
        [self.own setObject:@NO forKey:slot];
        [self.own setBool:NO forKey:flag];
    }
}

- (id)readExternalKey:(NSString *)key {
    if ([self.standard objectForKey:key] != nil) return [self.standard objectForKey:key];
    if (self.group && [self.group objectForKey:key] != nil) return [self.group objectForKey:key];
    return nil;
}

- (void)writeValue:(id)value toExternalKey:(NSString *)key {
    if (value) {
        [self.standard setObject:value forKey:key];
        if (self.group) [self.group setObject:value forKey:key];
    } else {
        [self.standard removeObjectForKey:key];
        if (self.group) [self.group removeObjectForKey:key];
    }
}

@end
