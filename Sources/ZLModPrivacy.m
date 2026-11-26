// language: Objective-C, file: ZLModPrivacy.m, target: iOS 15.1+ (Zalo 26.10.02 & 26.11.01, arm64)
// Messaging privacy & analytics control with ABI-verified hooks, single-pass selector index,
// unified ZLModChatEntityAdapter resolution, per-conversation selective enforcement,
// and reversible Firebase telemetry toggle (ON disables, OFF restores).

#import "ZLMod.h"

static BOOL gPrivacyObserversInstalled = NO;
static BOOL gFirebaseDisabledByZLMod = NO;

#pragma mark - Helper resolvers (never log raw user/thread IDs)

static NSString *ZLModExtractThreadIdFromObject(id obj) {
    if (!obj) return nil;
    if ([obj isKindOfClass:[NSString class]]) {
        NSString *s = (NSString *)obj;
        return s.length > 0 ? s : nil;
    }
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)obj;
        for (NSString *k in @[@"threadId", @"threadid", @"tuid", @"userid", @"userId", @"uid", @"groupId"]) {
            id val = dict[k];
            if ([val isKindOfClass:[NSString class]] && [(NSString *)val length] > 0) {
                return (NSString *)val;
            }
            if ([val isKindOfClass:[NSNumber class]]) {
                NSString *str = [(NSNumber *)val stringValue];
                if (str.length > 0 && ![str isEqualToString:@"0"]) return str;
            }
        }
        return nil;
    }

    NSString *adapted = [ZLModChatEntityAdapter extractThreadIdFromObject:obj];
    if (adapted.length > 0) return adapted;

    for (NSString *selName in @[@"rt_threadId", @"threadid", @"userid", @"getGroupId", @"swipeKey"]) {
        NSString *val = ZLModSafeStringProperty(obj, NSSelectorFromString(selName));
        if (val.length > 0 && ![val isEqualToString:@"0"]) return val;
    }
    return nil;
}

static NSString *ZLModExtractConvTypeFromObject(id obj, NSString *threadIdHint) {
    if (obj) {
        if ([obj isKindOfClass:[NSDictionary class]]) {
            NSDictionary *dict = (NSDictionary *)obj;
            if ([dict[@"isGroup"] respondsToSelector:@selector(boolValue)] && [dict[@"isGroup"] boolValue]) {
                return @"group";
            }
            id mType = dict[@"messageType"];
            if ([mType respondsToSelector:@selector(integerValue)] && [mType integerValue] == 2) {
                return @"group";
            }
        } else {
            NSString *adapted = [ZLModChatEntityAdapter extractConversationTypeFromObject:obj];
            if ([adapted isEqualToString:@"group"]) return @"group";
        }
    }
    NSString *activeTid = [ZLModPrivacyContext activeThreadId];
    if (activeTid.length > 0 && threadIdHint.length > 0 && [activeTid isEqualToString:threadIdHint]) {
        return [ZLModPrivacyContext activeConversationType] ?: @"single";
    }
    return nil;
}

static BOOL ZLModShouldHideSeenForContext(id obj, NSString *preferredConvType, BOOL includeReadReceiptsGlobal) {
    ZLModPreferences *prefs = [ZLModPreferences shared];
    if ([prefs boolForKey:kZLModHideSeen]) return YES;
    if (includeReadReceiptsGlobal && [prefs boolForKey:kZLModHideReadReceipts]) return YES;

    NSString *tid = ZLModExtractThreadIdFromObject(obj);
    if (tid.length == 0) tid = [ZLModPrivacyContext activeThreadId];
    if (tid.length == 0) return NO;

    NSString *ctype = preferredConvType ?: ZLModExtractConvTypeFromObject(obj, tid);
    return [[ZLModConversationPolicyStore shared] isHideSeenForThreadId:tid conversationType:ctype];
}

