// language: Objective-C, file: ZLModUtilities.m, target: iOS 15.1+ (Zalo 26.10.02 & 26.11.01, arm64)
// MODULE 08 — Messaging Utilities:
//   1. ZLModPrivateNotesStore: AES-256-CBC + HMAC-SHA256 per-conversation notes (v3 w/ encrypted titles),
//      non-blocking disk writes, fast metadata count, and multi-line modal UITextView editor.
//   2. ZLModQuickReplyStore: account-scoped templates (v2, migrates legacy flat array), deduplicated,
//      safe composer insertion (never auto-sends), plus 1-tap quick picker accessible from chat.
//   3. ZLModDelaySendManager: 5-state atomic FSM hooking ZAChatSendingManager -sendChat:checkUpload:
//      with multi-item live-countdown keyboard-aware Undo Banner, error feedback, and full timer cleanup.

#import "ZLMod.h"
#import <os/lock.h>
#import <math.h>

static const void *kZLModDelaySendBypassAssocKey = &kZLModDelaySendBypassAssocKey;
static const void *kZLModChatQuickReplyBtnAssocKey = &kZLModChatQuickReplyBtnAssocKey;
static const NSInteger kZLModQuickReplyBarBtnTag = 0x5A21;

#pragma mark - 1. ZLModPrivateNotesStore (Encrypted per-conversation notes, v3)

@interface ZLModPrivateNotesStore () {
    os_unfair_lock _lock;
}
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSDictionary *> *records;
@property (nonatomic, copy) NSString *storagePath;
@end

@implementation ZLModPrivateNotesStore

+ (instancetype)shared {
    static ZLModPrivateNotesStore *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ZLModPrivateNotesStore alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _records = [NSMutableDictionary dictionary];

        NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docs = paths.firstObject ?: NSTemporaryDirectory();
        _storagePath = [docs stringByAppendingPathComponent:@"ZLModNotes.plist"];

        [self loadFromDiskLocked];
    }
    return self;
}

+ (NSString *)compoundKeyForAccountScope:(NSString *)scope threadId:(NSString *)threadId {
    if (scope.length == 0 || threadId.length == 0) return nil;
    return [NSString stringWithFormat:@"%@:%@", scope, threadId];
}

+ (NSData *)metadataForAccountScope:(NSString *)scope threadId:(NSString *)threadId {
    NSString *bound = [NSString stringWithFormat:@"ZLModNote.v2|%@|%@", scope ?: @"", threadId ?: @""];
    return [bound dataUsingEncoding:NSUTF8StringEncoding];
}

+ (NSData *)titleMetadataForAccountScope:(NSString *)scope threadId:(NSString *)threadId {
    NSString *bound = [NSString stringWithFormat:@"ZLModNoteTitle.v3|%@|%@", scope ?: @"", threadId ?: @""];
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
        NSNumber *ver = plist[@"version"];
        NSDictionary *stored = plist[@"records"];
        if (![ver isKindOfClass:[NSNumber class]] ||
            (ver.integerValue != 2 && ver.integerValue != 3) ||
            ![stored isKindOfClass:[NSDictionary class]]) {
            return;
        }
        [stored enumerateKeysAndObjectsUsingBlock:^(id key, id obj, __unused BOOL *stop) {
            if ([key isKindOfClass:[NSString class]] && [obj isKindOfClass:[NSDictionary class]]) {
                self.records[(NSString *)key] = (NSDictionary *)obj;
            }
        }];
    } @catch (__unused NSException *e) {
        ZLMOD_LOG(@"notes: exception loading plist");
    }
}

- (NSDictionary *)immutableSnapshotLocked {
    return @{
        @"version": @3,
        @"records": [self.records copy]
    };
}

- (NSString *)noteForThreadId:(NSString *)threadId {
    NSString *scope = ZLModCurrentAccountScope();
    NSString *key = [[self class] compoundKeyForAccountScope:scope threadId:threadId];
    if (!key) return nil;

    os_unfair_lock_lock(&_lock);
    NSDictionary *rec = self.records[key];
    os_unfair_lock_unlock(&_lock);
    if (!rec) return nil;

    NSData *cipher = rec[@"cipher"];
    if (![cipher isKindOfClass:[NSData class]]) return nil;
    NSData *meta = [[self class] metadataForAccountScope:scope threadId:threadId];
    return [[ZLModCryptoBox shared] decryptData:cipher metadata:meta];
}

- (BOOL)setNote:(NSString *)note forThreadId:(NSString *)threadId {
    return [self setNote:note displayTitle:nil forThreadId:threadId];
}

