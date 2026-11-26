// language: Objective-C, file: ZLModCryptoStore.m, target: iOS 15.1+ (Zalo 26.10.02 & 26.11.01, arm64)
// Privacy-preserving SHA-256 hashing, verified multi-account scope resolution,
// Keychain-backed Encrypt-then-MAC (AES-256-CBC + HMAC-SHA256) storage box,
// Keychain-only secret store for Bridge/Webhook credentials, storage health diagnostics,
// and non-blocking serial background disk I/O.
// Fail-closed: returns nil/NO whenever Keychain or account identity is unavailable.

#import "ZLMod.h"
#import <Security/Security.h>
#import <CommonCrypto/CommonCryptor.h>
#import <CommonCrypto/CommonHMAC.h>
#import <CommonCrypto/CommonDigest.h>
#import <CommonCrypto/CommonRandom.h>
#import <os/lock.h>

static const uint8_t kZLModCryptoRecordVersion = 0x02;

static os_unfair_lock gAccountScopeLock = OS_UNFAIR_LOCK_INIT;
static NSString *gCachedRawUid = nil;
static NSString *gCachedAccountScope = nil;

#pragma mark - Non-blocking serial disk I/O queue

static dispatch_queue_t ZLModDiskIOQueue(void) {
    static dispatch_queue_t queue = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        queue = dispatch_queue_create("zlmod.diskio", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

void ZLModWritePropertyListAsync(id immutableRoot, NSString *storagePath, void (^completion)(BOOL saved)) {
    if (!immutableRoot || storagePath.length == 0) {
        if (completion) completion(NO);
        return;
    }
    NSString *pathCopy = [storagePath copy];
    dispatch_async(ZLModDiskIOQueue(), ^{
        BOOL ok = NO;
        @try {
            NSError *error = nil;
            NSData *data = [NSPropertyListSerialization dataWithPropertyList:immutableRoot
                                                                      format:NSPropertyListBinaryFormat_v1_0
                                                                     options:0
                                                                       error:&error];
            if (data && !error) {
                NSString *dir = [pathCopy stringByDeletingLastPathComponent];
                if (dir.length > 0) {
                    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                              withIntermediateDirectories:YES
                                                               attributes:nil
                                                                    error:nil];
                }
                ok = [data writeToFile:pathCopy options:NSDataWritingAtomic error:&error];
            }
            if (!ok) {
                ZLMOD_LOG(@"diskio: failed writing plist (%@)", error.localizedDescription ?: @"unknown");
            }
        } @catch (NSException *e) {
            ZLMOD_LOG(@"diskio: exception writing plist (%@)", e.reason ?: @"unknown");
            ok = NO;
        }
        if (completion) {
            completion(ok);
        }
    });
}

void ZLModWriteDataAsync(NSData *immutableData, NSString *storagePath, void (^completion)(BOOL saved)) {
    if (!immutableData || storagePath.length == 0) {
        if (completion) completion(NO);
        return;
    }
    NSData *dataCopy = [immutableData copy];
    NSString *pathCopy = [storagePath copy];
    dispatch_async(ZLModDiskIOQueue(), ^{
        BOOL ok = NO;
        @try {
            NSError *error = nil;
            NSString *dir = [pathCopy stringByDeletingLastPathComponent];
            if (dir.length > 0) {
                [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                          withIntermediateDirectories:YES
                                                           attributes:nil
                                                                error:nil];
            }
            ok = [dataCopy writeToFile:pathCopy options:NSDataWritingAtomic error:&error];
            if (!ok) {
                ZLMOD_LOG(@"diskio: failed writing data (%@)", error.localizedDescription ?: @"unknown");
            }
        } @catch (NSException *e) {
            ZLMOD_LOG(@"diskio: exception writing data (%@)", e.reason ?: @"unknown");
            ok = NO;
        }
        if (completion) {
            completion(ok);
        }
    });
}

void ZLModFlushDiskIOQueueSync(void) {
    dispatch_sync(ZLModDiskIOQueue(), ^{});
}

#pragma mark - Hashing & safe identifiers

NSString *ZLModSha256Hex(NSString *input) {
    if (!input || input.length == 0) return @"";
    NSData *data = [input dataUsingEncoding:NSUTF8StringEncoding];
    if (!data || data.length == 0) return @"";

    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);

    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return [hex copy];
}