static BOOL ZLModShouldHideTypingForThread(NSString *threadId, NSString *convType) {
    if ([[ZLModPreferences shared] boolForKey:kZLModHideTyping]) return YES;
    NSString *effectiveTid = threadId.length > 0 ? threadId : [ZLModPrivacyContext activeThreadId];
    if (effectiveTid.length == 0) return NO;

    NSString *effectiveType = convType;
    NSString *activeTid = [ZLModPrivacyContext activeThreadId];
    if (activeTid.length > 0 && [activeTid isEqualToString:effectiveTid]) {
        effectiveType = [ZLModPrivacyContext activeConversationType] ?: effectiveType;
    }
    return [[ZLModConversationPolicyStore shared] isHideTypingForThreadId:effectiveTid conversationType:effectiveType];
}

#pragma mark - Context + Seen hooks

static NSUInteger ZLModInstallChatContextHooks(void) {
    Class chatVCClass = NSClassFromString(@"BaseChatTVC");
    if (!chatVCClass) return 0;

    NSUInteger installed = 0;

    SEL didAppearSel = sel_registerName("zaloViewDidAppear:");
    if (ZLModClassHasInstanceMethod(chatVCClass, didAppearSel)) {
        IMP orig = class_getMethodImplementation(chatVCClass, didAppearSel);
        if (ZLModReplaceMethod(chatVCClass, didAppearSel, 1, "v", ^(id selfObj, BOOL animated) {
            NSString *tid = ZLModExtractThreadIdFromObject(selfObj);
            NSString *ctype = ZLModSafeBoolProperty(selfObj, sel_registerName("isChatGroup"), NO) ? @"group" : @"single";
            if (tid.length > 0) {
                [ZLModPrivacyContext noteChatControllerDidAppear:selfObj threadId:tid conversationType:ctype];
            }
            if (orig) ((void (*)(id, SEL, BOOL))orig)(selfObj, didAppearSel, animated);
        })) {
            installed++;
        }
    }

    SEL willDisappearSel = sel_registerName("zaloViewWillDisappear:");
    if (ZLModClassHasInstanceMethod(chatVCClass, willDisappearSel)) {
        IMP orig = class_getMethodImplementation(chatVCClass, willDisappearSel);
        if (ZLModReplaceMethod(chatVCClass, willDisappearSel, 1, "v", ^(id selfObj, BOOL animated) {
            if (orig) ((void (*)(id, SEL, BOOL))orig)(selfObj, willDisappearSel, animated);
            [ZLModPrivacyContext noteChatControllerWillDisappear:selfObj];
        })) {
            installed++;
        }
    }

    return installed;
}

