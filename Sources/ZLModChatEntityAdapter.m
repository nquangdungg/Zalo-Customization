// language: Objective-C, file: ZLModChatEntityAdapter.m, target: iOS 15.1+ (Zalo 26.10.02 & 26.11.01, arm64)
// Unified adapter normalizing Zalo host ChatEntity & inbox objects into immutable
// ZLModMessageModel instances shared by MessageTapBus, AntiRecall, Privacy, and CSaving.

#import "ZLMod.h"
#import <math.h>

@interface ZLModMessageModel ()
@property (nonatomic, assign) int64_t globalId;
@property (nonatomic, assign) int64_t clientId;
@property (nonatomic, copy) NSString *msgIdString;
@property (nonatomic, copy) NSString *cliMsgIdString;
@property (nonatomic, copy) NSString *threadId;
@property (nonatomic, assign) NSInteger threadType;
@property (nonatomic, copy) NSString *senderId;
@property (nonatomic, copy) NSString *senderName;
@property (nonatomic, copy) NSString *text;
@property (nonatomic, copy) NSString *originRecallText;
@property (nonatomic, copy) NSString *msgType;
@property (nonatomic, assign) NSTimeInterval timestampSec;
@property (nonatomic, assign) int64_t timestampMs;
@property (nonatomic, assign) BOOL isSelf;
@property (nonatomic, assign) BOOL isGroup;
@property (nonatomic, assign) BOOL isRecalled;
@property (nonatomic, assign) BOOL hasPhotoAttachment;
@property (nonatomic, copy) NSString *accountScope;
@property (nonatomic, copy) NSString *identityKey;
@end

@implementation ZLModMessageModel

- (id)copyWithZone:(__unused NSZone *)zone {
    // Immutable value object: returning self is safe and O(1).
    return self;
}

@end

@implementation ZLModChatEntityAdapter

+ (BOOL)isPlaceholderRecalledText:(NSString *)text {
    if (![text isKindOfClass:[NSString class]]) return NO;
    NSString *trimmed = [[text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if (trimmed.length == 0) return NO;

    // Exact placeholder sentences only — never match arbitrary user text containing
    // the words "thu hồi" or "recalled" (e.g. "đừng thu hồi tin nhắn nhé").
    static NSSet<NSString *> *exactPlaceholders = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        exactPlaceholders = [NSSet setWithArray:@[
            @"tin nhắn đã được thu hồi",
            @"tin nhắn đã bị thu hồi",
            @"tin nhắn đã thu hồi",
            @"message has been recalled",
            @"this message was recalled",
            @"message recalled",
            @"[tin nhắn đã thu hồi]",
            @"[hình ảnh đã thu hồi]"
        ]];
    });
    return [exactPlaceholders containsObject:trimmed];
}

+ (NSString *)firstNonEmptyStringFrom:(id)obj selectors:(NSArray<NSString *> *)selectors {
    if (!obj) return nil;
    for (NSString *selName in selectors) {
        NSString *val = ZLModSafeStringProperty(obj, sel_registerName(selName.UTF8String));
        if (val.length > 0 && ![val isEqualToString:@"0"] && ![val isEqualToString:@"(null)"]) {
            return val;
        }
    }
    return nil;
}

+ (int64_t)firstPositiveInt64From:(id)obj selectors:(NSArray<NSString *> *)selectors {
    if (!obj) return 0;
    for (NSString *selName in selectors) {
        int64_t v = ZLModSafeInt64Property(obj, sel_registerName(selName.UTF8String), 0);
        if (v > 0) return v;
    }
    return 0;
}

+ (NSString *)extractThreadIdFromObject:(id)obj {
    if (!obj) return nil;
    NSArray<NSString *> *directSels = @[
        @"threadId", @"tuid", @"conversationId", @"chatId",
        @"groupId", @"uid", @"userId", @"ownerId"
    ];
    NSString *tid = [self firstNonEmptyStringFrom:obj selectors:directSels];
    if (tid.length > 0) return tid;

    // Nested conversation/chat object fallback
    NSArray<NSString *> *nestedSels = @[@"conversation", @"conversationModel", @"chatItem", @"listItem", @"data", @"item"];
    for (NSString *nestedName in nestedSels) {
        id nested = ZLModSafeObjectProperty(obj, sel_registerName(nestedName.UTF8String));
        if (nested && nested != obj) {
            tid = [self firstNonEmptyStringFrom:nested selectors:directSels];
            if (tid.length > 0) return tid;
        }
    }
    return nil;
}

