// language: Objective-C, file: ZLModMessageTap.m, target: iOS 15.1+ (Zalo 26.10.02 & 26.11.01, arm64)
// Decoupled Message Tap Bus (MODULE 07):
//   ChatEntity -> ZLModChatEntityAdapter -> ZLModMessageTapBus -> { AntiRecall, CSaving, DiscordRelay, ... }
//   - Independent of the Anti-Recall toggle (CSaving & Discord relay work even when Anti-Recall is OFF).
//   - Bounded LRU deduplication across addChat:, addChats:, and didLoadChats: so each
//     message event (Observed vs Recalled) is emitted at most once.

#import "ZLMod.h"
#import <os/lock.h>

@interface ZLModTapConsumerEntry : NSObject
@property (nonatomic, copy) NSString *token;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) ZLModMessageTapConsumer block;
@end

@implementation ZLModTapConsumerEntry
@end

@interface ZLModMessageTapBus () {
    os_unfair_lock _lock;
}
@property (nonatomic, strong) NSMutableArray<ZLModTapConsumerEntry *> *consumers;
@property (nonatomic, strong) NSMutableSet<NSString *> *seenEventKeys;
@property (nonatomic, strong) NSMutableArray<NSString *> *seenEventOrder;
@end

@implementation ZLModMessageTapBus

+ (instancetype)shared {
    static ZLModMessageTapBus *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ZLModMessageTapBus alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _consumers = [NSMutableArray array];
        _seenEventKeys = [NSMutableSet set];
        _seenEventOrder = [NSMutableArray array];
    }
    return self;
}

- (NSString *)registerConsumerNamed:(NSString *)name block:(ZLModMessageTapConsumer)block {
    if (!block) return nil;
    NSString *token = [[NSUUID UUID] UUIDString];
    ZLModTapConsumerEntry *entry = [[ZLModTapConsumerEntry alloc] init];
    entry.token = token;
    entry.name = name ?: @"consumer";
    entry.block = block;

    os_unfair_lock_lock(&_lock);
    // Replace any existing consumer with the same logical name to guarantee zero duplicate listeners.
    for (NSInteger i = (NSInteger)self.consumers.count - 1; i >= 0; i--) {
        if ([self.consumers[(NSUInteger)i].name isEqualToString:entry.name]) {
            [self.consumers removeObjectAtIndex:(NSUInteger)i];
        }
    }
    [self.consumers addObject:entry];
    os_unfair_lock_unlock(&_lock);
    return token;
}

- (void)unregisterConsumerWithToken:(NSString *)token {
    if (token.length == 0) return;
    os_unfair_lock_lock(&_lock);
    for (NSInteger i = (NSInteger)self.consumers.count - 1; i >= 0; i--) {
        if ([self.consumers[(NSUInteger)i].token isEqualToString:token]) {
            [self.consumers removeObjectAtIndex:(NSUInteger)i];
        }
    }
    os_unfair_lock_unlock(&_lock);
}

- (BOOL)hasActiveTapDemand {
    ZLModPreferences *prefs = [ZLModPreferences shared];
    if ([prefs boolForKey:kZLModAntiRecall] ||
        [prefs boolForKey:kZLModBridgeSaving] ||
        [prefs boolForKey:kZLModBridgeDiscordRelay]) {
        return YES;
    }
    return NO;
}

- (void)clearDedupCache {
    os_unfair_lock_lock(&_lock);
    [self.seenEventKeys removeAllObjects];
    [self.seenEventOrder removeAllObjects];
    os_unfair_lock_unlock(&_lock);
}

- (BOOL)recordAndCheckDuplicateKey:(NSString *)dedupKey {
    if (dedupKey.length == 0) return NO;
    os_unfair_lock_lock(&_lock);
    if ([self.seenEventKeys containsObject:dedupKey]) {
        os_unfair_lock_unlock(&_lock);
        return YES;
    }
    [self.seenEventKeys addObject:dedupKey];
    [self.seenEventOrder addObject:dedupKey];
    while (self.seenEventOrder.count > kZLModMessageTapDedupCapacity) {
        NSString *oldest = self.seenEventOrder.firstObject;
        [self.seenEventOrder removeObjectAtIndex:0];
        if (oldest) [self.seenEventKeys removeObject:oldest];
    }
    os_unfair_lock_unlock(&_lock);
    return NO;
}

