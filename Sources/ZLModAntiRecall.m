// language: Objective-C, file: ZLModAntiRecall.m, target: iOS 15.1+ (Zalo 26.10.02 & 26.11.01, arm64)
// Local-only Anti-Recall Ghost Preview (MODULE 07):
//   - Consumes normalized events from decoupled ZLModMessageTapBus (CSaving no longer depends on Anti-Recall).
//   - Leak-free live snapshot LRU (evicts BOTH primaryKey and altKey atomically).
//   - Keychain-backed AES-256-CBC + HMAC-SHA256 storage for BOTH recalled text AND recalled photos on disk
//     (survives app restarts within 20 MB LRU quota & 14-day TTL) using non-blocking async I/O.
//   - Strictly non-mutating: NEVER mutates Zalo's SQLite database or host chat entity message setters.
//   - Structured recalled detection via ZLModChatEntityAdapter (no false positives on messages containing "thu hồi").
//   - Cleans associated label state on UITableViewCell / UICollectionViewCell prepareForReuse.

#import "ZLMod.h"
#import <os/lock.h>
#import <math.h>

NSString *const ZLModAntiRecallNoticePrefix = @"[ZLMod Bản sao cục bộ — tin nhắn gốc đã thu hồi]";

static const char * const kZLModOrigRecallTextKey = "ZLModOrigRecallText";

@interface ZLModLiveMessageSnapshot : NSObject
@property (nonatomic, assign) int64_t globalId;
@property (nonatomic, assign) int64_t clientId;
@property (nonatomic, copy) NSString *accountScope;
@property (nonatomic, copy) NSString *primaryKey;
@property (nonatomic, copy) NSString *altKey;
@property (nonatomic, copy) NSString *message;
@property (nonatomic, copy) NSString *senderName;
@property (nonatomic, copy) NSString *senderId;
@property (nonatomic, copy) NSString *threadId;
@property (nonatomic, assign) NSTimeInterval timestamp;
@property (nonatomic, strong) NSData *cachedPhotoJPEG;
@end

@implementation ZLModLiveMessageSnapshot
@end

static void ZLModClearUnhiddenMessages(void);

@interface ZLModAntiRecallStore () {
    os_unfair_lock _lock;
}
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *records;
@property (nonatomic, strong) NSMutableDictionary<NSString *, ZLModLiveMessageSnapshot *> *liveByKey;
@property (nonatomic, strong) NSMutableArray<ZLModLiveMessageSnapshot *> *liveOrder;
@property (nonatomic, copy) NSString *storagePath;
@property (nonatomic, copy) NSString *photoDirectoryPath;
- (void)cacheLiveSnapshotFromModel:(ZLModMessageModel *)model photoImage:(UIImage *)photoImage;
- (ZLModLiveMessageSnapshot *)liveSnapshotForAccountScope:(NSString *)scope
                                                 globalId:(int64_t)globalId
                                                 clientId:(int64_t)clientId;
@end

@implementation ZLModAntiRecallStore

+ (instancetype)shared {
    static ZLModAntiRecallStore *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ZLModAntiRecallStore alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _records = [NSMutableDictionary dictionary];
        _liveByKey = [NSMutableDictionary dictionary];
        _liveOrder = [NSMutableArray array];

        NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docs = paths.firstObject ?: NSTemporaryDirectory();
        _storagePath = [docs stringByAppendingPathComponent:@"ZLModAntiRecall.plist"];
        _photoDirectoryPath = [docs stringByAppendingPathComponent:@"ZLModRecallPhotos"];

        [self loadFromDiskLocked];
        [self pruneExpiredEntries];

        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserverForName:UIApplicationDidEnterBackgroundNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *note) {
            [self purgeLiveSnapshots];
            [self pruneExpiredEntries];
        }];

        [nc addObserverForName:UIApplicationWillTerminateNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *note) {
            [self purgeLiveSnapshots];
        }];

        [nc addObserverForName:ZLModAccountDidChangeNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *note) {
            [self purgeLiveSnapshots];
            ZLModClearUnhiddenMessages();
        }];

        [nc addObserverForName:ZLModPrefsDidChangeNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
            NSString *k = [note.object isKindOfClass:[NSString class]] ? (NSString *)note.object : @"";
            if ([k isEqualToString:kZLModAntiRecall] || [k isEqualToString:@"*"]) {
                if (![[ZLModPreferences shared] boolForKey:kZLModAntiRecall]) {
                    [self purgeLiveSnapshots];
                    ZLModClearUnhiddenMessages();
                }
            }
        }];
    }
    return self;
}

#pragma mark - Keys & metadata binding

+ (NSString *)primaryKeyForAccountScope:(NSString *)scope globalId:(int64_t)globalId clientId:(int64_t)clientId {
    if (scope.length == 0) return nil;
    if (globalId > 0) {
        return [NSString stringWithFormat:@"%@:g_%lld", scope, (long long)globalId];
    }
    if (clientId > 0) {
        return [NSString stringWithFormat:@"%@:c_%lld", scope, (long long)clientId];
    }
    return nil;
}

+ (NSData *)metadataForAccountScope:(NSString *)scope
                           globalId:(int64_t)globalId
                           clientId:(int64_t)clientId
                           threadId:(NSString *)threadId
                          timestamp:(NSTimeInterval)timestamp {
    NSMutableData *meta = [NSMutableData data];
    NSData *scopeData = [(scope ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
    if (scopeData) [meta appendData:scopeData];

    uint64_t gidBE = CFSwapInt64HostToBig((uint64_t)globalId);
    uint64_t cidBE = CFSwapInt64HostToBig((uint64_t)clientId);
    int64_t quantizedTs = (int64_t)llround(timestamp);
    uint64_t tsBE = CFSwapInt64HostToBig((uint64_t)quantizedTs);

    [meta appendBytes:&gidBE length:sizeof(gidBE)];
    [meta appendBytes:&cidBE length:sizeof(cidBE)];
    [meta appendBytes:&tsBE length:sizeof(tsBE)];

    NSData *tidData = [(threadId ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
    if (tidData) [meta appendData:tidData];
    return [meta copy];
}

+ (NSData *)photoMetadataForAccountScope:(NSString *)scope key:(NSString *)recordKey {
    NSString *bound = [NSString stringWithFormat:@"ZLModRecallPhoto.v2|%@|%@", scope ?: @"", recordKey ?: @""];
    return [bound dataUsingEncoding:NSUTF8StringEncoding];
}

- (NSString *)photoFilePathForFileName:(NSString *)fileName {
    if (fileName.length == 0) return nil;
    return [self.photoDirectoryPath stringByAppendingPathComponent:fileName];
}

#pragma mark - Disk persistence (non-blocking async writes outside lock)

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
        NSNumber *ver = plist[@"version"];
        NSDictionary *stored = plist[@"records"];
        if (![ver isKindOfClass:[NSNumber class]] || (ver.integerValue != 2 && ver.integerValue != 3) ||
            ![stored isKindOfClass:[NSDictionary class]]) {
            return;
        }
        [stored enumerateKeysAndObjectsUsingBlock:^(id key, id obj, __unused BOOL *stop) {
            if ([key isKindOfClass:[NSString class]] && [obj isKindOfClass:[NSDictionary class]]) {
                self.records[(NSString *)key] = (NSDictionary *)obj;
            }
        }];
    } @catch (__unused NSException *e) {
        ZLMOD_LOG(@"antirecall: exception loading plist");
    }
}

- (NSDictionary *)immutableSnapshotLocked {
    return @{
        @"version": @2,
        @"records": [self.records copy]
    };
}

- (void)deletePhotoFilesAsync:(NSArray<NSString *> *)fileNames {
    if (fileNames.count == 0) return;
    NSString *dir = [self.photoDirectoryPath copy];
    NSArray<NSString *> *copyNames = [fileNames copy];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        for (NSString *name in copyNames) {
            if (name.length == 0) continue;
            [fm removeItemAtPath:[dir stringByAppendingPathComponent:name] error:nil];
        }
    });
}