- (BOOL)setNote:(NSString *)note displayTitle:(NSString *)displayTitle forThreadId:(NSString *)threadId {
    NSString *trimmed = [note isKindOfClass:[NSString class]]
        ? [note stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
        : @"";
    if (trimmed.length == 0) {
        return [self removeNoteForThreadId:threadId];
    }

    NSString *scope = ZLModCurrentAccountScope();
    NSString *key = [[self class] compoundKeyForAccountScope:scope threadId:threadId];
    if (!key) return NO;

    NSData *meta = [[self class] metadataForAccountScope:scope threadId:threadId];
    NSData *cipher = [[ZLModCryptoBox shared] encryptString:trimmed metadata:meta];
    if (!cipher) return NO;

    NSData *titleCipher = nil;
    if (displayTitle.length > 0 && ![displayTitle isEqualToString:@"Cuộc trò chuyện"]) {
        NSData *tMeta = [[self class] titleMetadataForAccountScope:scope threadId:threadId];
        titleCipher = [[ZLModCryptoBox shared] encryptString:displayTitle metadata:tMeta];
    }

    NSMutableDictionary *record = [NSMutableDictionary dictionaryWithDictionary:@{
        @"accountScope": scope,
        @"threadId": [threadId copy],
        @"threadHash": ZLModSafeIdHash(threadId),
        @"updatedAt": @([[NSDate date] timeIntervalSince1970]),
        @"cipher": cipher
    }];

    NSDictionary *snapshot = nil;
    os_unfair_lock_lock(&_lock);
    NSDictionary *existing = self.records[key];
    if (titleCipher) {
        record[@"titleCipher"] = titleCipher;
    } else if ([existing[@"titleCipher"] isKindOfClass:[NSData class]]) {
        record[@"titleCipher"] = existing[@"titleCipher"];
    }
    self.records[key] = [record copy];
    snapshot = [self immutableSnapshotLocked];
    os_unfair_lock_unlock(&_lock);

    ZLModWritePropertyListAsync(snapshot, self.storagePath, nil);
    return YES;
}

- (BOOL)removeNoteForThreadId:(NSString *)threadId {
    NSString *scope = ZLModCurrentAccountScope();
    NSString *key = [[self class] compoundKeyForAccountScope:scope threadId:threadId];
    if (!key) return NO;

    NSDictionary *snapshot = nil;
    os_unfair_lock_lock(&_lock);
    if (self.records[key]) {
        [self.records removeObjectForKey:key];
        snapshot = [self immutableSnapshotLocked];
    }
    os_unfair_lock_unlock(&_lock);

    if (snapshot) {
        ZLModWritePropertyListAsync(snapshot, self.storagePath, nil);
    }
    return YES;
}

- (NSUInteger)countForCurrentAccount {
    NSString *scope = ZLModCurrentAccountScope();
    if (scope.length == 0) return 0;
    NSString *prefix = [scope stringByAppendingString:@":"];

    __block NSUInteger count = 0;
    os_unfair_lock_lock(&_lock);
    [self.records enumerateKeysAndObjectsUsingBlock:^(NSString *key, __unused NSDictionary *rec, __unused BOOL *stop) {
        if ([key hasPrefix:prefix]) count++;
    }];
    os_unfair_lock_unlock(&_lock);
    return count;
}

- (NSArray<NSDictionary<NSString *, NSString *> *> *)allEntriesForCurrentAccount {
    NSString *scope = ZLModCurrentAccountScope();
    if (scope.length == 0) return @[];
    NSString *prefix = [scope stringByAppendingString:@":"];

    NSMutableArray<NSDictionary *> *rawList = [NSMutableArray array];
    os_unfair_lock_lock(&_lock);
    [self.records enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSDictionary *rec, __unused BOOL *stop) {
        if ([key hasPrefix:prefix]) [rawList addObject:rec];
    }];
    os_unfair_lock_unlock(&_lock);

    [rawList sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [(b[@"updatedAt"] ?: @0) compare:(a[@"updatedAt"] ?: @0)];
    }];

    NSMutableArray<NSDictionary<NSString *, NSString *> *> *results = [NSMutableArray array];
    for (NSDictionary *rec in rawList) {
        NSString *tid = rec[@"threadId"];
        NSData *cipher = rec[@"cipher"];
        if (![tid isKindOfClass:[NSString class]] || ![cipher isKindOfClass:[NSData class]]) continue;
        NSData *meta = [[self class] metadataForAccountScope:scope threadId:tid];
        NSString *note = [[ZLModCryptoBox shared] decryptData:cipher metadata:meta];
        if (note.length == 0) continue;

        NSString *title = @"";
        NSData *tCipher = rec[@"titleCipher"];
        if ([tCipher isKindOfClass:[NSData class]]) {
            NSData *tMeta = [[self class] titleMetadataForAccountScope:scope threadId:tid];
            title = [[ZLModCryptoBox shared] decryptData:tCipher metadata:tMeta] ?: @"";
        }
        [results addObject:@{
            @"threadId": tid,
            @"threadHash": rec[@"threadHash"] ?: ZLModSafeIdHash(tid),
            @"displayTitle": title,
            @"note": note
        }];
    }
    return [results copy];
}

- (void)clearCurrentAccountNotes {
    NSString *scope = ZLModCurrentAccountScope();
    if (scope.length == 0) return;
    NSString *prefix = [scope stringByAppendingString:@":"];

    NSDictionary *snapshot = nil;
    os_unfair_lock_lock(&_lock);
    NSMutableArray<NSString *> *toRemove = [NSMutableArray array];
    for (NSString *k in self.records) {
        if ([k hasPrefix:prefix]) [toRemove addObject:k];
    }
    if (toRemove.count > 0) {
        [self.records removeObjectsForKeys:toRemove];
        snapshot = [self immutableSnapshotLocked];
    }
    os_unfair_lock_unlock(&_lock);

    if (snapshot) {
        ZLModWritePropertyListAsync(snapshot, self.storagePath, nil);
    }
}

@end

#pragma mark - Multi-line Private Note Editor View Controller

@interface ZLModPrivateNoteEditorViewController : UIViewController
@property (nonatomic, copy) NSString *threadId;
@property (nonatomic, copy) NSString *displayTitle;
@property (nonatomic, copy) void (^completionBlock)(BOOL saved);
@property (nonatomic, strong) UILabel *subtitleLabel;
@property (nonatomic, strong) UITextView *textView;
@property (nonatomic, strong) UIButton *deleteButton;
@property (nonatomic, assign) BOOL hasExistingNote;
@end

@implementation ZLModPrivateNoteEditorViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Ghi chú riêng tư";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                      target:self
                                                      action:@selector(cancelTapped)];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemSave
                                                      target:self
                                                      action:@selector(saveTapped)];

    NSString *existing = [[ZLModPrivateNotesStore shared] noteForThreadId:self.threadId] ?: @"";
    self.hasExistingNote = (existing.length > 0);

    self.subtitleLabel = [[UILabel alloc] init];
    self.subtitleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.subtitleLabel.adjustsFontForContentSizeCategory = YES;
    self.subtitleLabel.textColor = [UIColor secondaryLabelColor];
    self.subtitleLabel.numberOfLines = 2;
    self.subtitleLabel.text = (self.displayTitle.length > 0)
        ? [NSString stringWithFormat:@"Hội thoại: %@ (%@) • Mã hóa AES-256 cục bộ", self.displayTitle, ZLModSafeIdHash(self.threadId)]
        : [NSString stringWithFormat:@"Hội thoại: %@ • Mã hóa AES-256 cục bộ", ZLModSafeIdHash(self.threadId)];
    [self.view addSubview:self.subtitleLabel];

    self.textView = [[UITextView alloc] init];
    self.textView.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.textView.adjustsFontForContentSizeCategory = YES;
    self.textView.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
    self.textView.textColor = [UIColor labelColor];
    self.textView.layer.cornerRadius = 12.0;
    self.textView.textContainerInset = UIEdgeInsetsMake(12.0, 12.0, 12.0, 12.0);
    self.textView.text = existing;
    self.textView.accessibilityLabel = @"Nội dung ghi chú riêng tư nhiều dòng";
    [self.view addSubview:self.textView];

    if (self.hasExistingNote) {
        self.deleteButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [self.deleteButton setTitle:@"Xóa ghi chú này" forState:UIControlStateNormal];
        [self.deleteButton setTitleColor:[UIColor systemRedColor] forState:UIControlStateNormal];
        self.deleteButton.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCallout];
        self.deleteButton.titleLabel.adjustsFontForContentSizeCategory = YES;
        [self.deleteButton addTarget:self action:@selector(deleteTapped) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:self.deleteButton];
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self.textView becomeFirstResponder];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w = self.view.bounds.size.width;
    CGFloat h = self.view.bounds.size.height;
    CGFloat topY = self.view.safeAreaInsets.top + 12.0;
    CGFloat pad = 16.0;
    CGFloat contentW = MAX(w - pad * 2.0, 120.0);

    CGSize subSize = [self.subtitleLabel sizeThatFits:CGSizeMake(contentW, 48.0)];
    self.subtitleLabel.frame = CGRectMake(pad, topY, contentW, MAX(subSize.height, 20.0));

    CGFloat delH = self.deleteButton ? 44.0 : 0.0;
    CGFloat tvTop = CGRectGetMaxY(self.subtitleLabel.frame) + 10.0;
    CGFloat tvH = MIN(MAX(h - tvTop - delH - self.view.safeAreaInsets.bottom - 24.0, 160.0), 320.0);
    self.textView.frame = CGRectMake(pad, tvTop, contentW, tvH);

    if (self.deleteButton) {
        self.deleteButton.frame = CGRectMake(pad, CGRectGetMaxY(self.textView.frame) + 10.0, contentW, 44.0);
    }
}

