// language: Objective-C, file: ZLModPolicyStore.m, target: iOS 15.1+ (Zalo 26.10.02 & 26.11.01, arm64)
// Active chat context stack (LIFO safe across nested chat pushes) and account-scoped
// per-conversation policy persistence (v3 with encrypted display titles, v2 read-compatible,
// non-blocking async disk writes outside locks, fail-closed when account unidentified).

#import "ZLMod.h"
#import <os/lock.h>

NSString *const ZLModConversationPolicyDidChangeNotification = @"ZLModConversationPolicyDidChangeNotification";
NSString *const ZLModPolicyThreadIdKey = @"threadId";

#pragma mark - ZLModPrivacyContext (LIFO Stack)

@interface ZLModChatContextEntry : NSObject
@property (nonatomic, weak) id controller;
@property (nonatomic, copy) NSString *threadId;
@property (nonatomic, copy) NSString *convType;
@end

@implementation ZLModChatContextEntry
@end

static os_unfair_lock gPrivacyCtxLock = OS_UNFAIR_LOCK_INIT;
static NSMutableArray<ZLModChatContextEntry *> *gChatContextStack = nil;

static void ZLModPruneDeadContextLocked(void) {
    if (!gChatContextStack) return;
    for (NSInteger i = (NSInteger)gChatContextStack.count - 1; i >= 0; i--) {
        if (gChatContextStack[(NSUInteger)i].controller == nil) {
            [gChatContextStack removeObjectAtIndex:(NSUInteger)i];
        }
    }
}

@implementation ZLModPrivacyContext

+ (void)noteChatControllerDidAppear:(id)controller
                           threadId:(NSString *)threadId
                   conversationType:(NSString *)convType {
    if (!controller) return;
    NSString *cleanThread = ([threadId isKindOfClass:[NSString class]] && threadId.length > 0) ? [threadId copy] : nil;
    NSString *cleanType = [convType isEqualToString:@"group"] ? @"group" : @"single";

    os_unfair_lock_lock(&gPrivacyCtxLock);
    if (!gChatContextStack) {
        gChatContextStack = [NSMutableArray array];
    }
    ZLModPruneDeadContextLocked();
    // Remove any previous entry for the same controller before pushing to top.
    for (NSInteger i = (NSInteger)gChatContextStack.count - 1; i >= 0; i--) {
        if (gChatContextStack[(NSUInteger)i].controller == controller) {
            [gChatContextStack removeObjectAtIndex:(NSUInteger)i];
        }
    }
    ZLModChatContextEntry *entry = [[ZLModChatContextEntry alloc] init];
    entry.controller = controller;
    entry.threadId = cleanThread;
    entry.convType = cleanType;
    [gChatContextStack addObject:entry];
    os_unfair_lock_unlock(&gPrivacyCtxLock);
}

+ (void)noteChatControllerWillDisappear:(id)controller {
    os_unfair_lock_lock(&gPrivacyCtxLock);
    ZLModPruneDeadContextLocked();
    if (!controller) {
        [gChatContextStack removeAllObjects];
    } else {
        for (NSInteger i = (NSInteger)gChatContextStack.count - 1; i >= 0; i--) {
            if (gChatContextStack[(NSUInteger)i].controller == controller) {
                [gChatContextStack removeObjectAtIndex:(NSUInteger)i];
            }
        }
    }
    os_unfair_lock_unlock(&gPrivacyCtxLock);
}

+ (id)activeChatController {
    os_unfair_lock_lock(&gPrivacyCtxLock);
    ZLModPruneDeadContextLocked();
    id controller = gChatContextStack.lastObject.controller;
    os_unfair_lock_unlock(&gPrivacyCtxLock);
    return controller;
}

+ (NSString *)activeThreadId {
    os_unfair_lock_lock(&gPrivacyCtxLock);
    ZLModPruneDeadContextLocked();
    NSString *tid = gChatContextStack.lastObject.threadId;
    os_unfair_lock_unlock(&gPrivacyCtxLock);
    return tid;
}

+ (NSString *)activeConversationType {
    os_unfair_lock_lock(&gPrivacyCtxLock);
    ZLModPruneDeadContextLocked();
    NSString *ct = gChatContextStack.lastObject.convType;
    os_unfair_lock_unlock(&gPrivacyCtxLock);
    return ct;
}