- (void)enforcePhotoQuotaAsync {
    NSString *dir = [self.photoDirectoryPath copy];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray<NSString *> *files = [fm contentsOfDirectoryAtPath:dir error:nil];
        if (files.count == 0) return;

        NSMutableArray<NSDictionary *> *metaList = [NSMutableArray array];
        unsigned long long totalBytes = 0;
        for (NSString *name in files) {
            NSString *full = [dir stringByAppendingPathComponent:name];
            NSDictionary *attrs = [fm attributesOfItemAtPath:full error:nil];
            unsigned long long sz = [attrs fileSize];
            NSDate *mtime = attrs[NSFileModificationDate] ?: [NSDate distantPast];
            totalBytes += sz;
            [metaList addObject:@{ @"path": full, @"size": @(sz), @"mtime": mtime }];
        }
        if (totalBytes <= kZLModAntiRecallMaxPhotoBytes) return;

        [metaList sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [a[@"mtime"] compare:b[@"mtime"]];
        }];
        for (NSDictionary *item in metaList) {
            if (totalBytes <= kZLModAntiRecallMaxPhotoBytes) break;
            [fm removeItemAtPath:item[@"path"] error:nil];
            totalBytes -= [item[@"size"] unsignedLongLongValue];
        }
    });
}

- (void)pruneExpiredEntries {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSDictionary *snapshot = nil;
    NSMutableArray<NSString *> *photosToDelete = [NSMutableArray array];

    os_unfair_lock_lock(&_lock);
    NSMutableArray<NSString *> *expiredKeys = [NSMutableArray array];
    [self.records enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *entry, __unused BOOL *stop) {
        NSTimeInterval savedAt = [entry[@"savedAt"] doubleValue];
        if (savedAt <= 0 || (now - savedAt) > kZLModAntiRecallTTLSeconds) {
            [expiredKeys addObject:key];
            NSString *pf = entry[@"photoFile"];
            if ([pf isKindOfClass:[NSString class]] && pf.length > 0) [photosToDelete addObject:pf];
        }
    }];

    BOOL mutated = NO;
    if (expiredKeys.count > 0) {
        [self.records removeObjectsForKeys:expiredKeys];
        mutated = YES;
    }

    // Cap per account (kZLModAntiRecallMaxRecordsPerAcc)
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *byScope = [NSMutableDictionary dictionary];
    [self.records enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *entry, __unused BOOL *stop) {
        NSString *sc = [entry[@"accountScope"] isKindOfClass:[NSString class]] ? entry[@"accountScope"] : @"_";
        if (!byScope[sc]) byScope[sc] = [NSMutableArray array];
        [byScope[sc] addObject:key];
    }];
    for (NSString *sc in byScope) {
        NSMutableArray<NSString *> *keys = byScope[sc];
        if (keys.count <= kZLModAntiRecallMaxRecordsPerAcc) continue;
        [keys sortUsingComparator:^NSComparisonResult(NSString *ka, NSString *kb) {
            return [(self.records[ka][@"savedAt"] ?: @0) compare:(self.records[kb][@"savedAt"] ?: @0)];
        }];
        NSUInteger excess = keys.count - kZLModAntiRecallMaxRecordsPerAcc;
        for (NSUInteger i = 0; i < excess; i++) {
            NSString *dropKey = keys[i];
            NSString *pf = self.records[dropKey][@"photoFile"];
            if ([pf isKindOfClass:[NSString class]] && pf.length > 0) [photosToDelete addObject:pf];
            [self.records removeObjectForKey:dropKey];
        }
        mutated = YES;
    }

    if (mutated) {
        snapshot = [self immutableSnapshotLocked];
    }
    os_unfair_lock_unlock(&_lock);

    if (snapshot) {
        ZLModWritePropertyListAsync(snapshot, self.storagePath, nil);
    }
    if (photosToDelete.count > 0) {
        [self deletePhotoFilesAsync:photosToDelete];
    }
}

#pragma mark - Leak-Free Live Snapshot LRU (evicts BOTH primaryKey and altKey)

- (void)purgeLiveSnapshots {
    os_unfair_lock_lock(&_lock);
    [self.liveByKey removeAllObjects];
    [self.liveOrder removeAllObjects];
    os_unfair_lock_unlock(&_lock);
}

- (void)cacheLiveSnapshotFromModel:(ZLModMessageModel *)model photoImage:(UIImage *)photoImage {
    if (![[ZLModPreferences shared] boolForKey:kZLModAntiRecall]) return;
    if (!model || model.isRecalled) return;
    if (model.text.length == 0 && !photoImage) return;
    if ([model.text hasPrefix:ZLModAntiRecallNoticePrefix]) return;
    if ([ZLModChatEntityAdapter isPlaceholderRecalledText:model.text]) return;

    NSString *scope = model.accountScope.length > 0 ? model.accountScope : ZLModCurrentAccountScope();
    NSString *primaryKey = [[self class] primaryKeyForAccountScope:scope globalId:model.globalId clientId:model.clientId];
    if (!primaryKey) return;

    NSString *altKey = (model.globalId > 0 && model.clientId > 0)
        ? [NSString stringWithFormat:@"%@:c_%lld", scope, (long long)model.clientId]
        : nil;

    NSData *jpegData = photoImage ? UIImageJPEGRepresentation(photoImage, 0.82) : nil;

    ZLModLiveMessageSnapshot *snap = [[ZLModLiveMessageSnapshot alloc] init];
    snap.globalId = model.globalId;
    snap.clientId = model.clientId;
    snap.accountScope = scope;
    snap.primaryKey = primaryKey;
    snap.altKey = altKey;
    snap.message = model.text ?: @"";
    snap.senderName = model.senderName ?: @"";
    snap.senderId = model.senderId ?: @"";
    snap.threadId = model.threadId ?: @"";
    snap.timestamp = model.timestampSec;
    snap.cachedPhotoJPEG = jpegData;

    os_unfair_lock_lock(&_lock);
    ZLModLiveMessageSnapshot *existing = self.liveByKey[primaryKey];
    if (existing) {
        [self.liveOrder removeObjectIdenticalTo:existing];
        if (existing.altKey.length > 0 && ![existing.altKey isEqualToString:altKey]) {
            [self.liveByKey removeObjectForKey:existing.altKey];
        }
        if (!snap.cachedPhotoJPEG && existing.cachedPhotoJPEG) {
            snap.cachedPhotoJPEG = existing.cachedPhotoJPEG;
        }
    }
    self.liveByKey[primaryKey] = snap;
    if (altKey.length > 0) {
        self.liveByKey[altKey] = snap;
    }
    [self.liveOrder addObject:snap];

    while (self.liveOrder.count > kZLModAntiRecallMaxLiveSnapshots) {
        ZLModLiveMessageSnapshot *oldest = self.liveOrder.firstObject;
        [self.liveOrder removeObjectAtIndex:0];
        if (oldest) {
            if (oldest.primaryKey.length > 0 && self.liveByKey[oldest.primaryKey] == oldest) {
                [self.liveByKey removeObjectForKey:oldest.primaryKey];
            }
            if (oldest.altKey.length > 0 && self.liveByKey[oldest.altKey] == oldest) {
                [self.liveByKey removeObjectForKey:oldest.altKey];
            }
        }
    }
    os_unfair_lock_unlock(&_lock);
}

