// language: Objective-C, file: ZLModBridge.m, target: iOS 15.1+ (Zalo 26.10.02 & 26.11.01, arm64)
// ZLMod C-Bridge client — Local Server WebSocket connection, CPairing, CSaving, and CDeploy.

#import "ZLModBridge.h"
#import <os/lock.h>

NSString *const ZLModBridgeStatusDidChangeNotification = @"ZLModBridgeStatusDidChangeNotification";

static const NSUInteger kZLModMaxPendingMessages = 50;
static const NSTimeInterval kZLModHeartbeatInterval = 20.0;

@interface ZLModBridgeManager () <NSURLSessionWebSocketDelegate> {
    os_unfair_lock _lock;
}

@property (nonatomic, assign) ZLModBridgeStatus status;
@property (nonatomic, assign) NSTimeInterval lastPingLatencyMs;
@property (nonatomic, assign) NSUInteger savedMessagesCount;
@property (nonatomic, copy) NSString *lastSyncDateString;

@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionWebSocketTask *webSocketTask;
@property (nonatomic, strong) dispatch_source_t heartbeatTimer;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *pendingMessages;
@property (nonatomic, assign) BOOL isManualStop;
@property (nonatomic, assign) NSTimeInterval lastPingSentTime;

@end

@implementation ZLModBridgeManager

+ (instancetype)shared {
    static ZLModBridgeManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ZLModBridgeManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _status = ZLModBridgeStatusDisconnected;
        _pendingMessages = [NSMutableArray array];
        _savedMessagesCount = 0;
        _lastSyncDateString = @"Chưa đồng bộ";

        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 15.0;
        config.timeoutIntervalForResource = 60.0;
        _session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:[NSOperationQueue mainQueue]];

        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self
               selector:@selector(handleAppDidBecomeActive)
                   name:UIApplicationDidBecomeActiveNotification
                 object:nil];
        [nc addObserver:self
               selector:@selector(handleAppDidEnterBackground)
                   name:UIApplicationDidEnterBackgroundNotification
                 object:nil];
        [nc addObserver:self
               selector:@selector(handlePrefsChanged:)
                   name:ZLModPrefsDidChangeNotification
                 object:nil];
        [nc addObserver:self
               selector:@selector(handleAccountChanged)
                   name:ZLModAccountDidChangeNotification
                 object:nil];
        [nc addObserver:self
               selector:@selector(handleIncomingChatNotification:)
                   name:@"ZLModChatEntityArrivedNotification"
                 object:nil];
    }
    return self;
}

#pragma mark - Connection Lifecycle

- (void)start {
    self.isManualStop = NO;
    [self reconnect];
}