- (void)cancelTapped {
    void (^cb)(BOOL) = self.completionBlock;
    [self dismissViewControllerAnimated:YES completion:^{
        if (cb) cb(NO);
    }];
}

- (void)saveTapped {
    OSStatus kcStatus = errSecSuccess;
    ZLModStorageHealthState health = ZLModCurrentStorageHealth(&kcStatus);
    if (health != ZLModStorageHealthReady) {
        ZLModShowToast([NSString stringWithFormat:@"Không thể lưu ghi chú: %@", ZLModStorageHealthDescription()]);
        return;
    }

    NSString *text = self.textView.text ?: @"";
    BOOL ok = [[ZLModPrivateNotesStore shared] setNote:text displayTitle:self.displayTitle forThreadId:self.threadId];
    if (!ok) {
        ZLModShowToast(@"Lưu ghi chú thất bại — kiểm tra Keychain hoặc tài khoản");
        return;
    }
    void (^cb)(BOOL) = self.completionBlock;
    [self dismissViewControllerAnimated:YES completion:^{
        if (cb) cb(YES);
    }];
}

- (void)deleteTapped {
    BOOL ok = [[ZLModPrivateNotesStore shared] removeNoteForThreadId:self.threadId];
    void (^cb)(BOOL) = self.completionBlock;
    [self dismissViewControllerAnimated:YES completion:^{
        if (cb) cb(ok);
    }];
}

@end

void ZLModPresentPrivateNoteEditor(UIViewController *presenter,
                                   NSString *threadId,
                                   NSString *displayTitle,
                                   void (^completion)(BOOL saved)) {
    if (!presenter || threadId.length == 0) {
        if (completion) completion(NO);
        return;
    }
    ZLModRunOnMainThread(^{
        OSStatus st = errSecSuccess;
        if (ZLModCurrentStorageHealth(&st) != ZLModStorageHealthReady) {
            ZLModShowToast([NSString stringWithFormat:@"Kho mã hóa chưa sẵn sàng: %@", ZLModStorageHealthDescription()]);
            if (completion) completion(NO);
            return;
        }
        ZLModPrivateNoteEditorViewController *editor = [[ZLModPrivateNoteEditorViewController alloc] init];
        editor.threadId = threadId;
        editor.displayTitle = displayTitle;
        editor.completionBlock = completion;
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:editor];
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
        [presenter presentViewController:nav animated:YES completion:nil];
    });
}

#pragma mark - 2. ZLModQuickReplyStore (Account-scoped template manager + safe composer insert)

@interface ZLModQuickReplyStore () {
    os_unfair_lock _lock;
}
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *templatesByAccount;
@property (nonatomic, strong) NSArray<NSString *> *legacySeedTemplates;
@property (nonatomic, copy) NSString *storagePath;
@end

@implementation ZLModQuickReplyStore

+ (instancetype)shared {
    static ZLModQuickReplyStore *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ZLModQuickReplyStore alloc] init];
    });
    return instance;
}

+ (NSArray<NSString *> *)defaultTemplates {
    return @[
        @"Mình đang bận một chút, lát mình nhắn lại nhé!",
        @"Đã nhận thông tin, cảm ơn bạn nhé.",
        @"Ok bạn, để mình kiểm tra rồi phản hồi ngay."
    ];
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _templatesByAccount = [NSMutableDictionary dictionary];

        NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *docs = paths.firstObject ?: NSTemporaryDirectory();
        _storagePath = [docs stringByAppendingPathComponent:@"ZLModQuickReplies.plist"];

        [self loadFromDiskLocked];
    }
    return self;
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
        // Legacy v1 flat array migration: keep as initial seed for the active account.
        if ([plist isKindOfClass:[NSArray class]]) {
            NSMutableArray<NSString *> *seed = [NSMutableArray array];
            for (id item in (NSArray *)plist) {
                if ([item isKindOfClass:[NSString class]] && [(NSString *)item length] > 0 && ![seed containsObject:item]) {
                    [seed addObject:item];
                }
            }
            self.legacySeedTemplates = [seed copy];
            return;
        }
        if ([plist isKindOfClass:[NSDictionary class]]) {
            NSNumber *ver = plist[@"version"];
            NSDictionary *accounts = plist[@"accounts"];
            if ([ver isKindOfClass:[NSNumber class]] && ver.integerValue == 2 &&
                [accounts isKindOfClass:[NSDictionary class]]) {
                [accounts enumerateKeysAndObjectsUsingBlock:^(id scopeKey, id arrObj, __unused BOOL *stop) {
                    if ([scopeKey isKindOfClass:[NSString class]] && [arrObj isKindOfClass:[NSArray class]]) {
                        NSMutableArray<NSString *> *clean = [NSMutableArray array];
                        for (id item in (NSArray *)arrObj) {
                            if ([item isKindOfClass:[NSString class]] && [(NSString *)item length] > 0 && ![clean containsObject:item]) {
                                [clean addObject:item];
                            }
                        }
                        self.templatesByAccount[(NSString *)scopeKey] = clean;
                    }
                }];
            }
        }
    } @catch (__unused NSException *e) {
        ZLMOD_LOG(@"quickreply: exception loading plist");
    }
}