- (ZLModLiveMessageSnapshot *)liveSnapshotForAccountScope:(NSString *)scope
                                                 globalId:(int64_t)globalId
                                                 clientId:(int64_t)clientId {
    if (scope.length == 0) return nil;
    os_unfair_lock_lock(&_lock);
    ZLModLiveMessageSnapshot *snap = nil;
    if (globalId > 0) {
        snap = self.liveByKey[[NSString stringWithFormat:@"%@:g_%lld", scope, (long long)globalId]];
    }
    if (!snap && clientId > 0) {
        snap = self.liveByKey[[NSString stringWithFormat:@"%@:c_%lld", scope, (long long)clientId]];
    }
    os_unfair_lock_unlock(&_lock);
    return snap;
}

#pragma mark - Encrypted recalled text + photo persistence

- (BOOL)saveSnapshotWithGlobalId:(int64_t)globalId
                        clientId:(int64_t)clientId
                         message:(NSString *)message
                      senderName:(NSString *)senderName
                        senderId:(NSString *)senderId
                        threadId:(NSString *)threadId
                       timestamp:(NSTimeInterval)timestamp {
    return [self saveEncryptedRecordWithGlobalId:globalId
                                        clientId:clientId
                                         message:message
                                      senderName:senderName
                                        senderId:senderId
                                        threadId:threadId
                                       timestamp:timestamp
                                       photoJPEG:nil];
}

- (BOOL)saveSnapshotFromModel:(ZLModMessageModel *)model photoImage:(UIImage *)photoImage {
    if (!model) return NO;
    NSString *scope = model.accountScope.length > 0 ? model.accountScope : ZLModCurrentAccountScope();
    ZLModLiveMessageSnapshot *cached = [self liveSnapshotForAccountScope:scope
                                                                globalId:model.globalId
                                                                clientId:model.clientId];

    NSString *msg = cached.message;
    if (msg.length == 0 && model.originRecallText.length > 0 &&
        ![ZLModChatEntityAdapter isPlaceholderRecalledText:model.originRecallText]) {
        msg = model.originRecallText;
    }
    if (msg.length == 0 && model.text.length > 0 &&
        ![ZLModChatEntityAdapter isPlaceholderRecalledText:model.text]) {
        msg = model.text;
    }

    NSData *photoJPEG = cached.cachedPhotoJPEG;
    if (!photoJPEG && photoImage) {
        photoJPEG = UIImageJPEGRepresentation(photoImage, 0.82);
    }
    if (msg.length == 0 && photoJPEG.length > 0) {
        msg = @"[Hình ảnh đã thu hồi]";
    }
    if (msg.length == 0) return NO;

    NSString *sName = cached.senderName.length > 0 ? cached.senderName : model.senderName;
    NSString *sId = cached.senderId.length > 0 ? cached.senderId : model.senderId;
    NSString *tid = cached.threadId.length > 0 ? cached.threadId : model.threadId;
    NSTimeInterval ts = (cached.timestamp > 0) ? cached.timestamp : model.timestampSec;

    return [self saveEncryptedRecordWithGlobalId:model.globalId
                                        clientId:model.clientId
                                         message:msg
                                      senderName:sName
                                        senderId:sId
                                        threadId:tid
                                       timestamp:ts
                                       photoJPEG:photoJPEG];
}

- (BOOL)saveEncryptedRecordWithGlobalId:(int64_t)globalId
                               clientId:(int64_t)clientId
                                message:(NSString *)message
                             senderName:(NSString *)senderName
                               senderId:(NSString *)senderId
                               threadId:(NSString *)threadId
                              timestamp:(NSTimeInterval)timestamp
                              photoJPEG:(NSData *)photoJPEG {
    if (![message isKindOfClass:[NSString class]] || message.length == 0) return NO;
    if ([message hasPrefix:ZLModAntiRecallNoticePrefix]) return NO;

    NSString *scope = ZLModCurrentAccountScope();
    NSString *key = [[self class] primaryKeyForAccountScope:scope globalId:globalId clientId:clientId];
    if (!key) return NO;

    NSTimeInterval effectiveTs = (timestamp > 0) ? timestamp : [[NSDate date] timeIntervalSince1970];
    int64_t quantizedTs = (int64_t)llround(effectiveTs);
    NSString *safeThread = threadId ?: @"";
    NSString *safeSender = (senderName.length > 0) ? senderName : @"Người gửi";

    NSString *payloadText = [NSString stringWithFormat:@"%@\n%@", safeSender, message];
    NSData *metadata = [[self class] metadataForAccountScope:scope
                                                    globalId:globalId
                                                    clientId:clientId
                                                    threadId:safeThread
                                                   timestamp:(NSTimeInterval)quantizedTs];
    NSData *cipher = [[ZLModCryptoBox shared] encryptString:payloadText metadata:metadata];
    if (!cipher) return NO;

    // Optional encrypted photo persistence to disk (survives restart!)
    NSString *photoFileName = nil;
    NSData *encryptedPhoto = nil;
    if (photoJPEG.length > 0) {
        NSData *photoMeta = [[self class] photoMetadataForAccountScope:scope key:key];
        encryptedPhoto = [[ZLModCryptoBox shared] encryptData:photoJPEG metadata:photoMeta];
        if (encryptedPhoto.length > 0) {
            NSString *fileHash = ZLModSha256Hex(key);
            if (fileHash.length >= 24) {
                photoFileName = [NSString stringWithFormat:@"%@.enc", [fileHash substringToIndex:24]];
            }
        }
    }

    NSMutableDictionary *record = [NSMutableDictionary dictionaryWithDictionary:@{
        @"accountScope": scope,
        @"globalId": @(globalId),
        @"clientId": @(clientId),
        @"threadId": safeThread,
        @"threadHash": ZLModSafeIdHash(safeThread),
        @"senderHash": ZLModSafeIdHash(senderId ?: @""),
        @"msgTimestamp": @(quantizedTs),
        @"savedAt": @([[NSDate date] timeIntervalSince1970]),
        @"cipher": cipher
    }];
    if (photoFileName.length > 0) {
        record[@"photoFile"] = photoFileName;
    }

    NSDictionary *snapshot = nil;
    os_unfair_lock_lock(&_lock);
    self.records[key] = [record copy];
    snapshot = [self immutableSnapshotLocked];
    os_unfair_lock_unlock(&_lock);

    if (encryptedPhoto.length > 0 && photoFileName.length > 0) {
        NSString *photoPath = [self photoFilePathForFileName:photoFileName];
        ZLModWriteDataAsync(encryptedPhoto, photoPath, ^(__unused BOOL ok) {
            [self enforcePhotoQuotaAsync];
        });
    }
    ZLModWritePropertyListAsync(snapshot, self.storagePath, nil);
    [self pruneExpiredEntries];
    return YES;
}

- (NSDictionary *)recordLockedForAccountScope:(NSString *)scope
                                     globalId:(int64_t)globalId
                                     clientId:(int64_t)clientId
                                       outKey:(NSString **)outKey {
    if (scope.length == 0) return nil;
    if (globalId > 0) {
        NSString *gKey = [NSString stringWithFormat:@"%@:g_%lld", scope, (long long)globalId];
        if (self.records[gKey]) {
            if (outKey) *outKey = gKey;
            return self.records[gKey];
        }
    }
    if (clientId > 0) {
        NSString *cKey = [NSString stringWithFormat:@"%@:c_%lld", scope, (long long)clientId];
        if (self.records[cKey]) {
            if (outKey) *outKey = cKey;
            return self.records[cKey];
        }
    }
    if (globalId > 0 || clientId > 0) {
        NSString *prefix = [scope stringByAppendingString:@":"];
        for (NSString *k in self.records) {
            if (![k hasPrefix:prefix]) continue;
            NSDictionary *rec = self.records[k];
            int64_t rGid = [rec[@"globalId"] longLongValue];
            int64_t rCid = [rec[@"clientId"] longLongValue];
            if ((globalId > 0 && rGid == globalId) || (clientId > 0 && rCid == clientId)) {
                if (outKey) *outKey = k;
                return rec;
            }
        }
    }
    return nil;
}