- (void)publishRawEntity:(id)chatEntity fallbackThreadId:(NSString *)fallbackThreadId kind:(ZLModMessageTapEventKind)kind {
    if (!chatEntity || ![self hasActiveTapDemand]) return;

    ZLModMessageModel *model = [ZLModChatEntityAdapter modelFromChatEntity:chatEntity fallbackThreadId:fallbackThreadId];
    if (!model) return;
    if (model.globalId <= 0 && model.clientId <= 0 && model.text.length == 0 && !model.hasPhotoAttachment) {
        return;
    }

    // Separate Observed vs Recalled dedup namespace so an observed message that is later
    // recalled always fires its Recalled event cleanly while suppressing duplicate Observed
    // callbacks across addChat:, addChats:, and didLoadChats:.
    NSString *kindTag = (kind == ZLModMessageTapEventRecalled) ? @"recall" : @"obs";
    NSString *dedupKey = [NSString stringWithFormat:@"%@|%@", kindTag, model.identityKey ?: @""];
    if ([self recordAndCheckDuplicateKey:dedupKey]) {
        return;
    }

    os_unfair_lock_lock(&_lock);
    NSArray<ZLModTapConsumerEntry *> *snapshotConsumers = [self.consumers copy];
    os_unfair_lock_unlock(&_lock);

    for (ZLModTapConsumerEntry *entry in snapshotConsumers) {
        @try {
            entry.block(model, chatEntity, kind);
        } @catch (NSException *e) {
            ZLMOD_LOG(@"messagetap: consumer %@ threw (%@)", entry.name, e.reason ?: @"unknown");
        }
    }
}

@end

#pragma mark - Host container enumeration & hooks

static void ZLModTapEnumerateEntities(id container, void (^block)(id entity)) {
    if (!container || !block) return;
    if ([container isKindOfClass:[NSArray class]] || [container isKindOfClass:[NSSet class]]) {
        for (id item in container) block(item);
        return;
    }
    if ([container isKindOfClass:[NSDictionary class]]) {
        [(NSDictionary *)container enumerateKeysAndObjectsUsingBlock:^(__unused id key, id obj, __unused BOOL *stop) {
            if ([obj isKindOfClass:[NSArray class]]) {
                for (id sub in (NSArray *)obj) block(sub);
            } else {
                block(obj);
            }
        }];
        return;
    }
    block(container);
}