- (NSDictionary *)immutableSnapshotLocked {
    NSMutableDictionary *accounts = [NSMutableDictionary dictionaryWithCapacity:self.templatesByAccount.count];
    [self.templatesByAccount enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSMutableArray<NSString *> *v, __unused BOOL *stop) {
        accounts[k] = [v copy];
    }];
    return @{
        @"version": @2,
        @"accounts": [accounts copy]
    };
}

- (NSMutableArray<NSString *> *)bucketLockedForScope:(NSString *)scope createIfMissing:(BOOL)create {
    if (scope.length == 0) return nil;
    NSMutableArray<NSString *> *list = self.templatesByAccount[scope];
    if (!list && create) {
        NSArray<NSString *> *seed = (self.legacySeedTemplates.count > 0)
            ? self.legacySeedTemplates
            : [[self class] defaultTemplates];
        list = [seed mutableCopy];
        self.templatesByAccount[scope] = list;
        self.legacySeedTemplates = nil;
    }
    return list;
}

- (NSArray<NSString *> *)quickReplies {
    NSString *scope = ZLModCurrentAccountScope();
    if (scope.length == 0) return @[];

    NSDictionary *migratedSnapshot = nil;
    os_unfair_lock_lock(&_lock);
    BOOL neededCreate = (self.templatesByAccount[scope] == nil);
    NSMutableArray<NSString *> *bucket = [self bucketLockedForScope:scope createIfMissing:YES];
    NSArray<NSString *> *copy = bucket ? [bucket copy] : @[];
    if (neededCreate && bucket) {
        migratedSnapshot = [self immutableSnapshotLocked];
    }
    os_unfair_lock_unlock(&_lock);

    if (migratedSnapshot) {
        ZLModWritePropertyListAsync(migratedSnapshot, self.storagePath, nil);
    }
    return copy;
}