+ (void)clearActiveContext {
    os_unfair_lock_lock(&gPrivacyCtxLock);
    [gChatContextStack removeAllObjects];
    os_unfair_lock_unlock(&gPrivacyCtxLock);
}

@end

#pragma mark - ZLModConversationPolicyStore

@interface ZLModConversationPolicyStore () {
    os_unfair_lock _lock;
}
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableDictionary *> *policies;
@property (nonatomic, copy) NSString *storagePath;
@end

@implementation ZLModConversationPolicyStore

+ (instancetype)shared {
    static ZLModConversationPolicyStore *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ZLModConversationPolicyStore alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _policies = [NSMutableDictionary dictionary];

        NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docs = paths.firstObject ?: NSTemporaryDirectory();
        _storagePath = [docs stringByAppendingPathComponent:@"ZLModPolicies.plist"];

        [self loadFromDiskLocked];

        [[NSNotificationCenter defaultCenter] addObserverForName:ZLModAccountDidChangeNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *note) {
            [ZLModPrivacyContext clearActiveContext];
            [[NSNotificationCenter defaultCenter] postNotificationName:ZLModConversationPolicyDidChangeNotification
                                                                object:nil
                                                              userInfo:nil];
        }];
    }
    return self;
}

+ (NSString *)normalizedType:(NSString *)convType {
    if ([convType isEqualToString:@"group"]) return @"group";
    return @"single";
}

+ (NSString *)compoundKeyForAccountScope:(NSString *)accountScope
                        conversationType:(NSString *)convType
                                threadId:(NSString *)threadId {
    if (![accountScope isKindOfClass:[NSString class]] || accountScope.length == 0) return nil;
    if (![threadId isKindOfClass:[NSString class]] || threadId.length == 0) return nil;
    return [NSString stringWithFormat:@"%@:%@:%@", accountScope, [self normalizedType:convType], threadId];
}

+ (NSData *)titleMetadataForAccountScope:(NSString *)scope
                        conversationType:(NSString *)convType
                                threadId:(NSString *)threadId {
    NSString *bound = [NSString stringWithFormat:@"ZLModPolicyTitle.v3|%@|%@|%@",
                       scope ?: @"", [self normalizedType:convType], threadId ?: @""];
    return [bound dataUsingEncoding:NSUTF8StringEncoding];
}

- (void)loadFromDiskLocked {
    if (![[NSFileManager defaultManager] fileExistsAtPath:self.storagePath]) return;
    @try {
        NSData *data = [NSData dataWithContentsOfFile:self.storagePath];
        if (!data) return;
        id plist = [NSPropertyListSerialization propertyListWithData:data
                                                             options:NSPropertyListImmutable
                                                              format:NULL
                                                               error:nil];
        if (![plist isKindOfClass:[NSDictionary class]]) return;
        NSNumber *version = plist[@"version"];
        NSDictionary *rawPolicies = plist[@"policies"];
        if (![version isKindOfClass:[NSNumber class]] ||
            (version.integerValue != 2 && version.integerValue != 3) ||
            ![rawPolicies isKindOfClass:[NSDictionary class]]) {
            return;
        }
        [rawPolicies enumerateKeysAndObjectsUsingBlock:^(id key, id obj, __unused BOOL *stop) {
            if ([key isKindOfClass:[NSString class]] && [obj isKindOfClass:[NSDictionary class]]) {
                self.policies[(NSString *)key] = [(NSDictionary *)obj mutableCopy];
            }
        }];
    } @catch (__unused NSException *e) {
        ZLMOD_LOG(@"policy store: exception loading plist");
    }
}

- (NSDictionary *)immutableSnapshotLocked {
    NSMutableDictionary *serializedPolicies = [NSMutableDictionary dictionaryWithCapacity:self.policies.count];
    [self.policies enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSMutableDictionary *val, __unused BOOL *stop) {
        serializedPolicies[key] = [val copy];
    }];
    return @{
        @"version": @3,
        @"policies": [serializedPolicies copy]
    };
}