- (void)stop {
    self.isManualStop = YES;
    [self cancelHeartbeat];
    if (self.webSocketTask) {
        [self.webSocketTask cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
        self.webSocketTask = nil;
    }
    [self updateStatus:ZLModBridgeStatusDisconnected];
}

- (void)reconnect {
    if (self.isManualStop) return;

    NSString *serverUrlStr = [[ZLModPreferences shared] stringForKey:kZLModBridgeServerURL defaultValue:@""];
    if (serverUrlStr.length == 0) {
        [self updateStatus:ZLModBridgeStatusDisconnected];
        return;
    }

    // Convert http(s) URL to ws(s) URL
    NSURL *httpUrl = [NSURL URLWithString:serverUrlStr];
    if (!httpUrl || !httpUrl.host) {
        [self updateStatus:ZLModBridgeStatusDisconnected];
        return;
    }

    NSString *scheme = [httpUrl.scheme.lowercaseString isEqualToString:@"https"] ? @"wss" : @"ws";
    NSNumber *port = httpUrl.port;
    NSString *hostPort = port ? [NSString stringWithFormat:@"%@:%@", httpUrl.host, port] : httpUrl.host;
    NSString *token = [[ZLModPreferences shared] stringForKey:kZLModBridgeToken defaultValue:@""];
    NSString *accountScope = ZLModCurrentAccountScope() ?: @"";
    NSString *rawUid = @"";
    id chatMgr = NSClassFromString(@"ChatDataManager");
    if (chatMgr && [chatMgr respondsToSelector:sel_registerName("sharedChatDataManager")]) {
        id inst = ((id (*)(id, SEL))objc_msgSend)(chatMgr, sel_registerName("sharedChatDataManager"));
        rawUid = ZLModSafeStringProperty(inst, sel_registerName("userId")) ?: @"";
    }

    NSString *wsUrlStr = [NSString stringWithFormat:@"%@://%@/cbridge/ws?token=%@&account=%@&userId=%@",
                          scheme, hostPort,
                          [token stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]],
                          [accountScope stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]],
                          [rawUid stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];

    NSURL *wsUrl = [NSURL URLWithString:wsUrlStr];
    if (!wsUrl) return;

    if (self.webSocketTask) {
        [self.webSocketTask cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
        self.webSocketTask = nil;
    }

    [self updateStatus:ZLModBridgeStatusConnecting];
    ZLMOD_LOG(@"bridge: connecting to %@", wsUrl.host);

    self.webSocketTask = [self.session webSocketTaskWithURL:wsUrl];
    [self.webSocketTask resume];

    [self listenForMessages];
    [self startHeartbeat];
}

- (void)updateStatus:(ZLModBridgeStatus)newStatus {
    if (_status != newStatus) {
        _status = newStatus;
        ZLMOD_LOG(@"bridge: status changed to %ld", (long)newStatus);
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:ZLModBridgeStatusDidChangeNotification object:nil];
        });
    }
}

#pragma mark - WebSocket Listening & Heartbeat

- (void)listenForMessages {
    __weak typeof(self) weakSelf = self;
    [self.webSocketTask receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage * _Nullable message, NSError * _Nullable error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (error) {
            ZLMOD_LOG(@"bridge: receive error: %@", error.localizedDescription);
            [strongSelf updateStatus:ZLModBridgeStatusDisconnected];
            [strongSelf scheduleReconnect];
            return;
        }

        if (message.type == NSURLSessionWebSocketMessageTypeString) {
            [strongSelf handleIncomingTextMessage:message.string];
        }

        // Continue listening
        [strongSelf listenForMessages];
    }];
}

- (void)startHeartbeat {
    [self cancelHeartbeat];
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kZLModHeartbeatInterval * NSEC_PER_SEC)),
                              (uint64_t)(kZLModHeartbeatInterval * NSEC_PER_SEC),
                              (uint64_t)(1 * NSEC_PER_SEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        [weakSelf sendHeartbeatPing];
    });
    dispatch_resume(timer);
    self.heartbeatTimer = timer;
}

- (void)cancelHeartbeat {
    if (self.heartbeatTimer) {
        dispatch_source_cancel(self.heartbeatTimer);
        self.heartbeatTimer = nil;
    }
}

- (void)sendHeartbeatPing {
    if (!self.webSocketTask || self.status != ZLModBridgeStatusConnected) return;

    self.lastPingSentTime = [[NSDate date] timeIntervalSince1970];
    NSDictionary *pingPayload = @{
        @"action": @"ping",
        @"timestamp": @(self.lastPingSentTime)
    };
    [self sendJSONDictionary:pingPayload completion:nil];
}

- (void)scheduleReconnect {
    [self cancelHeartbeat];
    if (self.isManualStop) return;

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!weakSelf.isManualStop && weakSelf.status == ZLModBridgeStatusDisconnected) {
            [weakSelf reconnect];
        }
    });
}

#pragma mark - Incoming Message Router