- (NSString *)decryptMessageFromRecord:(NSDictionary *)record expectedScope:(NSString *)scope {
    if (!record || scope.length == 0) return nil;
    NSString *recScope = record[@"accountScope"];
    if (![recScope isKindOfClass:[NSString class]] || ![recScope isEqualToString:scope]) return nil;

    NSTimeInterval savedAt = [record[@"savedAt"] doubleValue];
    if (savedAt <= 0 || ([[NSDate date] timeIntervalSince1970] - savedAt) > kZLModAntiRecallTTLSeconds) {
        return nil;
    }

    NSData *cipher = record[@"cipher"];
    if (![cipher isKindOfClass:[NSData class]]) return nil;

    int64_t gid = [record[@"globalId"] longLongValue];
    int64_t cid = [record[@"clientId"] longLongValue];
    NSString *tid = [record[@"threadId"] isKindOfClass:[NSString class]] ? record[@"threadId"] : @"";
    NSTimeInterval msgTs = [record[@"msgTimestamp"] doubleValue];

    NSData *meta = [[self class] metadataForAccountScope:scope
                                                globalId:gid
                                                clientId:cid
                                                threadId:tid
                                               timestamp:msgTs];
    NSString *plain = [[ZLModCryptoBox shared] decryptData:cipher metadata:meta];
    if (!plain || plain.length == 0) return nil;

    NSRange nl = [plain rangeOfString:@"\n"];
    if (nl.location == NSNotFound) return plain;
    return [plain substringFromIndex:nl.location + 1];
}

- (NSString *)recalledTextForGlobalId:(int64_t)globalId clientId:(int64_t)clientId {
    NSString *scope = ZLModCurrentAccountScope();
    if (scope.length == 0) return nil;

    os_unfair_lock_lock(&_lock);
    NSDictionary *rec = [self recordLockedForAccountScope:scope globalId:globalId clientId:clientId outKey:nil];
    os_unfair_lock_unlock(&_lock);

    return [self decryptMessageFromRecord:rec expectedScope:scope];
}

- (NSString *)formattedNoticeForGlobalId:(int64_t)globalId clientId:(int64_t)clientId {
    NSString *text = [self recalledTextForGlobalId:globalId clientId:clientId];
    if (text.length == 0) return nil;
    return [NSString stringWithFormat:@"%@ %@", ZLModAntiRecallNoticePrefix, text];
}

- (UIImage *)preservedPhotoForGlobalId:(int64_t)globalId clientId:(int64_t)clientId {
    NSString *scope = ZLModCurrentAccountScope();
    if (scope.length == 0) return nil;

    // 1. Live snapshot photo in RAM
    ZLModLiveMessageSnapshot *live = [self liveSnapshotForAccountScope:scope globalId:globalId clientId:clientId];
    if (live.cachedPhotoJPEG.length > 0) {
        UIImage *img = [UIImage imageWithData:live.cachedPhotoJPEG];
        if (img) return img;
    }

    // 2. Encrypted photo persisted on disk (survives app restarts)
    NSString *recKey = nil;
    os_unfair_lock_lock(&_lock);
    NSDictionary *rec = [self recordLockedForAccountScope:scope globalId:globalId clientId:clientId outKey:&recKey];
    os_unfair_lock_unlock(&_lock);

    NSString *photoFile = [rec[@"photoFile"] isKindOfClass:[NSString class]] ? rec[@"photoFile"] : nil;
    if (photoFile.length == 0 || recKey.length == 0) return nil;

    NSString *path = [self photoFilePathForFileName:photoFile];
    NSData *enc = [NSData dataWithContentsOfFile:path];
    if (enc.length == 0) return nil;

    NSData *photoMeta = [[self class] photoMetadataForAccountScope:scope key:recKey];
    NSData *plainJPEG = [[ZLModCryptoBox shared] decryptRawData:enc metadata:photoMeta];
    if (plainJPEG.length == 0) return nil;
    return [UIImage imageWithData:plainJPEG];
}

#pragma mark - History inspection & clearing

- (NSArray<NSDictionary<NSString *, id> *> *)entriesForCurrentAccount {
    NSString *scope = ZLModCurrentAccountScope();
    if (scope.length == 0) return @[];
    NSString *prefix = [scope stringByAppendingString:@":"];
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];

    NSMutableArray<NSDictionary<NSString *, id> *> *list = [NSMutableArray array];
    os_unfair_lock_lock(&_lock);
    [self.records enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *rec, __unused BOOL *stop) {
        if (![key hasPrefix:prefix]) return;
        NSTimeInterval savedAt = [rec[@"savedAt"] doubleValue];
        if (savedAt <= 0 || (now - savedAt) > kZLModAntiRecallTTLSeconds) return;
        BOOL hasPhoto = ([rec[@"photoFile"] isKindOfClass:[NSString class]] && [(NSString *)rec[@"photoFile"] length] > 0);
        [list addObject:@{
            @"key": key,
            @"globalId": rec[@"globalId"] ?: @0,
            @"clientId": rec[@"clientId"] ?: @0,
            @"threadHash": rec[@"threadHash"] ?: @"none",
            @"senderHash": rec[@"senderHash"] ?: @"none",
            @"hasPhoto": @(hasPhoto),
            @"savedAt": @(savedAt),
            @"msgTimestamp": rec[@"msgTimestamp"] ?: @(savedAt)
        }];
    }];
    os_unfair_lock_unlock(&_lock);

    [list sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"savedAt"] compare:a[@"savedAt"]];
    }];
    return [list copy];
}

- (NSString *)revealTextForEntryKey:(NSString *)entryKey {
    NSString *scope = ZLModCurrentAccountScope();
    if (scope.length == 0 || entryKey.length == 0) return nil;
    NSString *prefix = [scope stringByAppendingString:@":"];
    if (![entryKey hasPrefix:prefix]) return nil;

    os_unfair_lock_lock(&_lock);
    NSDictionary *rec = self.records[entryKey];
    os_unfair_lock_unlock(&_lock);
    if (!rec) return nil;

    int64_t gid = [rec[@"globalId"] longLongValue];
    int64_t cid = [rec[@"clientId"] longLongValue];
    NSString *tid = [rec[@"threadId"] isKindOfClass:[NSString class]] ? rec[@"threadId"] : @"";
    NSTimeInterval msgTs = [rec[@"msgTimestamp"] doubleValue];
    NSData *cipher = rec[@"cipher"];
    if (![cipher isKindOfClass:[NSData class]]) return nil;

    NSData *meta = [[self class] metadataForAccountScope:scope
                                                globalId:gid
                                                clientId:cid
                                                threadId:tid
                                               timestamp:msgTs];
    NSString *plain = [[ZLModCryptoBox shared] decryptData:cipher metadata:meta];
    if (!plain || plain.length == 0) return nil;

    NSRange nl = [plain rangeOfString:@"\n"];
    if (nl.location == NSNotFound) {
        return [NSString stringWithFormat:@"%@\n%@", ZLModAntiRecallNoticePrefix, plain];
    }
    NSString *sender = [plain substringToIndex:nl.location];
    NSString *body = [plain substringFromIndex:nl.location + 1];
    return [NSString stringWithFormat:@"%@\nNgười gửi: %@\nNội dung: %@",
            ZLModAntiRecallNoticePrefix, sender, body];
}