- (NSMutableDictionary *)entryLockedForAccountScope:(NSString *)accountScope
                                   conversationType:(NSString *)convType
                                           threadId:(NSString *)threadId {
    NSString *key = [[self class] compoundKeyForAccountScope:accountScope conversationType:convType threadId:threadId];
    if (!key) return nil;
    return self.policies[key];
}

- (BOOL)updateField:(NSString *)field
              value:(id)value
    forAccountScope:(NSString *)accountScope
   conversationType:(NSString *)convType
           threadId:(NSString *)threadId {
    NSString *key = [[self class] compoundKeyForAccountScope:accountScope conversationType:convType threadId:threadId];
    if (!key) return NO;

    NSDictionary *snapshot = nil;
    os_unfair_lock_lock(&_lock);
    NSMutableDictionary *entry = self.policies[key] ? [self.policies[key] mutableCopy] : [NSMutableDictionary dictionary];
    entry[field] = value;
    entry[@"convType"] = [[self class] normalizedType:convType];
    entry[@"updatedAt"] = @([[NSDate date] timeIntervalSince1970]);

    BOOL allDefault = ([entry[@"seen"] integerValue] == 0 &&
                       [entry[@"typing"] integerValue] == 0 &&
                       ![entry[@"unread"] boolValue]);
    if (allDefault) {
        [self.policies removeObjectForKey:key];
    } else {
        self.policies[key] = entry;
    }
    snapshot = [self immutableSnapshotLocked];
    os_unfair_lock_unlock(&_lock);

    // Non-blocking atomic disk write outside lock.
    ZLModWritePropertyListAsync(snapshot, self.storagePath, nil);
    [self postPolicyDidChangeForThreadId:threadId];
    return YES;
}

- (void)updateDisplayTitle:(NSString *)displayTitle
           forAccountScope:(NSString *)accountScope
          conversationType:(NSString *)convType
                  threadId:(NSString *)threadId {
    if (displayTitle.length == 0 || accountScope.length == 0 || threadId.length == 0) return;
    if ([displayTitle isEqualToString:@"Cuộc trò chuyện"]) return;
    NSString *key = [[self class] compoundKeyForAccountScope:accountScope conversationType:convType threadId:threadId];
    if (!key) return;

    NSData *meta = [[self class] titleMetadataForAccountScope:accountScope conversationType:convType threadId:threadId];
    NSData *cipher = [[ZLModCryptoBox shared] encryptString:displayTitle metadata:meta];
    if (!cipher) return;

    NSDictionary *snapshot = nil;
    os_unfair_lock_lock(&_lock);
    NSMutableDictionary *entry = self.policies[key];
    if (entry) {
        entry[@"titleCipher"] = cipher;
        snapshot = [self immutableSnapshotLocked];
    }
    os_unfair_lock_unlock(&_lock);

    if (snapshot) {
        ZLModWritePropertyListAsync(snapshot, self.storagePath, nil);
    }
}

- (void)postPolicyDidChangeForThreadId:(NSString *)threadId {
    NSDictionary *info = (threadId.length > 0) ? @{ ZLModPolicyThreadIdKey: [threadId copy] } : nil;
    ZLModRunOnMainThread(^{
        [[NSNotificationCenter defaultCenter] postNotificationName:ZLModConversationPolicyDidChangeNotification
                                                            object:nil
                                                          userInfo:info];
    });
}

#pragma mark - Seen policy

- (ZLModSeenPolicy)seenPolicyForAccountScope:(NSString *)accountScope
                             conversationType:(NSString *)convType
                                     threadId:(NSString *)threadId {
    if (accountScope.length == 0 || threadId.length == 0) return ZLModSeenPolicyFollowOriginal;
    os_unfair_lock_lock(&_lock);
    NSMutableDictionary *entry = [self entryLockedForAccountScope:accountScope conversationType:convType threadId:threadId];
    NSInteger raw = entry ? [entry[@"seen"] integerValue] : ZLModSeenPolicyFollowOriginal;
    os_unfair_lock_unlock(&_lock);
    return (raw == ZLModSeenPolicyHideSeen) ? ZLModSeenPolicyHideSeen : ZLModSeenPolicyFollowOriginal;
}