+ (NSString *)extractConversationTypeFromObject:(id)obj {
    if (!obj) return @"user";
    BOOL isGroup = ZLModSafeBoolProperty(obj, sel_registerName("isChatGroup"), NO) ||
                   ZLModSafeBoolProperty(obj, sel_registerName("isGroup"), NO) ||
                   ZLModSafeBoolProperty(obj, sel_registerName("isGroupChat"), NO);
    if (isGroup) return @"group";
    int64_t ttype = ZLModSafeInt64Property(obj, sel_registerName("threadType"), -1);
    if (ttype == 1) return @"group";
    return @"user";
}

+ (NSString *)extractDisplayTitleFromObject:(id)obj {
    if (!obj) return nil;
    NSArray<NSString *> *titleSels = @[
        @"displayName", @"displayname", @"title", @"name",
        @"conversationName", @"groupName", @"senderName", @"userName"
    ];
    NSString *title = [self firstNonEmptyStringFrom:obj selectors:titleSels];
    if (title.length > 0) return title;

    NSArray<NSString *> *nestedSels = @[@"conversation", @"conversationModel", @"chatItem", @"item", @"user"];
    for (NSString *nestedName in nestedSels) {
        id nested = ZLModSafeObjectProperty(obj, sel_registerName(nestedName.UTF8String));
        if (nested && nested != obj) {
            title = [self firstNonEmptyStringFrom:nested selectors:titleSels];
            if (title.length > 0) return title;
        }
    }
    return nil;
}

+ (UIImage *)extractPhotoImageFromChatEntity:(id)chatEntity {
    if (!chatEntity) return nil;

    NSArray<NSString *> *imageSels = @[
        @"originalImage", @"fullImage", @"photoImage", @"photo", @"thumbImage", @"image", @"previewImage"
    ];
    for (NSString *selName in imageSels) {
        id candidate = ZLModSafeObjectProperty(chatEntity, sel_registerName(selName.UTF8String));
        if ([candidate isKindOfClass:[UIImage class]]) {
            return (UIImage *)candidate;
        }
    }

    NSArray<NSString *> *pathSels = @[
        @"hdLocalFilePath", @"chatlocalpath", @"localFilePath", @"photoPath", @"imagePath",
        @"backupFilePathAbs", @"dataFilePath", @"filePathStr", @"thumbLocalFilePath", @"filePath", @"originalPath"
    ];
    for (NSString *selName in pathSels) {
        NSString *path = ZLModSafeStringProperty(chatEntity, sel_registerName(selName.UTF8String));
        if (path.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:path]) {
            UIImage *img = [UIImage imageWithContentsOfFile:path];
            if (img) return img;
        }
    }
    return nil;
}

+ (BOOL)entityHasPhotoHint:(id)chatEntity text:(NSString *)text {
    if (!chatEntity) return NO;
    NSArray<NSString *> *pathSels = @[
        @"hdLocalFilePath", @"chatlocalpath", @"localFilePath", @"photoPath",
        @"imagePath", @"backupFilePathAbs", @"dataFilePath", @"filePathStr", @"thumbLocalFilePath"
    ];
    for (NSString *selName in pathSels) {
        NSString *path = ZLModSafeStringProperty(chatEntity, sel_registerName(selName.UTF8String));
        if (path.length > 0) return YES;
    }
    NSArray<NSString *> *imgSels = @[@"originalImage", @"photoImage", @"photo", @"thumbImage", @"image"];
    for (NSString *selName in imgSels) {
        id candidate = ZLModSafeObjectProperty(chatEntity, sel_registerName(selName.UTF8String));
        if ([candidate isKindOfClass:[UIImage class]]) return YES;
    }
    if (text.length > 0 &&
        ([text localizedCaseInsensitiveContainsString:@"[Hình ảnh]"] ||
         [text localizedCaseInsensitiveContainsString:@"[Photo]"])) {
        return YES;
    }
    return NO;
}