static NSUInteger ZLModInstallSeenHooks(void) {
    NSUInteger installed = 0;

    // 1. Outgoing seen per chat entity / talk item / batch (single-pass prewarmed index)
    SEL seenEntitySel = sel_registerName("sendSeenMessageWithChatEntity:");
    for (Class cls in ZLModClassesImplementingInstanceSelector(seenEntitySel)) {
        IMP orig = class_getMethodImplementation(cls, seenEntitySel);
        if (ZLModReplaceMethod(cls, seenEntitySel, 1, "v", ^(id selfObj, id chatEntity) {
            if (ZLModShouldHideSeenForContext(chatEntity ?: selfObj, nil, NO)) return;
            if (orig) ((void (*)(id, SEL, id))orig)(selfObj, seenEntitySel, chatEntity);
        })) {
            installed++;
        }
    }

    SEL seenTalkSel = sel_registerName("sendSeenMessageWithTalkTableItem:");
    for (Class cls in ZLModClassesImplementingInstanceSelector(seenTalkSel)) {
        IMP orig = class_getMethodImplementation(cls, seenTalkSel);
        if (ZLModReplaceMethod(cls, seenTalkSel, 1, "v", ^(id selfObj, id talkItem) {
            if (ZLModShouldHideSeenForContext(talkItem ?: selfObj, nil, NO)) return;
            if (orig) ((void (*)(id, SEL, id))orig)(selfObj, seenTalkSel, talkItem);
        })) {
            installed++;
        }
    }

    SEL seenBatchSel = sel_registerName("sendSeenMessages:messageDict:incomingData:");
    for (Class cls in ZLModClassesImplementingInstanceSelector(seenBatchSel)) {
        IMP orig = class_getMethodImplementation(cls, seenBatchSel);
        if (ZLModReplaceMethod(cls, seenBatchSel, 3, "v", ^(id selfObj, id msgs, id msgDict, id incomingData) {
            id hintObj = incomingData ?: ([msgs isKindOfClass:[NSArray class]] ? [(NSArray *)msgs firstObject] : msgs);
            if (ZLModShouldHideSeenForContext(hintObj ?: selfObj, nil, NO)) return;
            if (orig) ((void (*)(id, SEL, id, id, id))orig)(selfObj, seenBatchSel, msgs, msgDict, incomingData);
        })) {
            installed++;
        }
    }

    // 2. ChatSendSeenDataManager (only void action methods; never hook queue property getters)
    Class seenMgrCls = NSClassFromString(@"ChatSendSeenDataManager");
    if (seenMgrCls) {
        SEL sendDataSel = sel_registerName("_sendSeenMessageWithSeenData:messageType:");
        if (ZLModClassHasInstanceMethod(seenMgrCls, sendDataSel)) {
            IMP orig = class_getMethodImplementation(seenMgrCls, sendDataSel);
            if (ZLModReplaceMethod(seenMgrCls, sendDataSel, 2, "v", ^(id selfObj, id seenData, NSUInteger msgType) {
                NSString *ctype = (msgType == 2) ? @"group" : @"single";
                if (ZLModShouldHideSeenForContext(seenData, ctype, YES)) return;
                if (orig) ((void (*)(id, SEL, id, NSUInteger))orig)(selfObj, sendDataSel, seenData, msgType);
            })) {
                installed++;
            }
        }

        SEL sendServerSel = sel_registerName("sendSeenServer");
        if (ZLModClassHasInstanceMethod(seenMgrCls, sendServerSel)) {
            IMP orig = class_getMethodImplementation(seenMgrCls, sendServerSel);
            if (ZLModReplaceMethod(seenMgrCls, sendServerSel, 0, "v", ^(id selfObj) {
                if (ZLModShouldHideSeenForContext(nil, nil, YES)) return;
                if (orig) ((void (*)(id, SEL))orig)(selfObj, sendServerSel);
            })) {
                installed++;
            }
        }

        SEL forceServerSel = sel_registerName("forceSendSeenServer");
        if (ZLModClassHasInstanceMethod(seenMgrCls, forceServerSel)) {
            IMP orig = class_getMethodImplementation(seenMgrCls, forceServerSel);
            if (ZLModReplaceMethod(seenMgrCls, forceServerSel, 0, "v", ^(id selfObj) {
                if (ZLModShouldHideSeenForContext(nil, nil, YES)) return;
                if (orig) ((void (*)(id, SEL))orig)(selfObj, forceServerSel);
            })) {
                installed++;
            }
        }

        SEL lastThreadIdsSel = sel_registerName("sendSeenLastMessageWithThreadIds:withMessageType:");
        if (ZLModClassHasInstanceMethod(seenMgrCls, lastThreadIdsSel)) {
            IMP orig = class_getMethodImplementation(seenMgrCls, lastThreadIdsSel);
            if (ZLModReplaceMethod(seenMgrCls, lastThreadIdsSel, 2, "v", ^(id selfObj, id threadIds, NSUInteger msgType) {
                ZLModPreferences *prefs = [ZLModPreferences shared];
                if ([prefs boolForKey:kZLModHideReadReceipts] || [prefs boolForKey:kZLModHideSeen]) {
                    return;
                }
                NSString *ctype = (msgType == 2) ? @"group" : @"single";
                if ([threadIds isKindOfClass:[NSArray class]]) {
                    NSMutableArray *allowed = [NSMutableArray array];
                    for (id entry in (NSArray *)threadIds) {
                        NSString *tid = ZLModExtractThreadIdFromObject(entry);
                        if (tid.length > 0 &&
                            [[ZLModConversationPolicyStore shared] isHideSeenForThreadId:tid conversationType:ctype]) {
                            continue;
                        }
                        [allowed addObject:entry];
                    }
                    if (allowed.count == 0) return;
                    if (orig) ((void (*)(id, SEL, id, NSUInteger))orig)(selfObj, lastThreadIdsSel, [allowed copy], msgType);
                    return;
                }
                if (ZLModShouldHideSeenForContext(threadIds, ctype, YES)) return;
                if (orig) ((void (*)(id, SEL, id, NSUInteger))orig)(selfObj, lastThreadIdsSel, threadIds, msgType);
            })) {
                installed++;
            }
        }
    }

    // 3. ChatSocketCmdHelper class (+) seen ACKs
    Class sockCls = NSClassFromString(@"ChatSocketCmdHelper");
    if (sockCls) {
        SEL singleAckSel = sel_registerName("sendSeenChatACK:withSubCommandType:");
        if (ZLModClassHasClassMethod(sockCls, singleAckSel)) {
            IMP orig = class_getMethodImplementation(object_getClass(sockCls), singleAckSel);
            if (ZLModReplaceClassMethod(sockCls, singleAckSel, 2, "v", ^(id clsSelf, id data, NSUInteger subCmd) {
                if (ZLModShouldHideSeenForContext(data, @"single", YES)) return;
                if (orig) ((void (*)(id, SEL, id, NSUInteger))orig)(clsSelf, singleAckSel, data, subCmd);
            })) {
                installed++;
            }
        }

        SEL groupAckSel = sel_registerName("sendSeenGroupChatACKByData:withSubCommandType:");
        if (ZLModClassHasClassMethod(sockCls, groupAckSel)) {
            IMP orig = class_getMethodImplementation(object_getClass(sockCls), groupAckSel);
            if (ZLModReplaceClassMethod(sockCls, groupAckSel, 2, "v", ^(id clsSelf, id data, NSUInteger subCmd) {
                if (ZLModShouldHideSeenForContext(data, @"group", YES)) return;
                if (orig) ((void (*)(id, SEL, id, NSUInteger))orig)(clsSelf, groupAckSel, data, subCmd);
            })) {
                installed++;
            }
        }
    }

    // 4. Friend request read receipts (sourceView is 32-bit int `i`)
    Class frCls = NSClassFromString(@"FriendRequestManager");
    if (frCls) {
        SEL frSel2 = sel_registerName("sendSeenCurrentUnreadFriendRequest:sourceView:");
        if (ZLModClassHasInstanceMethod(frCls, frSel2)) {
            IMP orig = class_getMethodImplementation(frCls, frSel2);
            if (ZLModReplaceMethod(frCls, frSel2, 2, "v", ^(id selfObj, id reqs, int sourceView) {
                if ([[ZLModPreferences shared] boolForKey:kZLModHideReadReceipts]) return;
                if (orig) ((void (*)(id, SEL, id, int))orig)(selfObj, frSel2, reqs, sourceView);
            })) {
                installed++;
            }
        }

        SEL frSel3 = sel_registerName("sendSeenCurrentUnreadFriendRequest:retryTime:sourceView:");
        if (ZLModClassHasInstanceMethod(frCls, frSel3)) {
            IMP orig = class_getMethodImplementation(frCls, frSel3);
            if (ZLModReplaceMethod(frCls, frSel3, 3, "v", ^(id selfObj, id reqs, id retryTime, int sourceView) {
                if ([[ZLModPreferences shared] boolForKey:kZLModHideReadReceipts]) return;
                if (orig) ((void (*)(id, SEL, id, id, int))orig)(selfObj, frSel3, reqs, retryTime, sourceView);
            })) {
                installed++;
            }
        }
    }

    return installed;
}