- (NSUInteger)preservedCountForCurrentAccount {
    NSString *scope = ZLModCurrentAccountScope();
    if (scope.length == 0) return 0;
    NSString *prefix = [scope stringByAppendingString:@":"];
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];

    __block NSUInteger count = 0;
    os_unfair_lock_lock(&_lock);
    [self.records enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *rec, __unused BOOL *stop) {
        if (![key hasPrefix:prefix]) return;
        NSTimeInterval savedAt = [rec[@"savedAt"] doubleValue];
        if (savedAt > 0 && (now - savedAt) <= kZLModAntiRecallTTLSeconds) count++;
    }];
    os_unfair_lock_unlock(&_lock);
    return count;
}

- (void)clearCurrentAccountHistory {
    [self purgeLiveSnapshots];
    NSString *scope = ZLModCurrentAccountScope();
    if (scope.length == 0) return;
    NSString *prefix = [scope stringByAppendingString:@":"];

    NSDictionary *snapshot = nil;
    NSMutableArray<NSString *> *photosToDelete = [NSMutableArray array];
    os_unfair_lock_lock(&_lock);
    NSMutableArray<NSString *> *toRemove = [NSMutableArray array];
    for (NSString *k in self.records) {
        if ([k hasPrefix:prefix]) {
            [toRemove addObject:k];
            NSString *pf = self.records[k][@"photoFile"];
            if ([pf isKindOfClass:[NSString class]] && pf.length > 0) [photosToDelete addObject:pf];
        }
    }
    if (toRemove.count > 0) {
        [self.records removeObjectsForKeys:toRemove];
        snapshot = [self immutableSnapshotLocked];
    }
    os_unfair_lock_unlock(&_lock);

    if (snapshot) ZLModWritePropertyListAsync(snapshot, self.storagePath, nil);
    if (photosToDelete.count > 0) [self deletePhotoFilesAsync:photosToDelete];
}

- (void)clearAllHistory {
    [self purgeLiveSnapshots];
    NSDictionary *snapshot = nil;
    os_unfair_lock_lock(&_lock);
    [self.records removeAllObjects];
    snapshot = [self immutableSnapshotLocked];
    os_unfair_lock_unlock(&_lock);

    ZLModWritePropertyListAsync(snapshot, self.storagePath, nil);
    NSString *photoDir = [self.photoDirectoryPath copy];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        [[NSFileManager defaultManager] removeItemAtPath:photoDir error:nil];
    });
    ZLMOD_LOG(@"antirecall: all local history & encrypted photos cleared");
}

@end

#pragma mark - In-Place Unhide/Hide State & Cell Reuse Safety

static os_unfair_lock gUnhiddenLock = OS_UNFAIR_LOCK_INIT;
static NSMutableSet<NSString *> *gUnhiddenMessageKeys = nil;

static NSString *ZLModUnhiddenKey(NSString *accountScope, NSString *threadId, int64_t gid, int64_t cid) {
    NSString *scope = accountScope.length ? accountScope : (ZLModCurrentAccountScope() ?: @"anon");
    NSString *tid = threadId.length ? threadId : @"*";
    if (gid > 0) return [NSString stringWithFormat:@"%@:%@:g_%lld", scope, tid, (long long)gid];
    if (cid > 0) return [NSString stringWithFormat:@"%@:%@:c_%lld", scope, tid, (long long)cid];
    return nil;
}

static void ZLModClearUnhiddenMessages(void) {
    os_unfair_lock_lock(&gUnhiddenLock);
    [gUnhiddenMessageKeys removeAllObjects];
    os_unfair_lock_unlock(&gUnhiddenLock);
}

static BOOL ZLModIsMessageUnhidden(NSString *accountScope, NSString *threadId, int64_t gid, int64_t cid) {
    NSString *key = ZLModUnhiddenKey(accountScope, threadId, gid, cid);
    if (key.length == 0) return NO;
    os_unfair_lock_lock(&gUnhiddenLock);
    BOOL exists = [gUnhiddenMessageKeys containsObject:key];
    os_unfair_lock_unlock(&gUnhiddenLock);
    return exists;
}

static void ZLModSetMessageUnhidden(NSString *accountScope, NSString *threadId, int64_t gid, int64_t cid, BOOL unhidden) {
    NSString *key = ZLModUnhiddenKey(accountScope, threadId, gid, cid);
    if (key.length == 0) return;
    os_unfair_lock_lock(&gUnhiddenLock);
    if (!gUnhiddenMessageKeys) {
        gUnhiddenMessageKeys = [NSMutableSet set];
    }
    if (unhidden) {
        [gUnhiddenMessageKeys addObject:key];
    } else {
        [gUnhiddenMessageKeys removeObject:key];
    }
    os_unfair_lock_unlock(&gUnhiddenLock);
}

static NSString *ZLModResolveRecalledText(id chat, int64_t gid, int64_t cid) {
    NSString *scope = ZLModCurrentAccountScope();
    ZLModAntiRecallStore *store = [ZLModAntiRecallStore shared];

    // 1. Encrypted persistent archive
    NSString *decrypted = [store recalledTextForGlobalId:gid clientId:cid];
    if (decrypted.length > 0 && ![ZLModChatEntityAdapter isPlaceholderRecalledText:decrypted]) {
        return decrypted;
    }

    // 2. Live pre-recall snapshot
    ZLModLiveMessageSnapshot *snap = [store liveSnapshotForAccountScope:scope globalId:gid clientId:cid];
    if (snap.message.length > 0 && ![ZLModChatEntityAdapter isPlaceholderRecalledText:snap.message]) {
        return snap.message;
    }

    // 3. Host entity original fields
    if (chat) {
        for (NSString *s in @[@"originTextRecallMsg", @"_originTextRecallMsg", @"originText"]) {
            NSString *v = ZLModSafeStringProperty(chat, NSSelectorFromString(s));
            if (v.length > 0 && ![ZLModChatEntityAdapter isPlaceholderRecalledText:v]) {
                return v;
            }
        }
    }

    if (gid > 0 || cid > 0) {
        NSString *notice = [store formattedNoticeForGlobalId:gid clientId:cid];
        if (notice.length > 0) return notice;
    }
    return nil;
}

static UILabel *ZLModFindRecallLabel(UIView *view, BOOL isUnhiding) {
    if (!view) return nil;
    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *lbl = (UILabel *)view;
        if (isUnhiding) {
            NSString *curText = lbl.text;
            if ([ZLModChatEntityAdapter isPlaceholderRecalledText:curText]) {
                return lbl;
            }
        } else {
            NSString *orig = objc_getAssociatedObject(lbl, kZLModOrigRecallTextKey);
            if (orig.length > 0) {
                return lbl;
            }
        }
    }
    for (UIView *sub in view.subviews) {
        UILabel *found = ZLModFindRecallLabel(sub, isUnhiding);
        if (found) return found;
    }
    return nil;
}

static void ZLModCleanupAssociatedRecallLabelsInView(UIView *view) {
    if (!view) return;
    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *lbl = (UILabel *)view;
        NSString *orig = objc_getAssociatedObject(lbl, kZLModOrigRecallTextKey);
        if (orig.length > 0) {
            lbl.text = orig;
            objc_setAssociatedObject(lbl, kZLModOrigRecallTextKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
        }
    }
    for (UIView *sub in view.subviews) {
        ZLModCleanupAssociatedRecallLabelsInView(sub);
    }
}