NSString *ZLModSafeIdHash(NSString *identifier) {
    if (![identifier isKindOfClass:[NSString class]] || identifier.length == 0) {
        return @"none";
    }
    NSString *hex = ZLModSha256Hex(identifier);
    if (hex.length < 12) return @"none";
    return [NSString stringWithFormat:@"id_%@", [hex substringToIndex:12]];
}

#pragma mark - Verified account scope resolution (fail-closed)

static id ZLModSafeClassSingleton(NSString *className, SEL sel) {
    Class cls = NSClassFromString(className);
    if (!cls || !sel || ![cls respondsToSelector:sel]) return nil;
    Method m = class_getClassMethod(cls, sel);
    if (!m || method_getNumberOfArguments(m) != 2) return nil;
    const char *enc = method_getTypeEncoding(m);
    if (!enc || enc[0] != '@') return nil;
    IMP imp = method_getImplementation(m);
    if (!imp) return nil;
    @try {
        return ((id (*)(id, SEL))imp)(cls, sel);
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static NSString *ZLModValidatedUserId(NSString *candidate) {
    if (![candidate isKindOfClass:[NSString class]]) return nil;
    NSString *trimmed = [candidate stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return nil;
    if ([trimmed isEqualToString:@"0"] ||
        [trimmed isEqualToString:@"(null)"] ||
        [trimmed isEqualToString:@"null"] ||
        [trimmed isEqualToString:@"<null>"]) {
        return nil;
    }
    return trimmed;
}

static NSString *ZLModProbeCurrentRawUserId(void) {
    id appCtx = ZLModSafeClassSingleton(@"ZAApplicationContext", sel_registerName("sharedContext"));
    NSString *uid = ZLModValidatedUserId(ZLModSafeStringProperty(appCtx, sel_registerName("userId")));
    if (uid) return uid;
    uid = ZLModValidatedUserId(ZLModSafeStringProperty(appCtx, sel_registerName("currentUserId")));
    if (uid) return uid;

    id chatMgr = ZLModSafeClassSingleton(@"ChatDataManager", sel_registerName("sharedChatDataManager"));
    uid = ZLModValidatedUserId(ZLModSafeStringProperty(chatMgr, sel_registerName("userId")));
    if (uid) return uid;
    uid = ZLModValidatedUserId(ZLModSafeStringProperty(chatMgr, sel_registerName("ownerId")));
    if (uid) return uid;

    id seenMgr = ZLModSafeClassSingleton(@"ChatSendSeenDataManager", sel_registerName("shared"));
    uid = ZLModValidatedUserId(ZLModSafeStringProperty(seenMgr, sel_registerName("ownerId")));
    if (uid) return uid;

    id ftsMgr = ZLModSafeClassSingleton(@"FTSDatabaseManager", sel_registerName("sharedInstance"));
    uid = ZLModValidatedUserId(ZLModSafeStringProperty(ftsMgr, sel_registerName("currentUserId")));
    if (uid) return uid;

    return nil;
}

NSString *ZLModCurrentRawUserId(void) {
    NSString *rawUid = ZLModProbeCurrentRawUserId();
    if (!rawUid) {
        os_unfair_lock_lock(&gAccountScopeLock);
        gCachedRawUid = nil;
        gCachedAccountScope = nil;
        os_unfair_lock_unlock(&gAccountScopeLock);
        return nil;
    }
    return rawUid;
}

NSString *ZLModCurrentAccountScope(void) {
    NSString *rawUid = ZLModProbeCurrentRawUserId();
    if (!rawUid) {
        os_unfair_lock_lock(&gAccountScopeLock);
        gCachedRawUid = nil;
        gCachedAccountScope = nil;
        os_unfair_lock_unlock(&gAccountScopeLock);
        return nil; // fail-closed: never fall back to a shared global bucket
    }

    os_unfair_lock_lock(&gAccountScopeLock);
    if (gCachedRawUid && [gCachedRawUid isEqualToString:rawUid] && gCachedAccountScope.length > 0) {
        NSString *cached = gCachedAccountScope;
        os_unfair_lock_unlock(&gAccountScopeLock);
        return cached;
    }
    os_unfair_lock_unlock(&gAccountScopeLock);

    NSString *hex = ZLModSha256Hex(rawUid);
    if (hex.length < 16) return nil;
    NSString *scope = [NSString stringWithFormat:@"acc_%@", [hex substringToIndex:16]];

    os_unfair_lock_lock(&gAccountScopeLock);
    gCachedRawUid = [rawUid copy];
    gCachedAccountScope = [scope copy];
    os_unfair_lock_unlock(&gAccountScopeLock);
    return scope;
}

NSArray<NSString *> *ZLModCandidateAccountScopesForMigration(void) {
    NSString *scope = ZLModCurrentAccountScope();
    if (scope.length == 0) return @[];
    return @[scope];
}

void ZLModInvalidateCachedAccountScope(void) {
    os_unfair_lock_lock(&gAccountScopeLock);
    gCachedRawUid = nil;
    gCachedAccountScope = nil;
    os_unfair_lock_unlock(&gAccountScopeLock);
}

#pragma mark - Storage Health Diagnostics

ZLModStorageHealthState ZLModCurrentStorageHealth(OSStatus *outStatus) {
    ZLModCryptoBox *box = [ZLModCryptoBox shared];
    if (![box isReady]) {
        OSStatus st = [box lastKeychainStatus];
        if (outStatus) *outStatus = st;
        return ZLModStorageHealthKeychainUnavailable;
    }
    if (ZLModCurrentAccountScope().length == 0) {
        if (outStatus) *outStatus = errSecSuccess;
        return ZLModStorageHealthAccountUnidentified;
    }
    if (outStatus) *outStatus = errSecSuccess;
    return ZLModStorageHealthReady;
}

NSString *ZLModStorageHealthDescription(void) {
    OSStatus st = errSecSuccess;
    ZLModStorageHealthState state = ZLModCurrentStorageHealth(&st);
    switch (state) {
        case ZLModStorageHealthReady:
            return @"Ready";
        case ZLModStorageHealthAccountUnidentified:
            return @"AccountUnidentified (chưa xác định tài khoản Zalo — fail-closed)";
        case ZLModStorageHealthKeychainUnavailable:
            return [NSString stringWithFormat:@"KeychainUnavailable (OSStatus=%d — kiểm tra quyền Keychain / mở khóa thiết bị)", (int)st];
    }
    return @"Unavailable";
}

#pragma mark - Crypto utilities

static void ZLModZeroMemory(void *ptr, size_t len) {
    if (!ptr || len == 0) return;
    volatile uint8_t *p = (volatile uint8_t *)ptr;
    while (len--) {
        *p++ = 0;
    }
}

static BOOL ZLModConstantTimeEqual(const uint8_t *a, const uint8_t *b, size_t len) {
    if (!a || !b || len == 0) return NO;
    uint8_t diff = 0;
    for (size_t i = 0; i < len; i++) {
        diff |= (a[i] ^ b[i]);
    }
    return diff == 0;
}

static NSData *ZLModDeriveSubkey(NSData *masterKey, const char *label) {
    if (!masterKey || masterKey.length != kCCKeySizeAES256 || !label) return nil;
    size_t labelLen = strlen(label);
    NSMutableData *input = [NSMutableData dataWithCapacity:labelLen + masterKey.length];
    [input appendBytes:label length:labelLen];
    [input appendData:masterKey];

    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(input.bytes, (CC_LONG)input.length, digest);
    ZLModZeroMemory(input.mutableBytes, input.length);

    NSData *out = [NSData dataWithBytes:digest length:CC_SHA256_DIGEST_LENGTH];
    ZLModZeroMemory(digest, sizeof(digest));
    return out;
}

#pragma mark - ZLModSecretStore (Keychain-only storage for Bridge Token & Discord Webhook)

@interface ZLModSecretStore () {
    os_unfair_lock _lock;
    OSStatus _lastErrorStatus;
}
@end

@implementation ZLModSecretStore

+ (instancetype)shared {
    static ZLModSecretStore *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ZLModSecretStore alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _lastErrorStatus = errSecSuccess;
    }
    return self;
}

- (OSStatus)lastErrorStatus {
    os_unfair_lock_lock(&_lock);
    OSStatus st = _lastErrorStatus;
    os_unfair_lock_unlock(&_lock);
    return st;
}

- (NSString *)accountNameForKey:(NSString *)key {
    if (key.length == 0) return nil;
    return [kZLModKeychainSecretPrefix stringByAppendingString:key];
}

- (NSString *)secretForKey:(NSString *)key {
    NSString *account = [self accountNameForKey:key];
    if (account.length == 0) return nil;

    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kZLModKeychainServiceName,
        (__bridge id)kSecAttrAccount: account,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne
    };

    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    os_unfair_lock_lock(&_lock);
    _lastErrorStatus = (status == errSecItemNotFound) ? errSecSuccess : status;
    os_unfair_lock_unlock(&_lock);

    if (status == errSecSuccess && result != NULL) {
        NSData *data = (__bridge_transfer NSData *)result;
        NSString *val = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        return val;
    }
    if (status != errSecItemNotFound) {
        ZLMOD_LOG(@"secretstore: Keychain read failed for %@ (OSStatus=%d)", key, (int)status);
    }
    return nil;
}

- (BOOL)setSecret:(NSString *)value forKey:(NSString *)key errorStatus:(OSStatus *)outStatus {
    NSString *account = [self accountNameForKey:key];
    if (account.length == 0) {
        if (outStatus) *outStatus = errSecParam;
        return NO;
    }
    if (value.length == 0) {
        BOOL removed = [self removeSecretForKey:key];
        if (outStatus) *outStatus = removed ? errSecSuccess : [self lastErrorStatus];
        return removed;
    }

    NSData *payload = [value dataUsingEncoding:NSUTF8StringEncoding];
    if (!payload) {
        if (outStatus) *outStatus = errSecParam;
        return NO;
    }

    NSDictionary *baseQuery = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kZLModKeychainServiceName,
        (__bridge id)kSecAttrAccount: account
    };
    NSDictionary *addQuery = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kZLModKeychainServiceName,
        (__bridge id)kSecAttrAccount: account,
        (__bridge id)kSecValueData: payload,
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    };

    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)addQuery, NULL);
    if (status == errSecDuplicateItem) {
        NSDictionary *updateFields = @{
            (__bridge id)kSecValueData: payload,
            (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        };
        status = SecItemUpdate((__bridge CFDictionaryRef)baseQuery, (__bridge CFDictionaryRef)updateFields);
    }

    os_unfair_lock_lock(&_lock);
    _lastErrorStatus = status;
    os_unfair_lock_unlock(&_lock);

    if (outStatus) *outStatus = status;
    if (status != errSecSuccess) {
        ZLMOD_LOG(@"secretstore: Keychain write failed for %@ (OSStatus=%d)", key, (int)status);
        return NO;
    }
    return YES;
}