#pragma mark - Typing hooks (verified signatures)

static NSUInteger ZLModInstallTypingHooks(void) {
    NSUInteger installed = 0;

    // 1. High-level ChatDataManager -sendTypingWithType:toUserId:messageType:isE2eeChat: -> [B44@0:8Q16@24Q32B40]
    Class chatDataCls = NSClassFromString(@"ChatDataManager");
    if (chatDataCls) {
        SEL sendTypingSel = sel_registerName("sendTypingWithType:toUserId:messageType:isE2eeChat:");
        if (ZLModClassHasInstanceMethod(chatDataCls, sendTypingSel)) {
            IMP orig = class_getMethodImplementation(chatDataCls, sendTypingSel);
            if (ZLModReplaceMethod(chatDataCls, sendTypingSel, 4, "Bc",
                                   ^BOOL(id selfObj, NSUInteger typingType, id toUserId, NSUInteger msgType, BOOL isE2ee) {
                NSString *tid = [toUserId isKindOfClass:[NSString class]] ? (NSString *)toUserId : nil;
                NSString *ctype = (msgType == 2) ? @"group" : @"single";
                if (ZLModShouldHideTypingForThread(tid, ctype)) {
                    return NO;
                }
                return orig ? ((BOOL (*)(id, SEL, NSUInteger, id, NSUInteger, BOOL))orig)(selfObj, sendTypingSel, typingType, toUserId, msgType, isE2ee) : NO;
            })) {
                installed++;
            }
        }
    }

    // 2. Socket layer class (+) method: ChatSocketCmdHelper +sendStatusTyping:... -> [Q56@0:8Q16q24Q32q40q48]
    Class sockCls = NSClassFromString(@"ChatSocketCmdHelper");
    if (sockCls) {
        SEL socketTypingSel = sel_registerName("sendStatusTyping:withCommand:withSubCommand:withDestType:withGlobalMessageId:");
        if (ZLModClassHasClassMethod(sockCls, socketTypingSel)) {
            IMP orig = class_getMethodImplementation(object_getClass(sockCls), socketTypingSel);
            if (ZLModReplaceClassMethod(sockCls, socketTypingSel, 5, "Q",
                                        ^NSUInteger(id clsSelf, NSUInteger typingType, NSInteger cmd, NSUInteger subCmd, NSInteger destType, int64_t globalMsgId) {
                NSString *destConvType = (destType == 1 || destType == 2) ? @"group" : [ZLModPrivacyContext activeConversationType];
                NSString *activeTid = [ZLModPrivacyContext activeThreadId];
                if (ZLModShouldHideTypingForThread(activeTid, destConvType)) {
                    return 0;
                }
                return orig ? ((NSUInteger (*)(id, SEL, NSUInteger, NSInteger, NSUInteger, NSInteger, int64_t))orig)(clsSelf, socketTypingSel, typingType, cmd, subCmd, destType, globalMsgId) : 0;
            })) {
                installed++;
            }
        }
    }

    return installed;
}