- (BOOL)setSeenPolicy:(ZLModSeenPolicy)policy
      forAccountScope:(NSString *)accountScope
     conversationType:(NSString *)convType
             threadId:(NSString *)threadId {
    return [self updateField:@"seen"
                       value:@(policy)
             forAccountScope:accountScope
            conversationType:convType
                    threadId:threadId];
}

- (BOOL)isHideSeenForThreadId:(NSString *)threadId conversationType:(NSString *)convType {
    if (threadId.length == 0) return NO;
    NSString *scope = ZLModCurrentAccountScope();
    if (scope.length == 0) return NO;

    os_unfair_lock_lock(&_lock);
    NSMutableDictionary *exact = (convType.length > 0)
        ? [self entryLockedForAccountScope:scope conversationType:convType threadId:threadId]
        : nil;
    BOOL hide = NO;
    if (exact) {
        hide = ([exact[@"seen"] integerValue] == ZLModSeenPolicyHideSeen);
    } else if (convType.length == 0) {
        NSMutableDictionary *s = [self entryLockedForAccountScope:scope conversationType:@"single" threadId:threadId];
        NSMutableDictionary *g = [self entryLockedForAccountScope:scope conversationType:@"group" threadId:threadId];
        hide = ([s[@"seen"] integerValue] == ZLModSeenPolicyHideSeen) ||
               ([g[@"seen"] integerValue] == ZLModSeenPolicyHideSeen);
    } else {
        NSString *alt = [[self class] normalizedType:convType];
        NSString *other = [alt isEqualToString:@"group"] ? @"single" : @"group";
        NSMutableDictionary *fallback = [self entryLockedForAccountScope:scope conversationType:other threadId:threadId];
        hide = fallback ? ([fallback[@"seen"] integerValue] == ZLModSeenPolicyHideSeen) : NO;
    }
    os_unfair_lock_unlock(&_lock);
    return hide;
}

#pragma mark - Typing policy

- (ZLModTypingPolicy)typingPolicyForAccountScope:(NSString *)accountScope
                                 conversationType:(NSString *)convType
                                         threadId:(NSString *)threadId {
    if (accountScope.length == 0 || threadId.length == 0) return ZLModTypingPolicyFollowOriginal;
    os_unfair_lock_lock(&_lock);
    NSMutableDictionary *entry = [self entryLockedForAccountScope:accountScope conversationType:convType threadId:threadId];
    NSInteger raw = entry ? [entry[@"typing"] integerValue] : ZLModTypingPolicyFollowOriginal;
    os_unfair_lock_unlock(&_lock);
    return (raw == ZLModTypingPolicyHideTyping) ? ZLModTypingPolicyHideTyping : ZLModTypingPolicyFollowOriginal;
}

- (BOOL)setTypingPolicy:(ZLModTypingPolicy)policy
        forAccountScope:(NSString *)accountScope
       conversationType:(NSString *)convType
               threadId:(NSString *)threadId {
    return [self updateField:@"typing"
                       value:@(policy)
             forAccountScope:accountScope
            conversationType:convType
                    threadId:threadId];
}

- (BOOL)isHideTypingForThreadId:(NSString *)threadId conversationType:(NSString *)convType {
    if (threadId.length == 0) return NO;
    NSString *scope = ZLModCurrentAccountScope();
    if (scope.length == 0) return NO;

    os_unfair_lock_lock(&_lock);
    NSMutableDictionary *exact = (convType.length > 0)
        ? [self entryLockedForAccountScope:scope conversationType:convType threadId:threadId]
        : nil;
    BOOL hide = NO;
    if (exact) {
        hide = ([exact[@"typing"] integerValue] == ZLModTypingPolicyHideTyping);
    } else if (convType.length == 0) {
        NSMutableDictionary *s = [self entryLockedForAccountScope:scope conversationType:@"single" threadId:threadId];
        NSMutableDictionary *g = [self entryLockedForAccountScope:scope conversationType:@"group" threadId:threadId];
        hide = ([s[@"typing"] integerValue] == ZLModTypingPolicyHideTyping) ||
               ([g[@"typing"] integerValue] == ZLModTypingPolicyHideTyping);
    } else {
        NSString *alt = [[self class] normalizedType:convType];
        NSString *other = [alt isEqualToString:@"group"] ? @"single" : @"group";
        NSMutableDictionary *fallback = [self entryLockedForAccountScope:scope conversationType:other threadId:threadId];
        hide = fallback ? ([fallback[@"typing"] integerValue] == ZLModTypingPolicyHideTyping) : NO;
    }
    os_unfair_lock_unlock(&_lock);
    return hide;
}