- (BOOL)removeSecretForKey:(NSString *)key {
    NSString *account = [self accountNameForKey:key];
    if (account.length == 0) return NO;

    NSDictionary *delQuery = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kZLModKeychainServiceName,
        (__bridge id)kSecAttrAccount: account
    };
    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)delQuery);
    BOOL ok = (status == errSecSuccess || status == errSecItemNotFound);
    os_unfair_lock_lock(&_lock);
    _lastErrorStatus = ok ? errSecSuccess : status;
    os_unfair_lock_unlock(&_lock);
    return ok;
}

- (void)clearAllSecrets {
    for (NSString *key in [ZLModPreferences secretPreferenceKeys]) {
        [self removeSecretForKey:key];
    }
}

@end

#pragma mark - ZLModCryptoBox

@interface ZLModCryptoBox () {
    os_unfair_lock _lock;
    NSData *_masterKey;
    NSData *_encKey;
    NSData *_macKey;
    OSStatus _lastKeychainStatus;
}
@end

@implementation ZLModCryptoBox

+ (instancetype)shared {
    static ZLModCryptoBox *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ZLModCryptoBox alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _lastKeychainStatus = errSecSuccess;
        [self ensureKeys];
    }
    return self;
}

- (OSStatus)lastKeychainStatus {
    os_unfair_lock_lock(&_lock);
    OSStatus st = _lastKeychainStatus;
    os_unfair_lock_unlock(&_lock);
    return st;
}