- (BOOL)addQuickReply:(NSString *)text {
    NSString *scope = ZLModCurrentAccountScope();
    if (scope.length == 0) return NO;
    NSString *trimmed = [text isKindOfClass:[NSString class]]
        ? [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
        : @"";
    if (trimmed.length == 0) return NO;

    BOOL added = NO;
    NSDictionary *snapshot = nil;
    os_unfair_lock_lock(&_lock);
    NSMutableArray<NSString *> *bucket = [self bucketLockedForScope:scope createIfMissing:YES];
    if (bucket && bucket.count < kZLModMaxQuickRepliesCount && ![bucket containsObject:trimmed]) {
        [bucket addObject:trimmed];
        snapshot = [self immutableSnapshotLocked];
        added = YES;
    }
    os_unfair_lock_unlock(&_lock);

    if (snapshot) ZLModWritePropertyListAsync(snapshot, self.storagePath, nil);
    return added;
}

- (BOOL)updateQuickReplyAtIndex:(NSUInteger)index withText:(NSString *)text {
    NSString *scope = ZLModCurrentAccountScope();
    if (scope.length == 0) return NO;
    NSString *trimmed = [text isKindOfClass:[NSString class]]
        ? [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
        : @"";
    if (trimmed.length == 0) return NO;

    BOOL updated = NO;
    NSDictionary *snapshot = nil;
    os_unfair_lock_lock(&_lock);
    NSMutableArray<NSString *> *bucket = [self bucketLockedForScope:scope createIfMissing:YES];
    if (bucket && index < bucket.count) {
        NSUInteger dupIdx = [bucket indexOfObject:trimmed];
        if (dupIdx == NSNotFound || dupIdx == index) {
            bucket[index] = trimmed;
            snapshot = [self immutableSnapshotLocked];
            updated = YES;
        }
    }
    os_unfair_lock_unlock(&_lock);

    if (snapshot) ZLModWritePropertyListAsync(snapshot, self.storagePath, nil);
    return updated;
}

- (BOOL)removeQuickReplyAtIndex:(NSUInteger)index {
    NSString *scope = ZLModCurrentAccountScope();
    if (scope.length == 0) return NO;

    BOOL removed = NO;
    NSDictionary *snapshot = nil;
    os_unfair_lock_lock(&_lock);
    NSMutableArray<NSString *> *bucket = [self bucketLockedForScope:scope createIfMissing:YES];
    if (bucket && index < bucket.count) {
        [bucket removeObjectAtIndex:index];
        snapshot = [self immutableSnapshotLocked];
        removed = YES;
    }
    os_unfair_lock_unlock(&_lock);

    if (snapshot) ZLModWritePropertyListAsync(snapshot, self.storagePath, nil);
    return removed;
}

- (BOOL)moveQuickReplyFromIndex:(NSUInteger)fromIndex toIndex:(NSUInteger)toIndex {
    NSString *scope = ZLModCurrentAccountScope();
    if (scope.length == 0) return NO;

    BOOL moved = NO;
    NSDictionary *snapshot = nil;
    os_unfair_lock_lock(&_lock);
    NSMutableArray<NSString *> *bucket = [self bucketLockedForScope:scope createIfMissing:YES];
    if (bucket && fromIndex < bucket.count && toIndex < bucket.count && fromIndex != toIndex) {
        NSString *item = bucket[fromIndex];
        [bucket removeObjectAtIndex:fromIndex];
        [bucket insertObject:item atIndex:toIndex];
        snapshot = [self immutableSnapshotLocked];
        moved = YES;
    }
    os_unfair_lock_unlock(&_lock);

    if (snapshot) ZLModWritePropertyListAsync(snapshot, self.storagePath, nil);
    return moved;
}

- (void)resetDefaults {
    NSString *scope = ZLModCurrentAccountScope();
    if (scope.length == 0) return;

    NSDictionary *snapshot = nil;
    os_unfair_lock_lock(&_lock);
    self.templatesByAccount[scope] = [[[self class] defaultTemplates] mutableCopy];
    snapshot = [self immutableSnapshotLocked];
    os_unfair_lock_unlock(&_lock);

    ZLModWritePropertyListAsync(snapshot, self.storagePath, nil);
}

static UIView *ZLModFindFirstResponderInView(UIView *root) {
    if (!root) return nil;
    if (root.isFirstResponder) return root;
    for (UIView *sub in root.subviews) {
        UIView *found = ZLModFindFirstResponderInView(sub);
        if (found) return found;
    }
    return nil;
}

- (BOOL)insertTemplateIntoComposer:(NSString *)text {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return NO;

    __block BOOL inserted = NO;
    ZLModRunOnMainThreadSync(^{
        // 1. Active BaseChatTVC -fillChatBarWithText: [v24@0:8@16] (NEVER auto-sends)
        id activeChat = [ZLModPrivacyContext activeChatController];
        SEL fillSel = sel_registerName("fillChatBarWithText:");
        if (activeChat && [activeChat respondsToSelector:fillSel]) {
            Method m = class_getInstanceMethod(object_getClass(activeChat), fillSel);
            if (m && method_getNumberOfArguments(m) == 3) {
                @try {
                    ((void (*)(id, SEL, id))objc_msgSend)(activeChat, fillSel, text);
                    inserted = YES;
                    return;
                } @catch (__unused NSException *e) {}
            }
        }

        // 2. Fallback: active firstResponder UITextView or UITextField
        UIWindow *win = ZLModActiveKeyWindow();
        UIView *responder = ZLModFindFirstResponderInView(win);
        if ([responder isKindOfClass:[UITextView class]]) {
            UITextView *tv = (UITextView *)responder;
            if (tv.isEditable) {
                tv.text = (tv.text.length > 0) ? [tv.text stringByAppendingFormat:@" %@", text] : text;
                if ([tv.delegate respondsToSelector:@selector(textViewDidChange:)]) {
                    [tv.delegate textViewDidChange:tv];
                }
                inserted = YES;
                return;
            }
        } else if ([responder isKindOfClass:[UITextField class]]) {
            UITextField *tf = (UITextField *)responder;
            tf.text = (tf.text.length > 0) ? [tf.text stringByAppendingFormat:@" %@", text] : text;
            [tf sendActionsForControlEvents:UIControlEventEditingChanged];
            inserted = YES;
            return;
        }
    });
    return inserted;
}

@end

#pragma mark - In-Chat Quick Reply Picker Entry

@interface ZLModChatQuickReplyTrigger : NSObject
@property (nonatomic, weak) UIViewController *chatVC;
- (void)openPicker:(id)sender;
@end

@implementation ZLModChatQuickReplyTrigger
- (void)openPicker:(__unused id)sender {
    UIViewController *host = self.chatVC ?: ZLModTopPresenterViewController();
    if (host) {
        ZLModPresentQuickReplyPicker(host);
    }
}
@end

void ZLModPresentQuickReplyPicker(UIViewController *presenter) {
    if (!presenter) return;
    ZLModRunOnMainThread(^{
        if (ZLModCurrentAccountScope().length == 0) {
            ZLModShowToast(@"Chưa xác định tài khoản Zalo — không thể mở Mẫu trả lời nhanh");
            return;
        }
        NSArray<NSString *> *templates = [[ZLModQuickReplyStore shared] quickReplies];
        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Trả lời nhanh (Chỉ chèn vào ô nhập)"
                                                                       message:templates.count > 0 ? nil : @"Chưa có mẫu câu nào. Thêm trong ZLMod Customize."
                                                                preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSString *tpl in templates) {
            [sheet addAction:[UIAlertAction actionWithTitle:tpl
                                                      style:UIAlertActionStyleDefault
                                                    handler:^(__unused UIAlertAction *action) {
                if ([[ZLModQuickReplyStore shared] insertTemplateIntoComposer:tpl]) {
                    ZLModShowToast(@"Đã điền vào khung nhập tin nhắn");
                } else {
                    [UIPasteboard generalPasteboard].string = tpl;
                    ZLModShowToast(@"Đã sao chép mẫu câu vào bộ nhớ tạm");
                }
            }]];
        }
        [sheet addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
        if (sheet.popoverPresentationController) {
            sheet.popoverPresentationController.sourceView = presenter.view;
            sheet.popoverPresentationController.sourceRect = CGRectMake(presenter.view.bounds.size.width * 0.5,
                                                                        presenter.view.bounds.size.height - 60.0,
                                                                        1.0, 1.0);
        }
        [presenter presentViewController:sheet animated:YES completion:nil];
    });
}

static void ZLModAttachQuickReplyButtonToChatVC(UIViewController *vc) {
    if (![vc isKindOfClass:[UIViewController class]]) return;
    UINavigationItem *navItem = vc.navigationItem;
    if (!navItem) return;
    for (UIBarButtonItem *item in navItem.rightBarButtonItems) {
        if (item.tag == kZLModQuickReplyBarBtnTag) return;
    }

    ZLModChatQuickReplyTrigger *trigger = [[ZLModChatQuickReplyTrigger alloc] init];
    trigger.chatVC = vc;
    objc_setAssociatedObject(vc, kZLModChatQuickReplyBtnAssocKey, trigger, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIImage *icon = [UIImage systemImageNamed:@"text.bubble"];
    UIBarButtonItem *btn = icon
        ? [[UIBarButtonItem alloc] initWithImage:icon style:UIBarButtonItemStylePlain target:trigger action:@selector(openPicker:)]
        : [[UIBarButtonItem alloc] initWithTitle:@"QR" style:UIBarButtonItemStylePlain target:trigger action:@selector(openPicker:)];
    btn.tag = kZLModQuickReplyBarBtnTag;
    btn.accessibilityLabel = @"Mẫu trả lời nhanh ZLMod";
    btn.accessibilityIdentifier = @"zlmod.chat.quickreply";

    NSMutableArray<UIBarButtonItem *> *items = navItem.rightBarButtonItems
        ? [navItem.rightBarButtonItems mutableCopy]
        : [NSMutableArray array];
    [items addObject:btn];
    navItem.rightBarButtonItems = [items copy];
}

#pragma mark - 3. ZLModDelaySendManager (5-state atomic FSM + Multi-Item Keyboard-Aware Live Banner)

@interface ZLModPendingSendItem : NSObject
@property (nonatomic, copy) NSString *sendId;
@property (nonatomic, assign) ZLModDelaySendState state;
@property (nonatomic, weak) id senderManager;
@property (nonatomic, strong) id chatEntity;
@property (nonatomic, assign) BOOL checkUpload;
@property (nonatomic, copy) NSString *targetHash;
@property (nonatomic, assign) NSTimeInterval fireTime;
@property (nonatomic, strong) dispatch_source_t timer;
@end

@implementation ZLModPendingSendItem
@end

@interface ZLModDelaySendManager () {
    os_unfair_lock _lock;
}
@property (nonatomic, strong) NSMutableDictionary<NSString *, ZLModPendingSendItem *> *items;
@property (nonatomic, strong) NSMutableArray<NSString *> *sendOrder;
@property (nonatomic, assign) IMP origSendChatIMP;
@property (nonatomic, strong) dispatch_source_t bannerTickTimer;
@property (nonatomic, assign) CGFloat keyboardOverlapHeight;
- (void)enqueueSendFromManager:(id)manager
                    chatEntity:(id)chatEntity
                   checkUpload:(BOOL)checkUpload
                       origIMP:(IMP)origIMP;
@end

@implementation ZLModDelaySendManager

+ (instancetype)shared {
    static ZLModDelaySendManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ZLModDelaySendManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _items = [NSMutableDictionary dictionary];
        _sendOrder = [NSMutableArray array];
        _keyboardOverlapHeight = 0.0;

        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserverForName:UIApplicationDidEnterBackgroundNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *note) {
            [self cancelAllPendingSendsWithReason:@"app_backgrounded"];
        }];
        [nc addObserverForName:UIApplicationWillTerminateNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *note) {
            [self cancelAllPendingSendsWithReason:@"app_terminated"];
        }];
        [nc addObserverForName:ZLModAccountDidChangeNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *note) {
            [self cancelAllPendingSendsWithReason:@"account_changed"];
        }];
        [nc addObserverForName:ZLModPrefsDidChangeNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
            NSString *k = [note.object isKindOfClass:[NSString class]] ? (NSString *)note.object : @"";
            if ([k isEqualToString:kZLModDelaySend] || [k isEqualToString:@"*"]) {
                if (![[ZLModPreferences shared] boolForKey:kZLModDelaySend]) {
                    [self cancelAllPendingSendsWithReason:@"feature_disabled"];
                }
            }
        }];
        [nc addObserverForName:UIKeyboardWillChangeFrameNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
            NSValue *frameVal = note.userInfo[UIKeyboardFrameEndUserInfoKey];
            if ([frameVal isKindOfClass:[NSValue class]]) {
                CGRect kbFrame = [frameVal CGRectValue];
                UIWindow *win = ZLModActiveKeyWindow();
                CGFloat overlap = win ? MAX(0.0, win.bounds.size.height - kbFrame.origin.y) : 0.0;
                self.keyboardOverlapHeight = overlap;
                [self refreshUndoBannerOnMain];
            }
        }];
        [nc addObserverForName:UIKeyboardWillHideNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(__unused NSNotification *note) {
            self.keyboardOverlapHeight = 0.0;
            [self refreshUndoBannerOnMain];
        }];
    }
    return self;
}