#pragma mark - Local unread mark

- (BOOL)isLocalUnreadForAccountScope:(NSString *)accountScope
                     conversationType:(NSString *)convType
                             threadId:(NSString *)threadId {
    if (accountScope.length == 0 || threadId.length == 0) return NO;
    os_unfair_lock_lock(&_lock);
    NSMutableDictionary *entry = [self entryLockedForAccountScope:accountScope conversationType:convType threadId:threadId];
    BOOL unread = entry ? [entry[@"unread"] boolValue] : NO;
    os_unfair_lock_unlock(&_lock);
    return unread;
}

- (BOOL)setLocalUnread:(BOOL)marked
       forAccountScope:(NSString *)accountScope
      conversationType:(NSString *)convType
              threadId:(NSString *)threadId {
    return [self updateField:@"unread"
                       value:@(marked)
             forAccountScope:accountScope
            conversationType:convType
                    threadId:threadId];
}

- (BOOL)isLocalUnreadAnyTypeForThreadId:(NSString *)threadId {
    if (threadId.length == 0) return NO;
    NSString *scope = ZLModCurrentAccountScope();
    if (scope.length == 0) return NO;

    os_unfair_lock_lock(&_lock);
    NSMutableDictionary *s = [self entryLockedForAccountScope:scope conversationType:@"single" threadId:threadId];
    NSMutableDictionary *g = [self entryLockedForAccountScope:scope conversationType:@"group" threadId:threadId];
    BOOL marked = (s && [s[@"unread"] boolValue]) || (g && [g[@"unread"] boolValue]);
    os_unfair_lock_unlock(&_lock);
    return marked;
}

#pragma mark - Inspection & reset

- (NSArray<NSDictionary<NSString *, id> *> *)summaryEntriesForCurrentAccount {
    NSString *scope = ZLModCurrentAccountScope();
    if (scope.length == 0) return @[];
    NSString *prefix = [scope stringByAppendingString:@":"];

    NSMutableArray<NSDictionary *> *rawRows = [NSMutableArray array];
    os_unfair_lock_lock(&_lock);
    [self.policies enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSMutableDictionary *entry, __unused BOOL *stop) {
        if (![key hasPrefix:prefix]) return;
        NSString *rest = [key substringFromIndex:prefix.length];
        NSRange colon = [rest rangeOfString:@":"];
        if (colon.location == NSNotFound) return;
        NSString *convType = [rest substringToIndex:colon.location];
        NSString *threadId = [rest substringFromIndex:colon.location + 1];

        BOOL hideSeen = ([entry[@"seen"] integerValue] == ZLModSeenPolicyHideSeen);
        BOOL hideTyping = ([entry[@"typing"] integerValue] == ZLModTypingPolicyHideTyping);
        BOOL localUnread = [entry[@"unread"] boolValue];
        if (!hideSeen && !hideTyping && !localUnread) return;

        NSMutableDictionary *copy = [NSMutableDictionary dictionaryWithDictionary:@{
            @"key": key,
            @"convType": convType,
            @"threadId": threadId,
            @"threadHash": ZLModSafeIdHash(threadId),
            @"hideSeen": @(hideSeen),
            @"hideTyping": @(hideTyping),
            @"localUnread": @(localUnread),
            @"updatedAt": entry[@"updatedAt"] ?: @0
        }];
        if ([entry[@"titleCipher"] isKindOfClass:[NSData class]]) {
            copy[@"titleCipher"] = entry[@"titleCipher"];
        }
        [rawRows addObject:copy];
    }];
    os_unfair_lock_unlock(&_lock);

    [rawRows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"updatedAt"] compare:a[@"updatedAt"]];
    }];

    // Decrypt titles outside lock.
    NSMutableArray<NSDictionary<NSString *, id> *> *rows = [NSMutableArray arrayWithCapacity:rawRows.count];
    for (NSDictionary *raw in rawRows) {
        NSString *displayTitle = @"";
        NSData *cipher = raw[@"titleCipher"];
        if ([cipher isKindOfClass:[NSData class]]) {
            NSData *meta = [[self class] titleMetadataForAccountScope:scope
                                                     conversationType:raw[@"convType"]
                                                             threadId:raw[@"threadId"]];
            displayTitle = [[ZLModCryptoBox shared] decryptData:cipher metadata:meta] ?: @"";
        }
        [rows addObject:@{
            @"key": raw[@"key"],
            @"convType": raw[@"convType"],
            @"threadHash": raw[@"threadHash"],
            @"displayTitle": displayTitle,
            @"hideSeen": raw[@"hideSeen"],
            @"hideTyping": raw[@"hideTyping"],
            @"localUnread": raw[@"localUnread"],
            @"updatedAt": raw[@"updatedAt"]
        }];
    }
    return [rows copy];
}