- (NSData *)loadOrCreateMasterKeyWithStatus:(OSStatus *)outStatus {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kZLModKeychainServiceName,
        (__bridge id)kSecAttrAccount: kZLModKeychainMasterKeyAccount,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne
    };

    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status == errSecSuccess && result != NULL) {
        NSData *existing = (__bridge_transfer NSData *)result;
        if (existing.length == kCCKeySizeAES256) {
            if (outStatus) *outStatus = errSecSuccess;
            return existing;
        }
        // Corrupt length item only: remove and regenerate cleanly.
        NSDictionary *delQuery = @{
            (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrService: kZLModKeychainServiceName,
            (__bridge id)kSecAttrAccount: kZLModKeychainMasterKeyAccount
        };
        SecItemDelete((__bridge CFDictionaryRef)delQuery);
    } else if (status != errSecItemNotFound) {
        // Fail closed on transient keychain lock/error rather than overwriting valid key material.
        if (outStatus) *outStatus = status;
        ZLMOD_LOG(@"crypto: Keychain lookup unavailable (OSStatus=%d) — fail-closed", (int)status);
        return nil;
    }

    NSMutableData *newKey = [NSMutableData dataWithLength:kCCKeySizeAES256];
    if (CCRandomGenerateBytes(newKey.mutableBytes, newKey.length) != kCCSuccess) {
        if (outStatus) *outStatus = errSecInternalError;
        ZLMOD_LOG(@"crypto: CCRandomGenerateBytes failed — fail-closed");
        return nil;
    }

    NSDictionary *addQuery = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kZLModKeychainServiceName,
        (__bridge id)kSecAttrAccount: kZLModKeychainMasterKeyAccount,
        (__bridge id)kSecValueData: newKey,
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    };
    OSStatus addStatus = SecItemAdd((__bridge CFDictionaryRef)addQuery, NULL);
    if (addStatus == errSecDuplicateItem) {
        CFTypeRef retryRef = NULL;
        OSStatus retryStatus = SecItemCopyMatching((__bridge CFDictionaryRef)query, &retryRef);
        if (retryStatus == errSecSuccess && retryRef != NULL) {
            NSData *existing = (__bridge_transfer NSData *)retryRef;
            if (existing.length == kCCKeySizeAES256) {
                ZLModZeroMemory(newKey.mutableBytes, newKey.length);
                if (outStatus) *outStatus = errSecSuccess;
                return existing;
            }
        }
    }
    if (addStatus != errSecSuccess) {
        ZLModZeroMemory(newKey.mutableBytes, newKey.length);
        if (outStatus) *outStatus = addStatus;
        ZLMOD_LOG(@"crypto: SecItemAdd failed (OSStatus=%d) — fail-closed", (int)addStatus);
        return nil;
    }

    if (outStatus) *outStatus = errSecSuccess;
    ZLMOD_LOG(@"crypto: provisioned Keychain master key v2");
    return [newKey copy];
}