- (void)handleIncomingTextMessage:(NSString *)text {
    if (!text || text.length == 0) return;
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return;

    NSError *err = nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (![json isKindOfClass:[NSDictionary class]] || err) return;

    NSDictionary *dict = (NSDictionary *)json;
    NSString *action = dict[@"action"];

    if ([action isEqualToString:@"pong"]) {
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if (self.lastPingSentTime > 0) {
            self.lastPingLatencyMs = (now - self.lastPingSentTime) * 1000.0;
        }
        [self updateStatus:ZLModBridgeStatusConnected];
    } else if ([action isEqualToString:@"connected"]) {
        [self updateStatus:ZLModBridgeStatusConnected];
        ZLMOD_LOG(@"bridge: server acknowledged connection");
        // Flush any pending messages accumulated
        [self flushPendingMessages];
    } else if ([action isEqualToString:@"cdeploy_push"]) {
        NSDictionary *settings = dict[@"settings"];
        if ([settings isKindOfClass:[NSDictionary class]]) {
            [self handleDeployPushSettings:settings];
        }
    }
}

#pragma mark - CDeploy: Server Settings Push Handler

- (void)handleDeployPushSettings:(NSDictionary *)settings {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *presenter = ZLModTopPresenterViewController();
        if (!presenter) return;

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"C-Deploy: Đồng bộ từ máy chủ"
                                                                       message:@"Máy chủ cục bộ vừa gửi bản cập nhật cấu hình ZLMod mới. Bạn có chấp nhận áp dụng toàn bộ cài đặt này ngay bây giờ không?"
                                                                preferredStyle:UIAlertControllerStyleAlert];

        __weak typeof(self) weakSelf = self;
        [alert addAction:[UIAlertAction actionWithTitle:@"Chấp nhận" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [weakSelf applyRemoteSettings:settings];
        }]];

        [alert addAction:[UIAlertAction actionWithTitle:@"Từ chối" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action) {
            [weakSelf sendJSONDictionary:@{
                @"action": @"cdeploy_ack",
                @"status": @"rejected"
            } completion:nil];
            ZLMOD_LOG(@"bridge: deploy push rejected by user");
        }]];

        [presenter presentViewController:alert animated:YES completion:nil];
    });
}

- (void)applyRemoteSettings:(NSDictionary *)settings {
    ZLModPreferences *prefs = [ZLModPreferences shared];
    for (NSString *key in settings) {
        id val = settings[key];
        if ([val isKindOfClass:[NSNumber class]]) {
            // Check if BOOL or double
            if (strcmp([val objCType], "c") == 0 || strcmp([val objCType], "B") == 0) {
                [prefs setBool:[val boolValue] forKey:key];
            } else {
                [prefs setDouble:[val doubleValue] forKey:key];
            }
        } else if ([val isKindOfClass:[NSString class]]) {
            [prefs setString:(NSString *)val forKey:key];
        }
    }

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"HH:mm:ss dd/MM";
    self.lastSyncDateString = [df stringFromDate:[NSDate date]];
    [prefs setString:self.lastSyncDateString forKey:kZLModBridgeLastSync];

    [[NSNotificationCenter defaultCenter] postNotificationName:ZLModPrefsDidChangeNotification object:@"*"];
    ZLModShowToast(@"Đã đồng bộ cài đặt từ máy chủ thành công!");

    [self sendJSONDictionary:@{
        @"action": @"cdeploy_ack",
        @"status": @"accepted",
        @"timestamp": @([[NSDate date] timeIntervalSince1970])
    } completion:nil];
    ZLMOD_LOG(@"bridge: remote settings applied successfully");
}