- (NSUInteger)customizedCountForCurrentAccount {
    NSString *scope = ZLModCurrentAccountScope();
    if (scope.length == 0) return 0;
    NSString *prefix = [scope stringByAppendingString:@":"];

    __block NSUInteger count = 0;
    os_unfair_lock_lock(&_lock);
    [self.policies enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSMutableDictionary *entry, __unused BOOL *stop) {
        if (![key hasPrefix:prefix]) return;
        BOOL active = ([entry[@"seen"] integerValue] == ZLModSeenPolicyHideSeen) ||
                      ([entry[@"typing"] integerValue] == ZLModTypingPolicyHideTyping) ||
                      [entry[@"unread"] boolValue];
        if (active) count++;
    }];
    os_unfair_lock_unlock(&_lock);
    return count;
}

- (BOOL)resetPolicyAtCompoundKey:(NSString *)compoundKey {
    NSString *scope = ZLModCurrentAccountScope();
    if (scope.length == 0 || compoundKey.length == 0) return NO;
    NSString *prefix = [scope stringByAppendingString:@":"];
    if (![compoundKey hasPrefix:prefix]) return NO; // fail-closed cross-account guard

    NSDictionary *snapshot = nil;
    BOOL removed = NO;
    os_unfair_lock_lock(&_lock);
    if (self.policies[compoundKey]) {
        [self.policies removeObjectForKey:compoundKey];
        snapshot = [self immutableSnapshotLocked];
        removed = YES;
    }
    os_unfair_lock_unlock(&_lock);

    if (removed) {
        ZLModWritePropertyListAsync(snapshot, self.storagePath, nil);
        [self postPolicyDidChangeForThreadId:nil];
    }
    return removed;
}

- (NSUInteger)resetPoliciesForCurrentAccount {
    NSString *scope = ZLModCurrentAccountScope();
    if (scope.length == 0) return 0;
    NSString *prefix = [scope stringByAppendingString:@":"];

    NSDictionary *snapshot = nil;
    NSUInteger removedCount = 0;
    os_unfair_lock_lock(&_lock);
    NSMutableArray<NSString *> *toRemove = [NSMutableArray array];
    for (NSString *key in self.policies) {
        if ([key hasPrefix:prefix]) [toRemove addObject:key];
    }
    if (toRemove.count > 0) {
        [self.policies removeObjectsForKeys:toRemove];
        removedCount = toRemove.count;
        snapshot = [self immutableSnapshotLocked];
    }
    os_unfair_lock_unlock(&_lock);

    if (removedCount > 0) {
        ZLModWritePropertyListAsync(snapshot, self.storagePath, nil);
        [self postPolicyDidChangeForThreadId:nil];
    }
    return removedCount;
}

- (void)resetAllPolicies {
    NSDictionary *snapshot = nil;
    os_unfair_lock_lock(&_lock);
    [self.policies removeAllObjects];
    snapshot = [self immutableSnapshotLocked];
    os_unfair_lock_unlock(&_lock);

    ZLModWritePropertyListAsync(snapshot, self.storagePath, nil);
    [self postPolicyDidChangeForThreadId:nil];
    ZLMOD_LOG(@"policy store: all policies reset");
}

@end