+ (BOOL)detectIsRecalled:(id)chatEntity text:(NSString *)text originRecallText:(NSString *)originText {
    if (!chatEntity) return NO;

    // 1. Prefer verified structured host fields over text heuristics.
    if (ZLModSafeBoolProperty(chatEntity, sel_registerName("isRecalled"), NO)) return YES;
    if (ZLModSafeBoolProperty(chatEntity, sel_registerName("isRecallMsg"), NO)) return YES;
    if (ZLModSafeBoolProperty(chatEntity, sel_registerName("isRecalledOrFailOrRolledAll"), NO)) return YES;
    if (ZLModSafeBoolProperty(chatEntity, sel_registerName("isRecallDelByMySelf"), NO)) return YES;
    if (ZLModSafeBoolProperty(chatEntity, sel_registerName("isUndo"), NO)) return YES;

    int64_t numericMsgType = ZLModSafeInt64Property(chatEntity, sel_registerName("messageType"), 0);
    if (numericMsgType == 51) return YES;

    NSString *rawType = [self firstNonEmptyStringFrom:chatEntity selectors:@[@"msgType", @"messageTypeString"]];
    if (rawType.length > 0) {
        NSString *lower = rawType.lowercaseString;
        if ([lower isEqualToString:@"chat.undo"] ||
            [lower isEqualToString:@"undo"] ||
            [lower isEqualToString:@"recall"] ||
            [lower isEqualToString:@"chat.recall"]) {
            return YES;
        }
    }

    // 2. If host populated originTextRecallMsg / _originTextRecallMsg, treat as recalled.
    if (originText.length > 0 && ![self isPlaceholderRecalledText:originText]) {
        return YES;
    }

    // 3. Last resort: exact placeholder sentence match (never loose substring matching).
    return [self isPlaceholderRecalledText:text];
}

+ (NSString *)normalizeMessageTypeForEntity:(id)chatEntity
                                       text:(NSString *)text
                                 isRecalled:(BOOL)isRecalled
                                   hasPhoto:(BOOL)hasPhoto {
    if (isRecalled) return @"chat.undo";

    NSString *rawType = [self firstNonEmptyStringFrom:chatEntity selectors:@[@"msgType", @"messageTypeString"]];
    if (rawType.length > 0) {
        NSString *lower = rawType.lowercaseString;
        if ([lower containsString:@"photo"] || [lower containsString:@"image"]) return @"chat.photo";
        if ([lower containsString:@"sticker"]) return @"chat.sticker";
        if ([lower containsString:@"voice"] || [lower containsString:@"audio"]) return @"chat.voice";
        if ([lower containsString:@"file"] || [lower containsString:@"doc"]) return @"chat.file";
        if ([lower containsString:@"video"]) return @"chat.video";
        if ([lower containsString:@"undo"] || [lower containsString:@"recall"]) return @"chat.undo";
    }

    if (hasPhoto) return @"chat.photo";
    if (text.length > 0) {
        if ([text localizedCaseInsensitiveContainsString:@"[Hình ảnh]"] ||
            [text localizedCaseInsensitiveContainsString:@"[Photo]"]) {
            return @"chat.photo";
        }
        if ([text localizedCaseInsensitiveContainsString:@"[Nhãn dán]"] ||
            [text localizedCaseInsensitiveContainsString:@"[Sticker]"]) {
            return @"chat.sticker";
        }
        if ([text localizedCaseInsensitiveContainsString:@"[Tin nhắn thoại]"] ||
            [text localizedCaseInsensitiveContainsString:@"[Voice]"]) {
            return @"chat.voice";
        }
        if ([text localizedCaseInsensitiveContainsString:@"[Tệp tin]"] ||
            [text localizedCaseInsensitiveContainsString:@"[File]"]) {
            return @"chat.file";
        }
        if ([text localizedCaseInsensitiveContainsString:@"[Video]"]) {
            return @"chat.video";
        }
    }
    return @"chat.text";
}