- (void)uploadCurrentSettingsWithCompletion:(void (^)(BOOL success, NSString *message))completion {
    ZLModPreferences *prefs = [ZLModPreferences shared];
    NSMutableDictionary *current = [NSMutableDictionary dictionary];

    NSArray<NSString *> *keys = @[
        kZLModGlassTabBar, kZLModThemePreset, kZLModThemeTintHex,
        kZLModHideTyping, kZLModHideSeen, kZLModHideReadReceipts,
        kZLModBlockTracking, kZLModBlockFirebase, kZLModHideAds,
        kZLModBlockAdRequests, kZLModRestoreProfileMusic, kZLModRestoreGDrive,
        kZLModRestoreMoreTab, kZLModAntiRecall, kZLModDelaySend, kZLModDelaySendSeconds,
        kZLModBridgeSaving
    ];

    for (NSString *k in keys) {
        if ([k isEqualToString:kZLModThemePreset] || [k isEqualToString:kZLModThemeTintHex]) {
            current[k] = [prefs stringForKey:k defaultValue:@""];
        } else if ([k isEqualToString:kZLModDelaySendSeconds]) {
            current[k] = @([prefs doubleForKey:k defaultValue:3.0]);
        } else {
            current[k] = @([prefs boolForKey:k]);
        }
    }

    NSDictionary *payload = @{
        @"action": @"cdeploy_upload",
        @"accountScope": ZLModCurrentAccountScope() ?: @"",
        @"settings": current,
        @"timestamp": @([[NSDate date] timeIntervalSince1970])
    };

    [self sendJSONDictionary:payload completion:^(BOOL success) {
        if (completion) {
            completion(success, success ? @"Đã tải cài đặt lên máy chủ thành công!" : @"Không thể gửi dữ liệu lên máy chủ.");
        }
    }];
}

#pragma mark - CSaving: Message Queue & Streaming

- (void)handleIncomingChatNotification:(NSNotification *)note {
    id entity = note.object;
    NSString *fallbackTid = note.userInfo[@"threadId"];
    [self enqueueMessageForSaving:entity threadId:fallbackTid];
}

- (void)enqueueMessageForSaving:(id)chatEntity threadId:(NSString *)threadId {
    if (![[ZLModPreferences shared] boolForKey:kZLModBridgeSaving]) return;
    if (!chatEntity) return;

    int64_t gid = ZLModSafeInt64Property(chatEntity, sel_registerName("globalId"), 0);
    int64_t cid = ZLModSafeInt64Property(chatEntity, sel_registerName("clientId"), 0);
    NSString *tid = ZLModSafeStringProperty(chatEntity, sel_registerName("threadId")) ?:
                    ZLModSafeStringProperty(chatEntity, sel_registerName("tuid")) ?: threadId;
    NSString *msg = ZLModSafeStringProperty(chatEntity, sel_registerName("message")) ?: @"";
    NSString *senderName = ZLModSafeStringProperty(chatEntity, sel_registerName("senderName")) ?: @"";
    NSString *senderId = ZLModSafeStringProperty(chatEntity, sel_registerName("senderId")) ?: @"";
    NSTimeInterval ts = ZLModSafeDoubleProperty(chatEntity, sel_registerName("createTime"), 0);
    if (ts <= 0) ts = [[NSDate date] timeIntervalSince1970] * 1000.0;

    BOOL isSelf = ZLModSafeBoolProperty(chatEntity, sel_registerName("isOwner"), NO);
    BOOL isGroup = ZLModSafeBoolProperty(chatEntity, sel_registerName("isChatGroup"), NO);
    NSInteger threadType = isGroup ? 1 : 0;

    // Detect message type
    NSString *msgType = @"chat.text";
    if ([msg localizedCaseInsensitiveContainsString:@"[Hình ảnh]"] || [msg localizedCaseInsensitiveContainsString:@"[Photo]"]) {
        msgType = @"chat.photo";
    } else if ([msg localizedCaseInsensitiveContainsString:@"[Nhãn dán]"] || [msg localizedCaseInsensitiveContainsString:@"[Sticker]"]) {
        msgType = @"chat.sticker";
    } else if ([msg localizedCaseInsensitiveContainsString:@"[Tin nhắn thoại]"] || [msg localizedCaseInsensitiveContainsString:@"[Voice]"]) {
        msgType = @"chat.voice";
    } else if ([msg localizedCaseInsensitiveContainsString:@"[Tệp tin]"] || [msg localizedCaseInsensitiveContainsString:@"[File]"]) {
        msgType = @"chat.file";
    }

    NSString *msgIdStr = (gid > 0) ? [NSString stringWithFormat:@"%lld", (long long)gid] : @"";
    NSString *cliMsgIdStr = (cid > 0) ? [NSString stringWithFormat:@"%lld", (long long)cid] : @"";
    NSString *identityKey = [NSString stringWithFormat:@"%@:%ld:%@:%@",
                             senderId.length > 0 ? senderId : @"0",
                             (long)threadType,
                             tid ?: @"0",
                             msgIdStr.length > 0 ? msgIdStr : cliMsgIdStr];

    NSDictionary *record = @{
        @"identityKey": identityKey,
        @"threadId": tid ?: @"",
        @"threadType": @(threadType),
        @"msgId": msgIdStr,
        @"cliMsgId": cliMsgIdStr,
        @"senderUid": senderId ?: @"",
        @"senderName": senderName ?: @"",
        @"text": msg ?: @"",
        @"msgType": msgType,
        @"timestampMs": @((int64_t)ts),
        @"isSelf": @(isSelf)
    };

    os_unfair_lock_lock(&_lock);
    if (self.pendingMessages.count >= kZLModMaxPendingMessages) {
        [self.pendingMessages removeObjectAtIndex:0]; // drop oldest
    }
    [self.pendingMessages addObject:record];
    os_unfair_lock_unlock(&_lock);

    [self flushPendingMessages];
}