static BOOL ZLModUpdateTextInViewHierarchy(UIView *view, NSString *newText, BOOL isUnhiding) {
    UILabel *targetLabel = ZLModFindRecallLabel(view, isUnhiding);
    if (!targetLabel) return NO;

    if (isUnhiding) {
        NSString *curText = targetLabel.text;
        objc_setAssociatedObject(targetLabel, kZLModOrigRecallTextKey, curText, OBJC_ASSOCIATION_COPY_NONATOMIC);
        targetLabel.text = newText;
        targetLabel.numberOfLines = 0;
        [targetLabel sizeToFit];
        return YES;
    } else {
        NSString *orig = objc_getAssociatedObject(targetLabel, kZLModOrigRecallTextKey);
        if (orig.length > 0) {
            targetLabel.text = orig;
            objc_setAssociatedObject(targetLabel, kZLModOrigRecallTextKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
            [targetLabel sizeToFit];
            return YES;
        }
        return NO;
    }
}

static UIView *ZLModFindContainingCellOrRoot(UIView *view) {
    UIView *p = view;
    UIView *root = view;
    while (p) {
        root = p;
        if ([p isKindOfClass:[UITableViewCell class]] || [p isKindOfClass:[UICollectionViewCell class]]) {
            return p;
        }
        p = p.superview;
    }
    return root;
}

static void ZLModApplyRecallTextInPlace(UIView *menuButton, NSString *text, BOOL isUnhiding) {
    if (!menuButton) return;
    UIView *container = ZLModFindContainingCellOrRoot(menuButton);
    ZLModUpdateTextInViewHierarchy(container, text, isUnhiding);
    [container setNeedsLayout];
    [container layoutIfNeeded];
}

static id ZLModMakeRecallMenuItem(id template, NSString *title, NSString *symbolName, NSInteger actionId) {
    Class vmClass = NSClassFromString(@"ContextMenuViewModel");
    if (!vmClass) return nil;
    id vm = [[vmClass alloc] init];
    if (!vm) return nil;

    if (template && [template isKindOfClass:vmClass]) {
        static NSArray<NSArray<NSString *> *> *pairs;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            pairs = @[
                @[@"textColor", @"setTextColor:"],
                @[@"iconColor", @"setIconColor:"],
                @[@"disabledTextColor", @"setDisabledTextColor:"],
                @[@"disabledIconColor", @"setDisabledIconColor:"],
            ];
        });
        for (NSArray<NSString *> *pair in pairs) {
            SEL getter = NSSelectorFromString(pair[0]);
            SEL setter = NSSelectorFromString(pair[1]);
            if (![template respondsToSelector:getter] || ![vm respondsToSelector:setter]) continue;
            id value = ZLModSafeObjectProperty(template, getter);
            if (value) ((void (*)(id, SEL, id))objc_msgSend)(vm, setter, value);
        }
    }

    SEL setTextSel = sel_registerName("setText:");
    if ([vm respondsToSelector:setTextSel]) {
        ((void (*)(id, SEL, id))objc_msgSend)(vm, setTextSel, title ?: @"");
    }
    SEL setMenuTypeSel = sel_registerName("setMenuType:");
    if ([vm respondsToSelector:setMenuTypeSel]) {
        ((void (*)(id, SEL, NSInteger))objc_msgSend)(vm, setMenuTypeSel, actionId);
    }
    UIImage *icon = symbolName.length > 0 ? [UIImage systemImageNamed:symbolName] : nil;
    if (!icon) icon = [UIImage systemImageNamed:@"eye"];
    if (icon) {
        icon = [icon imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        SEL setIconSel = sel_registerName("setIconImage:");
        if ([vm respondsToSelector:setIconSel]) {
            ((void (*)(id, SEL, id))objc_msgSend)(vm, setIconSel, icon);
        }
    }
    return vm;
}

#pragma mark - Pinch-Zoom Recalled Photo Preview Modal

@interface ZLModPhotoPreviewViewController : UIViewController <UIScrollViewDelegate>
@property (nonatomic, strong) UIImage *photo;
@property (nonatomic, copy) NSString *senderName;
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) UINavigationBar *navBar;
@property (nonatomic, strong) UIView *bottomBar;
@property (nonatomic, strong) UIButton *saveBtn;
@property (nonatomic, strong) UIButton *clipboardBtn;
@end

@implementation ZLModPhotoPreviewViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    self.scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    self.scrollView.delegate = self;
    self.scrollView.minimumZoomScale = 1.0;
    self.scrollView.maximumZoomScale = 4.0;
    self.scrollView.showsHorizontalScrollIndicator = NO;
    self.scrollView.showsVerticalScrollIndicator = NO;
    [self.view addSubview:self.scrollView];

    self.imageView = [[UIImageView alloc] initWithFrame:self.scrollView.bounds];
    self.imageView.contentMode = UIViewContentModeScaleAspectFit;
    self.imageView.image = self.photo;
    self.imageView.userInteractionEnabled = YES;
    self.imageView.isAccessibilityElement = YES;
    self.imageView.accessibilityLabel = @"Ảnh đã thu hồi";
    [self.scrollView addSubview:self.imageView];

    UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleDoubleTap:)];
    doubleTap.numberOfTapsRequired = 2;
    [self.scrollView addGestureRecognizer:doubleTap];

    self.navBar = [[UINavigationBar alloc] init];
    self.navBar.barStyle = UIBarStyleBlack;
    self.navBar.translucent = YES;
    NSString *navTitle = self.senderName.length ? [NSString stringWithFormat:@"Ảnh từ %@", self.senderName] : @"Ảnh đã thu hồi";
    UINavigationItem *navItem = [[UINavigationItem alloc] initWithTitle:navTitle];
    UIBarButtonItem *closeBtn = [[UIBarButtonItem alloc] initWithTitle:@"Đóng"
                                                                 style:UIBarButtonItemStyleDone
                                                                target:self
                                                                action:@selector(closeTapped)];
    closeBtn.tintColor = [UIColor whiteColor];
    closeBtn.accessibilityLabel = @"Đóng xem ảnh";
    navItem.rightBarButtonItem = closeBtn;
    [self.navBar pushNavigationItem:navItem animated:NO];
    [self.view addSubview:self.navBar];

    self.bottomBar = [[UIView alloc] init];
    self.bottomBar.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.82];
    [self.view addSubview:self.bottomBar];

    self.saveBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.saveBtn setTitle:@" Lưu vào Ảnh" forState:UIControlStateNormal];
    [self.saveBtn setImage:[UIImage systemImageNamed:@"square.and.arrow.down"] forState:UIControlStateNormal];
    [self.saveBtn setTintColor:[UIColor whiteColor]];
    self.saveBtn.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.saveBtn.titleLabel.adjustsFontForContentSizeCategory = YES;
    self.saveBtn.accessibilityLabel = @"Lưu ảnh vào Thư viện";
    [self.saveBtn addTarget:self action:@selector(saveTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.bottomBar addSubview:self.saveBtn];

    self.clipboardBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.clipboardBtn setTitle:@" Sao chép ảnh" forState:UIControlStateNormal];
    [self.clipboardBtn setImage:[UIImage systemImageNamed:@"doc.on.doc"] forState:UIControlStateNormal];
    [self.clipboardBtn setTintColor:[UIColor whiteColor]];
    self.clipboardBtn.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.clipboardBtn.titleLabel.adjustsFontForContentSizeCategory = YES;
    self.clipboardBtn.accessibilityLabel = @"Sao chép ảnh vào bộ nhớ tạm";
    [self.clipboardBtn addTarget:self action:@selector(handleCopyTapped) forControlEvents:UIControlEventTouchUpInside];
    [self.bottomBar addSubview:self.clipboardBtn];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = self.view.bounds.size.width;
    CGFloat h = self.view.bounds.size.height;
    CGFloat topSafe = self.view.safeAreaInsets.top;
    CGFloat bottomSafe = self.view.safeAreaInsets.bottom;
    CGFloat navH = 52.0;
    CGFloat bottomH = 64.0 + bottomSafe;

    self.navBar.frame = CGRectMake(0.0, topSafe, w, navH);
    self.bottomBar.frame = CGRectMake(0.0, h - bottomH, w, bottomH);
    self.saveBtn.frame = CGRectMake(16.0, 10.0, 150.0, 44.0);
    self.clipboardBtn.frame = CGRectMake(w - 166.0, 10.0, 150.0, 44.0);

    CGRect imgRect = CGRectMake(0.0, topSafe + navH, w, MAX(h - topSafe - navH - bottomH, 100.0));
    self.scrollView.zoomScale = 1.0;
    self.scrollView.frame = imgRect;
    self.scrollView.contentSize = imgRect.size;
    self.imageView.frame = CGRectMake(0.0, 0.0, imgRect.size.width, imgRect.size.height);
}