- (BOOL)ensureKeys {
    os_unfair_lock_lock(&_lock);
    if (_masterKey && _encKey && _macKey) {
        _lastKeychainStatus = errSecSuccess;
        os_unfair_lock_unlock(&_lock);
        return YES;
    }
    os_unfair_lock_unlock(&_lock);

    OSStatus st = errSecSuccess;
    NSData *mk = [self loadOrCreateMasterKeyWithStatus:&st];
    if (!mk) {
        os_unfair_lock_lock(&_lock);
        _lastKeychainStatus = (st != errSecSuccess) ? st : errSecAuthFailed;
        os_unfair_lock_unlock(&_lock);
        return NO;
    }
    NSData *ek = ZLModDeriveSubkey(mk, "ZLMod.ENC.v2:");
    NSData *ak = ZLModDeriveSubkey(mk, "ZLMod.MAC.v2:");
    if (!ek || !ak) {
        os_unfair_lock_lock(&_lock);
        _lastKeychainStatus = errSecInternalError;
        os_unfair_lock_unlock(&_lock);
        return NO;
    }

    os_unfair_lock_lock(&_lock);
    _masterKey = mk;
    _encKey = ek;
    _macKey = ak;
    _lastKeychainStatus = errSecSuccess;
    os_unfair_lock_unlock(&_lock);
    return YES;
}

- (BOOL)isReady {
    return [self ensureKeys];
}

- (NSData *)encryptData:(NSData *)plainData metadata:(NSData *)metadata {
    if (![plainData isKindOfClass:[NSData class]] || plainData.length == 0) return nil;
    if (![self ensureKeys]) return nil;

    os_unfair_lock_lock(&_lock);
    NSData *encKey = _encKey;
    NSData *macKey = _macKey;
    os_unfair_lock_unlock(&_lock);
    if (!encKey || !macKey) return nil;

    NSMutableData *iv = [NSMutableData dataWithLength:kCCBlockSizeAES128];
    if (CCRandomGenerateBytes(iv.mutableBytes, iv.length) != kCCSuccess) {
        return nil;
    }

    NSMutableData *cipher = [NSMutableData dataWithLength:plainData.length + kCCBlockSizeAES128];
    size_t outLen = 0;
    CCCryptorStatus st = CCCrypt(kCCEncrypt,
                                 kCCAlgorithmAES,
                                 kCCOptionPKCS7Padding,
                                 encKey.bytes,
                                 kCCKeySizeAES256,
                                 iv.bytes,
                                 plainData.bytes,
                                 plainData.length,
                                 cipher.mutableBytes,
                                 cipher.length,
                                 &outLen);
    if (st != kCCSuccess) {
        ZLMOD_LOG(@"crypto: CCCrypt encrypt failed (%d)", (int)st);
        return nil;
    }
    cipher.length = outLen;

    uint8_t ver = kZLModCryptoRecordVersion;
    NSMutableData *package = [NSMutableData dataWithCapacity:1 + iv.length + cipher.length + CC_SHA256_DIGEST_LENGTH];
    [package appendBytes:&ver length:1];
    [package appendData:iv];
    [package appendData:cipher];

    NSMutableData *hmacInput = [NSMutableData dataWithData:package];
    if (metadata.length > 0) {
        [hmacInput appendData:metadata];
    }

    unsigned char mac[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, macKey.bytes, macKey.length, hmacInput.bytes, hmacInput.length, mac);
    [package appendBytes:mac length:CC_SHA256_DIGEST_LENGTH];
    ZLModZeroMemory(mac, sizeof(mac));

    return [package copy];
}