- (NSTimeInterval)delayDuration {
    double val = [[ZLModPreferences shared] doubleForKey:kZLModDelaySendSeconds defaultValue:kZLModDelaySendDefaultSeconds];
    if (val < kZLModDelaySendMinSeconds) return kZLModDelaySendMinSeconds;
    if (val > kZLModDelaySendMaxSeconds) return kZLModDelaySendMaxSeconds;
    return val;
}

- (void)setDelayDuration:(NSTimeInterval)seconds {
    double clamped = seconds;
    if (clamped < kZLModDelaySendMinSeconds) clamped = kZLModDelaySendMinSeconds;
    if (clamped > kZLModDelaySendMaxSeconds) clamped = kZLModDelaySendMaxSeconds;
    [[ZLModPreferences shared] setDouble:clamped forKey:kZLModDelaySendSeconds];
}

- (NSUInteger)pendingCount {
    NSUInteger count = 0;
    os_unfair_lock_lock(&_lock);
    for (NSString *sid in self.items) {
        if (self.items[sid].state == ZLModDelaySendStatePending) count++;
    }
    os_unfair_lock_unlock(&_lock);
    return count;
}

- (void)enqueueSendFromManager:(id)manager
                    chatEntity:(id)chatEntity
                   checkUpload:(BOOL)checkUpload
                       origIMP:(IMP)origIMP {
    SEL sendSel = sel_registerName("sendChat:checkUpload:");
    if (!manager || !chatEntity || !origIMP) {
        if (origIMP && manager) {
            ((void (*)(id, SEL, id, BOOL))origIMP)(manager, sendSel, chatEntity, checkUpload);
        }
        return;
    }

    NSNumber *bypass = objc_getAssociatedObject(chatEntity, kZLModDelaySendBypassAssocKey);
    if ([bypass boolValue] || ![[ZLModPreferences shared] boolForKey:kZLModDelaySend]) {
        objc_setAssociatedObject(chatEntity, kZLModDelaySendBypassAssocKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        ((void (*)(id, SEL, id, BOOL))origIMP)(manager, sendSel, chatEntity, checkUpload);
        return;
    }

    NSTimeInterval delay = [self delayDuration];
    NSString *sendId = [[NSUUID UUID] UUIDString];
    NSString *targetId = [ZLModChatEntityAdapter extractThreadIdFromObject:chatEntity];

    ZLModPendingSendItem *item = [[ZLModPendingSendItem alloc] init];
    item.sendId = sendId;
    item.state = ZLModDelaySendStatePending;
    item.senderManager = manager;
    item.chatEntity = chatEntity;
    item.checkUpload = checkUpload;
    item.targetHash = ZLModSafeIdHash(targetId);
    item.fireTime = [[NSDate date] timeIntervalSince1970] + delay;

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    item.timer = timer;

    os_unfair_lock_lock(&_lock);
    self.origSendChatIMP = origIMP;
    self.items[sendId] = item;
    [self.sendOrder addObject:sendId];
    os_unfair_lock_unlock(&_lock);

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER,
                              (uint64_t)(50 * NSEC_PER_MSEC));
    dispatch_source_set_event_handler(timer, ^{
        [weakSelf timerFiredForSendId:sendId];
    });
    dispatch_resume(timer);

    ZLMOD_LOG(@"delaysend: queued sendId=%@ target=%@ delay=%.1fs", sendId, item.targetHash, delay);

    ZLModRunOnMainThread(^{
        [self startBannerTickTimerIfNeeded];
        [self refreshUndoBannerOnMain];
    });
}