- (UIView *)viewForZoomingInScrollView:(__unused UIScrollView *)scrollView {
    return self.imageView;
}

- (void)handleDoubleTap:(UITapGestureRecognizer *)tap {
    if (self.scrollView.zoomScale > 1.05) {
        [self.scrollView setZoomScale:1.0 animated:YES];
    } else {
        CGPoint pt = [tap locationInView:self.imageView];
        CGRect zoomRect = CGRectMake(pt.x - 60.0, pt.y - 60.0, 120.0, 120.0);
        [self.scrollView zoomToRect:zoomRect animated:YES];
    }
}

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)saveTapped {
    if (self.photo) {
        UIImageWriteToSavedPhotosAlbum(self.photo, self, @selector(image:didFinishSavingWithError:contextInfo:), NULL);
    }
}

- (void)image:(__unused UIImage *)image didFinishSavingWithError:(NSError *)error contextInfo:(__unused void *)contextInfo {
    if (error) {
        ZLModShowToast([NSString stringWithFormat:@"Lỗi lưu ảnh: %@", error.localizedDescription ?: @"Không có quyền"]);
    } else {
        ZLModShowToast(@"Đã lưu ảnh vào Thư viện Ảnh");
    }
}

- (void)handleCopyTapped {
    if (self.photo) {
        [UIPasteboard generalPasteboard].image = self.photo;
        ZLModShowToast(@"Đã sao chép ảnh vào bộ nhớ tạm");
    }
}

@end

static BOOL ZLModIsChatRecalled(id chat) {
    if (!chat) return NO;
    ZLModMessageModel *model = [ZLModChatEntityAdapter modelFromChatEntity:chat fallbackThreadId:nil];
    if (model.isRecalled) return YES;
    if ((model.globalId > 0 || model.clientId > 0) &&
        [[ZLModAntiRecallStore shared] recalledTextForGlobalId:model.globalId clientId:model.clientId].length > 0) {
        return YES;
    }
    return NO;
}

#pragma mark - Install (subscribes to ZLModMessageTapBus + installs non-mutating UI & reuse hooks)