#pragma mark - Reversible Firebase / analytics toggle

static void ZLModApplyFirebaseState(void) {
    BOOL blocked = [[ZLModPreferences shared] boolForKey:kZLModBlockFirebase];
    if (!blocked && !gFirebaseDisabledByZLMod) {
        // Default OFF at boot: never touch host Firebase collection state unless user toggled it.
        return;
    }

    BOOL enabled = !blocked;
    @try {
        Class firAnalytics = NSClassFromString(@"FIRAnalytics");
        SEL analyticsSel = sel_registerName("setAnalyticsCollectionEnabled:");
        if (firAnalytics && [firAnalytics respondsToSelector:analyticsSel]) {
            IMP imp = class_getMethodImplementation(object_getClass(firAnalytics), analyticsSel);
            if (imp) ((void (*)(id, SEL, BOOL))imp)(firAnalytics, analyticsSel, enabled);
        }

        Class firPerformance = NSClassFromString(@"FIRPerformance");
        SEL perfClassSel = sel_registerName("setDataCollectionEnabled:");
        if (firPerformance && [firPerformance respondsToSelector:perfClassSel]) {
            IMP imp = class_getMethodImplementation(object_getClass(firPerformance), perfClassSel);
            if (imp) ((void (*)(id, SEL, BOOL))imp)(firPerformance, perfClassSel, enabled);
        } else if (firPerformance && [firPerformance respondsToSelector:sel_registerName("sharedInstance")]) {
            IMP sharedImp = class_getMethodImplementation(object_getClass(firPerformance), sel_registerName("sharedInstance"));
            id perfInst = sharedImp ? ((id (*)(id, SEL))sharedImp)(firPerformance, sel_registerName("sharedInstance")) : nil;
            if (perfInst && [perfInst respondsToSelector:perfClassSel]) {
                IMP imp = class_getMethodImplementation(object_getClass(perfInst), perfClassSel);
                if (imp) ((void (*)(id, SEL, BOOL))imp)(perfInst, perfClassSel, enabled);
            }
        }

        Class crashlytics = NSClassFromString(@"FIRCrashlytics");
        SEL sharedSel = sel_registerName("crashlytics");
        if (crashlytics && [crashlytics respondsToSelector:sharedSel]) {
            IMP sharedImp = class_getMethodImplementation(object_getClass(crashlytics), sharedSel);
            id instance = sharedImp ? ((id (*)(id, SEL))sharedImp)(crashlytics, sharedSel) : nil;
            SEL collectionSel = sel_registerName("setCrashlyticsCollectionEnabled:");
            if (instance && [instance respondsToSelector:collectionSel]) {
                IMP imp = class_getMethodImplementation(object_getClass(instance), collectionSel);
                if (imp) ((void (*)(id, SEL, BOOL))imp)(instance, collectionSel, enabled);
            }
        }
    } @catch (NSException *e) {
        ZLMOD_LOG(@"Firebase toggle failed: %@", e.reason ?: @"unknown");
    }

    gFirebaseDisabledByZLMod = blocked;
    ZLMOD_LOG(@"Firebase collection %@", blocked ? @"disabled" : @"restored (enabled)");
}