- (void)flushPendingMessages {
    if (self.status != ZLModBridgeStatusConnected) return;

    NSArray *batch = nil;
    os_unfair_lock_lock(&_lock);
    if (self.pendingMessages.count > 0) {
        batch = [self.pendingMessages copy];
        [self.pendingMessages removeAllObjects];
    }
    os_unfair_lock_unlock(&_lock);

    if (!batch || batch.count == 0) return;

    NSDictionary *payload = @{
        @"action": @"csaving",
        @"accountScope": ZLModCurrentAccountScope() ?: @"",
        @"messages": batch
    };

    __weak typeof(self) weakSelf = self;
    [self sendJSONDictionary:payload completion:^(BOOL success) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (success) {
            strongSelf.savedMessagesCount += batch.count;
            ZLMOD_LOG(@"bridge: csaving dispatched %lu messages", (unsigned long)batch.count);
        } else {
            // Re-enqueue if send failed
            os_unfair_lock_lock(&strongSelf->_lock);
            [strongSelf.pendingMessages addObjectsFromArray:batch];
            os_unfair_lock_unlock(&strongSelf->_lock);
        }
    }];
}

#pragma mark - CPairing & Webhook Tests

- (void)testPairingWithCompletion:(void (^)(BOOL success, NSString *message, NSTimeInterval latencyMs))completion {
    NSString *serverUrl = [[ZLModPreferences shared] stringForKey:kZLModBridgeServerURL defaultValue:@""];
    if (serverUrl.length == 0) {
        if (completion) completion(NO, @"Chưa cấu hình địa chỉ máy chủ cục bộ.", 0);
        return;
    }

    NSURL *url = [NSURL URLWithString:[serverUrl stringByAppendingPathComponent:@"/api/cbridge/health"]];
    if (!url) {
        if (completion) completion(NO, @"Địa chỉ máy chủ không hợp lệ.", 0);
        return;
    }

    NSTimeInterval start = [[NSDate date] timeIntervalSince1970];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 5.0;
    NSString *token = [[ZLModPreferences shared] stringForKey:kZLModBridgeToken defaultValue:@""];
    if (token.length > 0) {
        [req setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    }

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        NSTimeInterval latency = ([[NSDate date] timeIntervalSince1970] - start) * 1000.0;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!error && [(NSHTTPURLResponse *)response statusCode] == 200) {
                if (completion) completion(YES, [NSString stringWithFormat:@"Kết nối thành công (%.0f ms)", latency], latency);
            } else {
                NSString *errStr = error ? error.localizedDescription : @"Máy chủ trả về mã lỗi";
                if (completion) completion(NO, [NSString stringWithFormat:@"Lỗi kết nối: %@", errStr], 0);
            }
        });
    }];
    [task resume];
}