void ZLModAntiRecallInstall(void) {
    NSUInteger installed = 0;

    // 1. Register as consumer of the decoupled ZLModMessageTapBus
    [[ZLModMessageTapBus shared] registerConsumerNamed:@"AntiRecall"
                                                 block:^(ZLModMessageModel *model, id rawEntity, ZLModMessageTapEventKind kind) {
        if (![[ZLModPreferences shared] boolForKey:kZLModAntiRecall]) return;
        UIImage *photo = model.hasPhotoAttachment ? [ZLModChatEntityAdapter extractPhotoImageFromChatEntity:rawEntity] : nil;
        if (kind == ZLModMessageTapEventObserved) {
            [[ZLModAntiRecallStore shared] cacheLiveSnapshotFromModel:model photoImage:photo];
        } else if (kind == ZLModMessageTapEventRecalled) {
            [[ZLModAntiRecallStore shared] saveSnapshotFromModel:model photoImage:photo];
        }
    }];
    installed++;

    // 2. Non-mutating ChatEntity display hooks
    Class chatEntityCls = NSClassFromString(@"ChatEntity");
    if (chatEntityCls) {
        SEL previewSel = sel_registerName("_getRecalledMsgPreviewFromSource:");
        if (ZLModClassHasInstanceMethod(chatEntityCls, previewSel)) {
            IMP orig = class_getMethodImplementation(chatEntityCls, previewSel);
            if (ZLModReplaceMethod(chatEntityCls, previewSel, 1, "@", ^id(id selfObj, NSInteger source) {
                id origPreview = orig ? ((id (*)(id, SEL, NSInteger))orig)(selfObj, previewSel, source) : nil;
                if (![[ZLModPreferences shared] boolForKey:kZLModAntiRecall]) {
                    return origPreview;
                }
                ZLModMessageModel *m = [ZLModChatEntityAdapter modelFromChatEntity:selfObj fallbackThreadId:nil];
                if (!m || (m.globalId <= 0 && m.clientId <= 0)) return origPreview;

                if (ZLModIsMessageUnhidden(m.accountScope, m.threadId, m.globalId, m.clientId)) {
                    NSString *unhiddenText = ZLModResolveRecalledText(selfObj, m.globalId, m.clientId);
                    if (unhiddenText.length > 0) return unhiddenText;
                }
                NSString *notice = [[ZLModAntiRecallStore shared] formattedNoticeForGlobalId:m.globalId clientId:m.clientId];
                return (notice.length > 0) ? notice : origPreview;
            })) {
                installed++;
            }
        }

        SEL messageSel = sel_registerName("message");
        if (ZLModClassHasInstanceMethod(chatEntityCls, messageSel)) {
            IMP orig = class_getMethodImplementation(chatEntityCls, messageSel);
            if (ZLModReplaceMethod(chatEntityCls, messageSel, 0, "@", ^id(id selfObj) {
                id origMsg = orig ? ((id (*)(id, SEL))orig)(selfObj, messageSel) : nil;
                if (![[ZLModPreferences shared] boolForKey:kZLModAntiRecall]) {
                    return origMsg;
                }
                int64_t gid = ZLModSafeInt64Property(selfObj, sel_registerName("globalId"), 0);
                if (gid <= 0) gid = ZLModSafeInt64Property(selfObj, sel_registerName("globalMsgId"), 0);
                int64_t cid = ZLModSafeInt64Property(selfObj, sel_registerName("clientId"), 0);
                if (cid <= 0) cid = ZLModSafeInt64Property(selfObj, sel_registerName("cliMsgId"), 0);
                if (gid > 0 || cid > 0) {
                    NSString *scope = ZLModCurrentAccountScope();
                    NSString *tid = ZLModSafeStringProperty(selfObj, sel_registerName("threadId")) ?:
                                    ZLModSafeStringProperty(selfObj, sel_registerName("tuid"));
                    if (ZLModIsMessageUnhidden(scope, tid, gid, cid)) {
                        NSString *unhidden = ZLModResolveRecalledText(selfObj, gid, cid);
                        if (unhidden.length > 0) return unhidden;
                    }
                }
                return origMsg;
            })) {
                installed++;
            }
        }
    }

    // 3. Cell reuse cleanup hooks so associated recall labels never leak into recycled chat bubbles
    SEL reuseSel = sel_registerName("prepareForReuse");
    for (Class cellBaseCls in @[[UITableViewCell class], [UICollectionViewCell class]]) {
        if (ZLModClassHasInstanceMethod(cellBaseCls, reuseSel)) {
            IMP orig = class_getMethodImplementation(cellBaseCls, reuseSel);
            if (ZLModReplaceMethod(cellBaseCls, reuseSel, 0, "v", ^(id selfObj) {
                ZLModCleanupAssociatedRecallLabelsInView((UIView *)selfObj);
                if (orig) ((void (*)(id, SEL))orig)(selfObj, reuseSel);
            })) {
                installed++;
            }
        }
    }

    // 4. MenuButton hooks for Chat Bubble "Hiện / Ẩn" in-place toggle (strictly non-mutating)
    Class menuBtnCls = NSClassFromString(@"MenuButton");
    if (menuBtnCls) {
        SEL showMenuSel = sel_registerName("showContextMenuViewWithMenuItemArray:hasReaction:");
        if (ZLModClassHasInstanceMethod(menuBtnCls, showMenuSel)) {
            IMP orig = class_getMethodImplementation(menuBtnCls, showMenuSel);
            if (ZLModReplaceMethod(menuBtnCls, showMenuSel, 2, "v", ^(id selfObj, id itemArray, BOOL hasReaction) {
                NSArray *finalArray = itemArray;
                @try {
                    if ([[ZLModPreferences shared] boolForKey:kZLModAntiRecall]) {
                        id chat = ZLModSafeObjectProperty(selfObj, sel_registerName("chatEntity"));
                        if (chat) {
                            ZLModMessageModel *m = [ZLModChatEntityAdapter modelFromChatEntity:chat fallbackThreadId:nil];
                            BOOL isRecalled = ZLModIsChatRecalled(chat);
                            BOOL isUnhidden = m ? ZLModIsMessageUnhidden(m.accountScope, m.threadId, m.globalId, m.clientId) : NO;

                            if (isRecalled || isUnhidden) {
                                NSMutableArray *mutableItems = [itemArray isKindOfClass:[NSArray class]]
                                    ? [itemArray mutableCopy]
                                    : [NSMutableArray array];

                                NSIndexSet *existing = [mutableItems indexesOfObjectsPassingTest:^BOOL(id obj, __unused NSUInteger idx, __unused BOOL *stop) {
                                    NSInteger mt = (NSInteger)ZLModSafeInt64Property(obj, sel_registerName("menuType"), 0);
                                    return (mt == kZLModActionUnhideRecall || mt == kZLModActionHideRecall);
                                }];
                                if (existing.count > 0) [mutableItems removeObjectsAtIndexes:existing];

                                id template = mutableItems.firstObject;
                                id menuItem = isUnhidden
                                    ? ZLModMakeRecallMenuItem(template, @"Ẩn", @"eye.slash", kZLModActionHideRecall)
                                    : ZLModMakeRecallMenuItem(template, @"Hiện", @"eye", kZLModActionUnhideRecall);
                                if (menuItem) [mutableItems insertObject:menuItem atIndex:0];
                                finalArray = mutableItems;
                            }
                        }
                    }
                } @catch (__unused NSException *e) {}

                if (orig) ((void (*)(id, SEL, id, BOOL))orig)(selfObj, showMenuSel, finalArray, hasReaction);
            })) {
                installed++;
            }
        }

        SEL tapSel = sel_registerName("contextMenuView:didTapAtItemType:");
        if (ZLModClassHasInstanceMethod(menuBtnCls, tapSel)) {
            IMP orig = class_getMethodImplementation(menuBtnCls, tapSel);
            if (ZLModReplaceMethod(menuBtnCls, tapSel, 2, "v", ^(id selfObj, id menuView, NSInteger itemType) {
                if (itemType == kZLModActionUnhideRecall) {
                    id chat = ZLModSafeObjectProperty(selfObj, sel_registerName("chatEntity"));
                    ZLModMessageModel *m = [ZLModChatEntityAdapter modelFromChatEntity:chat fallbackThreadId:nil];
                    int64_t gid = m ? m.globalId : 0;
                    int64_t cid = m ? m.clientId : 0;
                    NSString *tid = m ? m.threadId : nil;
                    NSString *scope = m.accountScope.length > 0 ? m.accountScope : ZLModCurrentAccountScope();

                    ZLModSetMessageUnhidden(scope, tid, gid, cid, YES);

                    NSString *decrypted = ZLModResolveRecalledText(chat, gid, cid);
                    UIImage *photo = [[ZLModAntiRecallStore shared] preservedPhotoForGlobalId:gid clientId:cid];
                    if (!photo) {
                        photo = [ZLModChatEntityAdapter extractPhotoImageFromChatEntity:chat];
                    }

                    NSString *displayText = decrypted.length > 0
                        ? decrypted
                        : (photo ? @"[Hình ảnh đã thu hồi]" : @"[Tin nhắn đã thu hồi]");

                    // Non-mutating in-place UI update + reloadCellIfNeed (never mutates ChatEntity properties/SQLite)
                    ZLModApplyRecallTextInPlace((UIView *)selfObj, displayText, YES);
                    if (chat) {
                        SEL reloadSel = sel_registerName("reloadCellIfNeed");
                        if ([chat respondsToSelector:reloadSel]) {
                            ((void (*)(id, SEL))objc_msgSend)(chat, reloadSel);
                        }
                    }

                    if (photo) {
                        NSString *senderLabel = (m.senderName.length > 0) ? m.senderName : @"Ảnh đã thu hồi";
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            UIViewController *top = ZLModTopPresenterViewController();
                            if (top) {
                                ZLModPhotoPreviewViewController *pvc = [[ZLModPhotoPreviewViewController alloc] init];
                                pvc.photo = photo;
                                pvc.senderName = senderLabel;
                                pvc.modalPresentationStyle = UIModalPresentationFullScreen;
                                [top presentViewController:pvc animated:YES completion:nil];
                            }
                        });
                    }

                    SEL dismissSel = sel_registerName("contextMenuViewWillDismiss:");
                    if ([selfObj respondsToSelector:dismissSel]) {
                        ((void (*)(id, SEL, id))objc_msgSend)(selfObj, dismissSel, menuView);
                    }
                    ZLModShowToast(@"Đã hiện tin nhắn");
                    return;
                }

                if (itemType == kZLModActionHideRecall) {
                    id chat = ZLModSafeObjectProperty(selfObj, sel_registerName("chatEntity"));
                    ZLModMessageModel *m = [ZLModChatEntityAdapter modelFromChatEntity:chat fallbackThreadId:nil];
                    int64_t gid = m ? m.globalId : 0;
                    int64_t cid = m ? m.clientId : 0;
                    NSString *tid = m ? m.threadId : nil;
                    NSString *scope = m.accountScope.length > 0 ? m.accountScope : ZLModCurrentAccountScope();

                    ZLModSetMessageUnhidden(scope, tid, gid, cid, NO);
                    ZLModApplyRecallTextInPlace((UIView *)selfObj, @"Tin nhắn đã được thu hồi", NO);

                    if (chat) {
                        SEL reloadSel = sel_registerName("reloadCellIfNeed");
                        if ([chat respondsToSelector:reloadSel]) {
                            ((void (*)(id, SEL))objc_msgSend)(chat, reloadSel);
                        }
                    }

                    SEL dismissSel = sel_registerName("contextMenuViewWillDismiss:");
                    if ([selfObj respondsToSelector:dismissSel]) {
                        ((void (*)(id, SEL, id))objc_msgSend)(selfObj, dismissSel, menuView);
                    }
                    ZLModShowToast(@"Đã ẩn tin nhắn");
                    return;
                }

                if (orig) ((void (*)(id, SEL, id, NSInteger))orig)(selfObj, tapSel, menuView, itemType);
            })) {
                installed++;
            }
        }
    }

    ZLModSetModuleStatus(@"AntiRecall",
                         (installed >= 2) ? ZLModModuleStatusHookInstalled : ZLModModuleStatusNotInstalled,
                         [NSString stringWithFormat:@"hooks=%lu", (unsigned long)installed]);
    ZLMOD_LOG(@"anti-recall installed (hooks=%lu)", (unsigned long)installed);
}