void ZLModMessageTapInstall(void) {
    NSUInteger installed = 0;

    Class convModelCls = NSClassFromString(@"ConversationModel");
    if (convModelCls) {
        // 1. ConversationModel -didLoadChats:config: [v32@0:8@16@24]
        SEL didLoadSel = sel_registerName("didLoadChats:config:");
        if (ZLModClassHasInstanceMethod(convModelCls, didLoadSel)) {
            IMP orig = class_getMethodImplementation(convModelCls, didLoadSel);
            if (ZLModReplaceMethod(convModelCls, didLoadSel, 2, "v", ^(id selfObj, id chats, id config) {
                if (chats && [[ZLModMessageTapBus shared] hasActiveTapDemand]) {
                    NSString *convTid = [ZLModChatEntityAdapter extractThreadIdFromObject:selfObj];
                    ZLModTapEnumerateEntities(chats, ^(id entity) {
                        [[ZLModMessageTapBus shared] publishRawEntity:entity
                                                     fallbackThreadId:convTid
                                                                 kind:ZLModMessageTapEventObserved];
                    });
                }
                if (orig) ((void (*)(id, SEL, id, id))orig)(selfObj, didLoadSel, chats, config);
            })) {
                installed++;
            }
        }

        // 2. ConversationModel -updateDBWhenRecalledChats:completion: [v32@0:8@16@?24]
        SEL recallSel = sel_registerName("updateDBWhenRecalledChats:completion:");
        if (ZLModClassHasInstanceMethod(convModelCls, recallSel)) {
            IMP orig = class_getMethodImplementation(convModelCls, recallSel);
            if (ZLModReplaceMethod(convModelCls, recallSel, 2, "v", ^(id selfObj, id recalledChats, id completion) {
                if (recalledChats && [[ZLModMessageTapBus shared] hasActiveTapDemand]) {
                    NSString *convTid = [ZLModChatEntityAdapter extractThreadIdFromObject:selfObj];
                    ZLModTapEnumerateEntities(recalledChats, ^(id entity) {
                        [[ZLModMessageTapBus shared] publishRawEntity:entity
                                                     fallbackThreadId:convTid
                                                                 kind:ZLModMessageTapEventRecalled];
                    });
                }
                if (orig) ((void (*)(id, SEL, id, id))orig)(selfObj, recallSel, recalledChats, completion);
            })) {
                installed++;
            }
        }
    }

    Class chatMgrCls = NSClassFromString(@"ChatDataManager");
    if (chatMgrCls) {
        // 3. ChatDataManager -addChats:byUserId:willAlert:fromSrc: [v44@0:8@16@24B32q36]
        SEL addChatsSel = sel_registerName("addChats:byUserId:willAlert:fromSrc:");
        if (ZLModClassHasInstanceMethod(chatMgrCls, addChatsSel)) {
            IMP orig = class_getMethodImplementation(chatMgrCls, addChatsSel);
            if (ZLModReplaceMethod(chatMgrCls, addChatsSel, 4, "v",
                                   ^(id selfObj, id chats, id userId, BOOL willAlert, NSInteger src) {
                if (chats && [[ZLModMessageTapBus shared] hasActiveTapDemand]) {
                    NSString *uidHint = [userId isKindOfClass:[NSString class]] ? (NSString *)userId : nil;
                    ZLModTapEnumerateEntities(chats, ^(id entity) {
                        [[ZLModMessageTapBus shared] publishRawEntity:entity
                                                     fallbackThreadId:uidHint
                                                                 kind:ZLModMessageTapEventObserved];
                    });
                }
                if (orig) ((void (*)(id, SEL, id, id, BOOL, NSInteger))orig)(selfObj, addChatsSel, chats, userId, willAlert, src);
            })) {
                installed++;
            }
        }

        // 4. ChatDataManager -addChat:byUserId:willAlert:fromSrc: [v44@0:8@16@24B32q36]
        SEL addChatSel = sel_registerName("addChat:byUserId:willAlert:fromSrc:");
        if (ZLModClassHasInstanceMethod(chatMgrCls, addChatSel)) {
            IMP orig = class_getMethodImplementation(chatMgrCls, addChatSel);
            if (ZLModReplaceMethod(chatMgrCls, addChatSel, 4, "v",
                                   ^(id selfObj, id chat, id userId, BOOL willAlert, NSInteger src) {
                if (chat && [[ZLModMessageTapBus shared] hasActiveTapDemand]) {
                    NSString *uidHint = [userId isKindOfClass:[NSString class]] ? (NSString *)userId : nil;
                    ZLModTapEnumerateEntities(chat, ^(id entity) {
                        [[ZLModMessageTapBus shared] publishRawEntity:entity
                                                     fallbackThreadId:uidHint
                                                                 kind:ZLModMessageTapEventObserved];
                    });
                }
                if (orig) ((void (*)(id, SEL, id, id, BOOL, NSInteger))orig)(selfObj, addChatSel, chat, userId, willAlert, src);
            })) {
                installed++;
            }
        }
    }

    ZLModSetModuleStatus(@"MessageTap",
                         (installed >= 2) ? ZLModModuleStatusHookInstalled : ZLModModuleStatusNotInstalled,
                         [NSString stringWithFormat:@"tapHooks=%lu", (unsigned long)installed]);
    ZLMOD_LOG(@"message tap bus installed (hooks=%lu)", (unsigned long)installed);
}