- (NSData *)decryptRawData:(NSData *)packageData metadata:(NSData *)metadata {
    if (![packageData isKindOfClass:[NSData class]]) return nil;
    if (![self ensureKeys]) return nil;

    static const size_t kMinLen = 1 + kCCBlockSizeAES128 + kCCBlockSizeAES128 + CC_SHA256_DIGEST_LENGTH;
    if (packageData.length < kMinLen) return nil;

    const uint8_t *bytes = (const uint8_t *)packageData.bytes;
    if (bytes[0] != kZLModCryptoRecordVersion) return nil;

    size_t authLen = packageData.length - CC_SHA256_DIGEST_LENGTH;
    size_t cipherLen = authLen - 1 - kCCBlockSizeAES128;
    if (cipherLen == 0 || (cipherLen % kCCBlockSizeAES128) != 0) return nil;

    os_unfair_lock_lock(&_lock);
    NSData *encKey = _encKey;
    NSData *macKey = _macKey;
    os_unfair_lock_unlock(&_lock);
    if (!encKey || !macKey) return nil;

    NSMutableData *hmacInput = [NSMutableData dataWithBytes:bytes length:authLen];
    if (metadata.length > 0) {
        [hmacInput appendData:metadata];
    }

    unsigned char computedMac[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, macKey.bytes, macKey.length, hmacInput.bytes, hmacInput.length, computedMac);
    BOOL ok = ZLModConstantTimeEqual(bytes + authLen, computedMac, CC_SHA256_DIGEST_LENGTH);
    ZLModZeroMemory(computedMac, sizeof(computedMac));
    if (!ok) {
        ZLMOD_LOG(@"crypto: HMAC verification failed");
        return nil;
    }

    const void *ivBytes = bytes + 1;
    const void *cipherBytes = bytes + 1 + kCCBlockSizeAES128;
    NSMutableData *plain = [NSMutableData dataWithLength:cipherLen + kCCBlockSizeAES128];
    size_t decLen = 0;
    CCCryptorStatus st = CCCrypt(kCCDecrypt,
                                 kCCAlgorithmAES,
                                 kCCOptionPKCS7Padding,
                                 encKey.bytes,
                                 kCCKeySizeAES256,
                                 ivBytes,
                                 cipherBytes,
                                 cipherLen,
                                 plain.mutableBytes,
                                 plain.length,
                                 &decLen);
    if (st != kCCSuccess) {
        ZLModZeroMemory(plain.mutableBytes, plain.length);
        ZLMOD_LOG(@"crypto: CCCrypt decrypt failed (%d)", (int)st);
        return nil;
    }
    plain.length = decLen;
    NSData *out = [plain copy];
    ZLModZeroMemory(plain.mutableBytes, plain.length);
    return out;
}

- (NSData *)encryptString:(NSString *)plainText metadata:(NSData *)metadata {
    if (![plainText isKindOfClass:[NSString class]] || plainText.length == 0) return nil;
    NSData *plainData = [plainText dataUsingEncoding:NSUTF8StringEncoding];
    if (!plainData || plainData.length == 0) return nil;
    return [self encryptData:plainData metadata:metadata];
}

- (NSString *)decryptData:(NSData *)packageData metadata:(NSData *)metadata {
    NSData *plain = [self decryptRawData:packageData metadata:metadata];
    if (!plain || plain.length == 0) return nil;
    return [[NSString alloc] initWithData:plain encoding:NSUTF8StringEncoding];
}

@end