- (void)timerFiredForSendId:(NSString *)sendId {
    if (sendId.length == 0) return;

    ZLModPendingSendItem *item = nil;
    IMP origIMP = NULL;

    os_unfair_lock_lock(&_lock);
    ZLModPendingSendItem *candidate = self.items[sendId];
    if (candidate && candidate.state == ZLModDelaySendStatePending) {
        candidate.state = ZLModDelaySendStateDispatching;
        item = candidate;
        origIMP = self.origSendChatIMP;
    }
    os_unfair_lock_unlock(&_lock);

    if (!item) return;

    if (item.timer) {
        dispatch_source_cancel(item.timer);
        item.timer = nil;
    }

    id manager = item.senderManager;
    id chat = item.chatEntity;
    SEL sendSel = sel_registerName("sendChat:checkUpload:");

    BOOL dispatchedOK = NO;
    if (manager && chat && origIMP) {
        @try {
            objc_setAssociatedObject(chat, kZLModDelaySendBypassAssocKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            ((void (*)(id, SEL, id, BOOL))origIMP)(manager, sendSel, chat, item.checkUpload);
            dispatchedOK = YES;
        } @catch (NSException *e) {
            objc_setAssociatedObject(chat, kZLModDelaySendBypassAssocKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            ZLMOD_LOG(@"delaysend: dispatch threw exception (%@)", e.reason ?: @"unknown");
            dispatchedOK = NO;
        }
    }

    os_unfair_lock_lock(&_lock);
    item.state = dispatchedOK ? ZLModDelaySendStateDispatched : ZLModDelaySendStateFailed;
    [self.items removeObjectForKey:sendId];
    [self.sendOrder removeObject:sendId];
    os_unfair_lock_unlock(&_lock);

    if (!dispatchedOK) {
        ZLModShowToast(@"Gửi tin nhắn thất bại — vui lòng thử lại");
    }

    ZLModRunOnMainThread(^{
        [self refreshUndoBannerOnMain];
    });
}

- (BOOL)cancelPendingSendWithId:(NSString *)sendId {
    if (sendId.length == 0) return NO;

    ZLModPendingSendItem *cancelledItem = nil;
    os_unfair_lock_lock(&_lock);
    ZLModPendingSendItem *item = self.items[sendId];
    if (item && item.state == ZLModDelaySendStatePending) {
        item.state = ZLModDelaySendStateCancelled;
        cancelledItem = item;
        [self.items removeObjectForKey:sendId];
        [self.sendOrder removeObject:sendId];
    }
    os_unfair_lock_unlock(&_lock);

    if (!cancelledItem) return NO;

    if (cancelledItem.timer) {
        dispatch_source_cancel(cancelledItem.timer);
        cancelledItem.timer = nil;
    }
    ZLMOD_LOG(@"delaysend: cancelled sendId=%@ target=%@", sendId, cancelledItem.targetHash);
    ZLModShowToast(@"Đã hủy gửi tin nhắn");
    ZLModRunOnMainThread(^{
        [self refreshUndoBannerOnMain];
    });
    return YES;
}

- (void)cancelLatestPendingSend {
    NSString *latestId = nil;
    os_unfair_lock_lock(&_lock);
    for (NSInteger i = (NSInteger)self.sendOrder.count - 1; i >= 0; i--) {
        NSString *sid = self.sendOrder[(NSUInteger)i];
        if (self.items[sid].state == ZLModDelaySendStatePending) {
            latestId = sid;
            break;
        }
    }
    os_unfair_lock_unlock(&_lock);
    if (latestId) {
        [self cancelPendingSendWithId:latestId];
    }
}

- (void)cancelAllPendingSends {
    [self cancelAllPendingSendsWithReason:@"manual_cancel_all"];
}

- (void)cancelAllPendingSendsWithReason:(NSString *)reason {
    NSMutableArray<ZLModPendingSendItem *> *toCancel = [NSMutableArray array];
    os_unfair_lock_lock(&_lock);
    for (NSString *sid in [self.items allKeys]) {
        ZLModPendingSendItem *item = self.items[sid];
        if (item.state == ZLModDelaySendStatePending) {
            item.state = ZLModDelaySendStateCancelled;
            [toCancel addObject:item];
        }
    }
    [self.items removeAllObjects];
    [self.sendOrder removeAllObjects];
    os_unfair_lock_unlock(&_lock);

    for (ZLModPendingSendItem *item in toCancel) {
        if (item.timer) {
            dispatch_source_cancel(item.timer);
            item.timer = nil;
        }
    }
    if (toCancel.count > 0) {
        ZLMOD_LOG(@"delaysend: cancelled %lu pending sends (reason=%@)",
                  (unsigned long)toCancel.count, reason ?: @"unknown");
        if ([reason isEqualToString:@"manual_cancel_all"]) {
            ZLModShowToast([NSString stringWithFormat:@"Đã hủy gửi %lu tin nhắn", (unsigned long)toCancel.count]);
        }
    }
    ZLModRunOnMainThread(^{
        [self stopBannerTickTimer];
        [self refreshUndoBannerOnMain];
    });
}

#pragma mark - Multi-Item Live-Countdown Keyboard-Aware Undo Banner

- (void)startBannerTickTimerIfNeeded {
    if (self.bannerTickTimer) return;
    dispatch_source_t tick = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(tick,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(250 * NSEC_PER_MSEC)),
                              (uint64_t)(250 * NSEC_PER_MSEC),
                              (uint64_t)(50 * NSEC_PER_MSEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(tick, ^{
        [weakSelf refreshUndoBannerOnMain];
    });
    dispatch_resume(tick);
    self.bannerTickTimer = tick;
}

- (void)stopBannerTickTimer {
    if (self.bannerTickTimer) {
        dispatch_source_cancel(self.bannerTickTimer);
        self.bannerTickTimer = nil;
    }
}

- (void)refreshUndoBannerOnMain {
    UIWindow *win = ZLModActiveKeyWindow();
    if (!win) return;

    NSUInteger activeCount = 0;
    NSTimeInterval soonestFire = DBL_MAX;
    os_unfair_lock_lock(&_lock);
    for (NSString *sid in self.sendOrder) {
        ZLModPendingSendItem *item = self.items[sid];
        if (item && item.state == ZLModDelaySendStatePending) {
            activeCount++;
            if (item.fireTime < soonestFire) soonestFire = item.fireTime;
        }
    }
    os_unfair_lock_unlock(&_lock);

    UIView *existing = [win viewWithTag:kZLModUndoBannerViewTag];
    if (activeCount == 0) {
        if (existing) [existing removeFromSuperview];
        [self stopBannerTickTimer];
        return;
    }

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSInteger remainingSec = (NSInteger)ceil(MAX(soonestFire - now, 0.0));
    if (remainingSec < 1) remainingSec = 1;

    CGFloat width = MIN(win.bounds.size.width - 28.0, 400.0);
    CGFloat height = 48.0;
    CGFloat baseBottomInset = MAX(win.safeAreaInsets.bottom + 64.0, 88.0);
    CGFloat kbBottomInset = (self.keyboardOverlapHeight > 0.0) ? (self.keyboardOverlapHeight + 12.0) : 0.0;
    CGFloat bottomY = win.bounds.size.height - MAX(baseBottomInset, kbBottomInset) - height;

    if (existing) [existing removeFromSuperview];

    UIView *banner = [[UIView alloc] initWithFrame:CGRectMake((win.bounds.size.width - width) * 0.5, bottomY, width, height)];
    banner.tag = kZLModUndoBannerViewTag;
    banner.userInteractionEnabled = YES;
    banner.accessibilityIdentifier = @"zlmod.delaysend.banner";
    banner.backgroundColor = [UIColor colorWithRed:0.08 green:0.10 blue:0.14 alpha:0.96];
    banner.layer.cornerRadius = 14.0;
    banner.layer.masksToBounds = YES;

    if (activeCount == 1) {
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(14.0, 0.0, width - 122.0, height)];
        label.text = [NSString stringWithFormat:@"Đang chờ gửi (%lds)...", (long)remainingSec];
        label.textColor = [UIColor whiteColor];
        label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        label.adjustsFontForContentSizeCategory = YES;
        [banner addSubview:label];

        UIButton *undoBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        undoBtn.frame = CGRectMake(width - 104.0, 8.0, 92.0, 32.0);
        [undoBtn setTitle:@"Hủy gửi" forState:UIControlStateNormal];
        [undoBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        undoBtn.titleLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightBold];
        undoBtn.backgroundColor = [UIColor systemRedColor];
        undoBtn.layer.cornerRadius = 10.0;
        undoBtn.accessibilityLabel = @"Hủy gửi tin nhắn";
        [undoBtn addTarget:self action:@selector(undoLatestTapped:) forControlEvents:UIControlEventTouchUpInside];
        [banner addSubview:undoBtn];
    } else {
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(12.0, 0.0, width - 196.0, height)];
        label.text = [NSString stringWithFormat:@"Chờ gửi %lu tin (%lds)", (unsigned long)activeCount, (long)remainingSec];
        label.textColor = [UIColor whiteColor];
        label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        label.adjustsFontForContentSizeCategory = YES;
        [banner addSubview:label];

        UIButton *cancelOneBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        cancelOneBtn.frame = CGRectMake(width - 180.0, 8.0, 82.0, 32.0);
        [cancelOneBtn setTitle:@"Hủy 1" forState:UIControlStateNormal];
        [cancelOneBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        cancelOneBtn.titleLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightSemibold];
        cancelOneBtn.backgroundColor = [UIColor systemOrangeColor];
        cancelOneBtn.layer.cornerRadius = 10.0;
        cancelOneBtn.accessibilityLabel = @"Hủy tin nhắn gần nhất";
        [cancelOneBtn addTarget:self action:@selector(undoLatestTapped:) forControlEvents:UIControlEventTouchUpInside];
        [banner addSubview:cancelOneBtn];

        UIButton *cancelAllBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        cancelAllBtn.frame = CGRectMake(width - 92.0, 8.0, 82.0, 32.0);
        [cancelAllBtn setTitle:@"Hủy hết" forState:UIControlStateNormal];
        [cancelAllBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        cancelAllBtn.titleLabel.font = [UIFont systemFontOfSize:12.5 weight:UIFontWeightBold];
        cancelAllBtn.backgroundColor = [UIColor systemRedColor];
        cancelAllBtn.layer.cornerRadius = 10.0;
        cancelAllBtn.accessibilityLabel = @"Hủy tất cả tin nhắn đang chờ gửi";
        [cancelAllBtn addTarget:self action:@selector(undoAllTapped:) forControlEvents:UIControlEventTouchUpInside];
        [banner addSubview:cancelAllBtn];
    }

    [win addSubview:banner];
    [win bringSubviewToFront:banner];
}

- (void)undoLatestTapped:(__unused UIButton *)sender {
    [self cancelLatestPendingSend];
}

- (void)undoAllTapped:(__unused UIButton *)sender {
    [self cancelAllPendingSendsWithReason:@"manual_cancel_all"];
}

@end

#pragma mark - Module installer

void ZLModUtilitiesInstall(void) {
    (void)[ZLModPrivateNotesStore shared];
    (void)[ZLModQuickReplyStore shared];
    (void)[ZLModDelaySendManager shared];

    NSUInteger installed = 0;
    Class sendMgrCls = NSClassFromString(@"ZAChatSendingManager");
    if (sendMgrCls) {
        // ZAChatSendingManager -sendChat:checkUpload: [v28@0:8@16B24]
        SEL sendSel = sel_registerName("sendChat:checkUpload:");
        if (ZLModClassHasInstanceMethod(sendMgrCls, sendSel)) {
            IMP orig = class_getMethodImplementation(sendMgrCls, sendSel);
            if (ZLModReplaceMethod(sendMgrCls, sendSel, 2, "v", ^(id selfObj, id chatEntity, BOOL checkUpload) {
                [[ZLModDelaySendManager shared] enqueueSendFromManager:selfObj
                                                            chatEntity:chatEntity
                                                           checkUpload:checkUpload
                                                               origIMP:orig];
            })) {
                installed++;
            }
        }
    }

    // Attach 1-tap Quick Reply picker button to BaseChatTVC navigation bar on viewDidAppear:
    Class chatVCCls = NSClassFromString(@"BaseChatTVC");
    if (chatVCCls) {
        SEL appearSel = sel_registerName("viewDidAppear:");
        if (ZLModClassHasInstanceMethod(chatVCCls, appearSel)) {
            IMP orig = class_getMethodImplementation(chatVCCls, appearSel);
            if (ZLModReplaceMethod(chatVCCls, appearSel, 1, "v", ^(id selfObj, BOOL animated) {
                if (orig) ((void (*)(id, SEL, BOOL))orig)(selfObj, appearSel, animated);
                if ([selfObj isKindOfClass:[UIViewController class]]) {
                    ZLModRunOnMainThread(^{
                        ZLModAttachQuickReplyButtonToChatVC((UIViewController *)selfObj);
                    });
                }
            })) {
                installed++;
            }
        }
    }

    ZLModSetModuleStatus(@"Utilities",
                         (installed > 0) ? ZLModModuleStatusHookInstalled : ZLModModuleStatusNotInstalled,
                         [NSString stringWithFormat:@"hooks=%lu", (unsigned long)installed]);
    ZLMOD_LOG(@"utilities installed (hooks=%lu)", (unsigned long)installed);
}