+ (ZLModMessageModel *)modelFromChatEntity:(id)chatEntity fallbackThreadId:(NSString *)fallbackThreadId {
    if (!chatEntity) return nil;

    int64_t gid = [self firstPositiveInt64From:chatEntity selectors:@[@"globalId", @"globalMsgId", @"msgId"]];
    int64_t cid = [self firstPositiveInt64From:chatEntity selectors:@[@"clientId", @"cliMsgId", @"localMsgId"]];

    NSString *tid = [self extractThreadIdFromObject:chatEntity];
    if (tid.length == 0 && fallbackThreadId.length > 0) {
        tid = fallbackThreadId;
    }

    NSString *senderId = [self firstNonEmptyStringFrom:chatEntity selectors:@[@"senderId", @"fuid", @"fromUid", @"authorId"]] ?: @"";
    NSString *senderName = [self firstNonEmptyStringFrom:chatEntity selectors:@[@"senderName", @"displayname", @"displayName", @"senderDisplayName", @"fromName"]] ?: @"";
    NSString *text = [self firstNonEmptyStringFrom:chatEntity selectors:@[@"message", @"text", @"content", @"msgContent"]] ?: @"";
    NSString *originText = [self firstNonEmptyStringFrom:chatEntity selectors:@[@"originTextRecallMsg", @"_originTextRecallMsg", @"originText"]] ?: @"";

    BOOL isGroup = [[self extractConversationTypeFromObject:chatEntity] isEqualToString:@"group"];
    NSInteger threadType = isGroup ? 1 : 0;

    BOOL isSelf = ZLModSafeBoolProperty(chatEntity, sel_registerName("isOwner"), NO) ||
                  ZLModSafeBoolProperty(chatEntity, sel_registerName("isSelf"), NO) ||
                  ZLModSafeBoolProperty(chatEntity, sel_registerName("isSender"), NO);
    if (!isSelf && senderId.length > 0) {
        NSString *currentRawUid = ZLModCurrentRawUserId();
        if (currentRawUid.length > 0 && [senderId isEqualToString:currentRawUid]) {
            isSelf = YES;
        }
    }

    // Automatic timestamp unit normalization (handles seconds and milliseconds uniformly).
    double rawTs = ZLModSafeDoubleProperty(chatEntity, sel_registerName("createTime"), 0.0);
    if (rawTs <= 0.0) {
        rawTs = ZLModSafeDoubleProperty(chatEntity, sel_registerName("time"), 0.0);
    }
    if (rawTs <= 0.0) {
        rawTs = ZLModSafeDoubleProperty(chatEntity, sel_registerName("timestamp"), 0.0);
    }

    NSTimeInterval tsSec = 0.0;
    int64_t tsMs = 0;
    if (rawTs > 100000000000.0) {
        tsMs = (int64_t)llround(rawTs);
        tsSec = rawTs / 1000.0;
    } else if (rawTs > 0.0) {
        tsSec = rawTs;
        tsMs = (int64_t)llround(rawTs * 1000.0);
    } else {
        tsSec = [[NSDate date] timeIntervalSince1970];
        tsMs = (int64_t)llround(tsSec * 1000.0);
    }

    BOOL isRecalled = [self detectIsRecalled:chatEntity text:text originRecallText:originText];
    BOOL hasPhoto = [self entityHasPhotoHint:chatEntity text:text];
    NSString *msgType = [self normalizeMessageTypeForEntity:chatEntity
                                                       text:text
                                                 isRecalled:isRecalled
                                                   hasPhoto:hasPhoto];

    NSString *msgIdStr = (gid > 0) ? [NSString stringWithFormat:@"%lld", (long long)gid] : @"";
    NSString *cliMsgIdStr = (cid > 0) ? [NSString stringWithFormat:@"%lld", (long long)cid] : @"";
    NSString *scope = ZLModCurrentAccountScope() ?: @"";

    NSString *idPart = (gid > 0)
        ? [NSString stringWithFormat:@"g_%lld", (long long)gid]
        : ((cid > 0) ? [NSString stringWithFormat:@"c_%lld", (long long)cid]
                     : [NSString stringWithFormat:@"t_%lld_%@", (long long)tsMs, ZLModSafeIdHash(text)]);
    NSString *identityKey = [NSString stringWithFormat:@"%@:%ld:%@:%@",
                             scope.length > 0 ? scope : @"0",
                             (long)threadType,
                             tid.length > 0 ? tid : @"0",
                             idPart];

    ZLModMessageModel *model = [[ZLModMessageModel alloc] init];
    model.globalId = gid;
    model.clientId = cid;
    model.msgIdString = msgIdStr;
    model.cliMsgIdString = cliMsgIdStr;
    model.threadId = tid ?: @"";
    model.threadType = threadType;
    model.senderId = senderId;
    model.senderName = senderName;
    model.text = text;
    model.originRecallText = originText;
    model.msgType = msgType;
    model.timestampSec = tsSec;
    model.timestampMs = tsMs;
    model.isSelf = isSelf;
    model.isGroup = isGroup;
    model.isRecalled = isRecalled;
    model.hasPhotoAttachment = hasPhoto;
    model.accountScope = scope;
    model.identityKey = identityKey;
    return model;
}

+ (NSDictionary<NSString *, id> *)csavingDictionaryFromModel:(ZLModMessageModel *)model {
    if (!model) return @{};
    return @{
        @"identityKey": model.identityKey ?: @"",
        @"threadId": model.threadId ?: @"",
        @"threadType": @(model.threadType),
        @"msgId": model.msgIdString ?: @"",
        @"cliMsgId": model.cliMsgIdString ?: @"",
        @"senderUid": model.senderId ?: @"",
        @"senderName": model.senderName ?: @"",
        @"text": model.text ?: @"",
        @"msgType": model.msgType ?: @"chat.text",
        @"timestampMs": @(model.timestampMs),
        @"isSelf": @(model.isSelf),
        @"isRecalled": @(model.isRecalled)
    };
}

@end