- (void)testWebhookWithCompletion:(void (^)(BOOL success, NSString *message))completion {
    NSString *webhookUrlStr = [[ZLModPreferences shared] stringForKey:kZLModBridgeWebhook defaultValue:@""];
    if (webhookUrlStr.length == 0) {
        if (completion) completion(NO, @"Chưa nhập URL Discord Webhook.");
        return;
    }

    NSURL *url = [NSURL URLWithString:webhookUrlStr];
    if (!url) {
        if (completion) completion(NO, @"URL Discord Webhook không hợp lệ.");
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.timeoutInterval = 8.0;

    NSString *accountScope = ZLModCurrentAccountScope() ?: @"none";
    NSDictionary *body = @{
        @"content": [NSString stringWithFormat:@"🔔 **[ZLMod C-Bridge]** Kiểm tra kết nối Webhook thành công từ iPhone!\nTài khoản: `%@`", accountScope]
    };
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSInteger status = [(NSHTTPURLResponse *)response statusCode];
            if (!error && (status == 200 || status == 204)) {
                if (completion) completion(YES, @"Đã gửi thông báo thử nghiệm tới Discord!");
            } else {
                NSString *errStr = error ? error.localizedDescription : [NSString stringWithFormat:@"Mã lỗi HTTP %ld", (long)status];
                if (completion) completion(NO, [NSString stringWithFormat:@"Lỗi gửi Webhook: %@", errStr]);
            }
        });
    }];
    [task resume];
}

#pragma mark - Helper Send

- (void)sendJSONDictionary:(NSDictionary *)dict completion:(void (^)(BOOL success))completion {
    if (!self.webSocketTask || self.status != ZLModBridgeStatusConnected) {
        if (completion) completion(NO);
        return;
    }

    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:&err];
    if (!data || err) {
        if (completion) completion(NO);
        return;
    }

    NSString *str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSURLSessionWebSocketMessage *msg = [[NSURLSessionWebSocketMessage alloc] initWithString:str];
    [self.webSocketTask sendMessage:msg completionHandler:^(NSError * _Nullable error) {
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(error == nil);
            });
        }
    }];
}

#pragma mark - Notification Handlers

- (void)handleAppDidBecomeActive {
    if (!self.isManualStop && self.status == ZLModBridgeStatusDisconnected) {
        [self reconnect];
    }
}

- (void)handleAppDidEnterBackground {
    // Keep connection briefly or gracefully pause ping
}

- (void)handlePrefsChanged:(NSNotification *)note {
    if ([note.object isEqualToString:kZLModBridgeServerURL] || [note.object isEqualToString:kZLModBridgeToken]) {
        [self reconnect];
    }
}

- (void)handleAccountChanged {
    [self reconnect];
}

#pragma mark - NSURLSessionWebSocketDelegate

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask didOpenWithProtocol:(NSString *)protocol {
    ZLMOD_LOG(@"bridge: webSocket connected");
    [self updateStatus:ZLModBridgeStatusConnected];
    [self sendHeartbeatPing];
    [self flushPendingMessages];
}

- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask didCloseWithCode:(NSURLSessionWebSocketCloseCode)closeCode reason:(NSData *)reason {
    ZLMOD_LOG(@"bridge: webSocket closed with code %ld", (long)closeCode);
    [self updateStatus:ZLModBridgeStatusDisconnected];
    [self scheduleReconnect];
}

@end

#pragma mark - Module Installer

void ZLModBridgeInstall(void) {
    ZLModBridgeManager *mgr = [ZLModBridgeManager shared];
    [mgr start];
    ZLModSetModuleStatus(@"Bridge", ZLModModuleStatusHookInstalled, @"WebSocket client ready");
    ZLMOD_LOG(@"bridge: module installed");
}