#pragma mark - Install

void ZLModPrivacyInstall(void) {
    NSUInteger ctxCount = ZLModInstallChatContextHooks();
    NSUInteger seenCount = ZLModInstallSeenHooks();
    NSUInteger typingCount = ZLModInstallTypingHooks();

    ZLModApplyFirebaseState();
    if (!gPrivacyObserversInstalled) {
        gPrivacyObserversInstalled = YES;
        [[NSNotificationCenter defaultCenter] addObserverForName:ZLModPrefsDidChangeNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
            NSString *key = [note.object isKindOfClass:[NSString class]] ? (NSString *)note.object : @"";
            if ([key isEqualToString:kZLModBlockFirebase] || [key isEqualToString:@"*"]) {
                ZLModApplyFirebaseState();
            }
        }];
    }

    ZLModSetModuleStatus(@"SeenPrivacy",
                         seenCount > 0 ? ZLModModuleStatusHookInstalled : ZLModModuleStatusNotInstalled,
                         [NSString stringWithFormat:@"seenHooks=%lu ctxHooks=%lu",
                          (unsigned long)seenCount, (unsigned long)ctxCount]);
    ZLModSetModuleStatus(@"TypingPrivacy",
                         typingCount > 0 ? ZLModModuleStatusHookInstalled : ZLModModuleStatusNotInstalled,
                         [NSString stringWithFormat:@"typingHooks=%lu", (unsigned long)typingCount]);
    ZLModSetModuleStatus(@"Privacy",
                         (seenCount > 0 && typingCount > 0) ? ZLModModuleStatusHookInstalled : ZLModModuleStatusNotInstalled,
                         [NSString stringWithFormat:@"seen=%lu typing=%lu ctx=%lu",
                          (unsigned long)seenCount, (unsigned long)typingCount, (unsigned long)ctxCount]);

    ZLMOD_LOG(@"privacy installed (ctx=%lu seen=%lu typing=%lu)",
              (unsigned long)ctxCount, (unsigned long)seenCount, (unsigned long)typingCount);
}
