// language: Objective-C, file: ZLModBridge.m, target: iOS 15.1+ (Zalo 26.10.02 & 26.11.01, arm64)
// ZLMod C-Bridge client (MODULE 10):
// - 4-state WebSocket FSM (Disconnected -> Connecting -> Connected -> Closing -> Disconnected)
//   with monotonic connectionEpoch guarding all delegate & receive callbacks against stale tasks.
// - Exponential backoff reconnect (2s..30s), 20s heartbeat + 10s pong timeout, clean
//   background pause/resume, and full NSURLSession invalidateAndCancel on stop.
// - CPairing using NSURLComponents (never stringByAppendingPathComponent:) + Bonjour/mDNS
//   LAN auto-discovery + Bearer Authorization header (zero token in WS query URL).
// - CSaving subscribed directly to ZLModMessageTapBus (independent of AntiRecall), with
//   local bounded LRU dedup and ordered retry prepending failed batches before new messages.
// - CDeploy with strict preference allowlist, pending push retry queue, guaranteed cdeploy_ack,
//   and lastSyncDateString updated on both push accept and upload.
// - Automatic Discord Webhook relay for incoming & recalled messages with strict domain
//   validation, dedup, rate limiting (1.5s / HTTP 429 Retry-After), bounded retry, and
//   zero secret logging.

#import "ZLModBridge.h"
#import <os/lock.h>
#import <arpa/inet.h>
#import <netinet/in.h>

NSString *const ZLModBridgeStatusDidChangeNotification = @"ZLModBridgeStatusDidChangeNotification";

static const NSUInteger kZLModMaxPendingMessages = kZLModBridgeMaxPendingMessages;
static const NSTimeInterval kZLModHeartbeatInterval = kZLModBridgeHeartbeatSeconds;
static const NSUInteger kZLModMaxDiscordQueue = 50;
static const NSUInteger kZLModMaxDiscordRetries = 2;
static const NSUInteger kZLModMaxCDeployPresenterRetries = 3;

#pragma mark - URL & Formatting Helpers

static NSString *ZLModRFC3986Encode(NSString *value) {
    if (![value isKindOfClass:[NSString class]] || value.length == 0) return @"";
    static NSCharacterSet *unreserved = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        unreserved = [NSCharacterSet characterSetWithCharactersInString:
                      @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    });
    return [value stringByAddingPercentEncodingWithAllowedCharacters:unreserved] ?: @"";
}

static NSString *ZLModFormatSyncTimestamp(NSDate *date) {
    static NSDateFormatter *formatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"HH:mm:ss dd/MM";
    });
    return [formatter stringFromDate:date ?: [NSDate date]] ?: @"";
}

static NSURL *ZLModBuildBridgeEndpointURL(NSString *serverUrlStr, NSString *endpointPath) {
    if (![serverUrlStr isKindOfClass:[NSString class]]) return nil;
    NSString *trimmed = [serverUrlStr stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return nil;

    NSURLComponents *components = [NSURLComponents componentsWithString:trimmed];
    if (!components) return nil;
    NSString *scheme = components.scheme.lowercaseString;
    if (!([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])) return nil;
    if (components.host.length == 0) return nil;

    NSString *basePath = components.path ?: @"";
    while ([basePath hasSuffix:@"/"]) {
        basePath = [basePath substringToIndex:basePath.length - 1];
    }
    NSString *cleanEndpoint = [endpointPath hasPrefix:@"/"] ? endpointPath : [@"/" stringByAppendingString:endpointPath ?: @""];
    components.path = [basePath stringByAppendingString:cleanEndpoint];
    components.query = nil;
    components.fragment = nil;
    return components.URL;
}

static NSString *ZLModExtractIPv4HostFromAddresses(NSArray<NSData *> *addresses) {
    for (NSData *addrData in addresses) {
        if (addrData.length < sizeof(struct sockaddr)) continue;
        const struct sockaddr *sa = (const struct sockaddr *)addrData.bytes;
        if (sa->sa_family == AF_INET && addrData.length >= sizeof(struct sockaddr_in)) {
            const struct sockaddr_in *sin = (const struct sockaddr_in *)sa;
            char buf[INET_ADDRSTRLEN] = {0};
            if (inet_ntop(AF_INET, &(sin->sin_addr), buf, sizeof(buf)) != NULL) {
                return [NSString stringWithUTF8String:buf];
            }
        }
    }
    return nil;
}

static BOOL ZLModIsAllowedDiscordHost(NSString *host) {
    if (![host isKindOfClass:[NSString class]] || host.length == 0) return NO;
    NSString *lower = host.lowercaseString;
    return ([lower isEqualToString:@"discord.com"] ||
            [lower isEqualToString:@"discordapp.com"] ||
            [lower isEqualToString:@"ptb.discord.com"] ||
            [lower isEqualToString:@"canary.discord.com"]);
}

static BOOL ZLModPrefNoteMatchesKeys(NSNotification *note, NSSet<NSString *> *targets) {
    if ([note.object isKindOfClass:[NSString class]]) {
        NSString *k = (NSString *)note.object;
        if ([k isEqualToString:@"*"] || [targets containsObject:k]) return YES;
    }
    NSArray *changed = note.userInfo[ZLModPrefsChangedKeysUserInfoKey];
    if ([changed isKindOfClass:[NSArray class]]) {
        for (id item in changed) {
            if ([item isKindOfClass:[NSString class]]) {
                NSString *k = (NSString *)item;
                if ([k isEqualToString:@"*"] || [targets containsObject:k]) return YES;
            }
        }
    }
    return NO;
}

#pragma mark - ZLModBridgeManager

@interface ZLModBridgeManager () <NSURLSessionWebSocketDelegate, NSNetServiceBrowserDelegate, NSNetServiceDelegate> {
    os_unfair_lock _lock;
}

@property (nonatomic, assign) ZLModBridgeStatus status;
@property (nonatomic, assign) NSTimeInterval lastPingLatencyMs;
@property (nonatomic, assign) NSUInteger savedMessagesCount;
@property (nonatomic, assign) NSUInteger discordRelayedCount;
@property (nonatomic, assign) BOOL isDiscoveringLAN;
@property (nonatomic, copy) NSString *discoveredServerURL;
@property (nonatomic, copy) NSString *lastSyncDateString;
@property (nonatomic, copy) NSString *lastErrorMessage;

@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSession *httpSession;
@property (nonatomic, strong) NSURLSessionWebSocketTask *webSocketTask;
@property (nonatomic, assign) uint64_t connectionEpoch;
@property (nonatomic, assign) NSUInteger reconnectAttempt;
@property (nonatomic, assign) BOOL isManualStop;
@property (nonatomic, assign) BOOL isInBackground;
@property (nonatomic, assign) BOOL isFlushingMessages;
@property (nonatomic, assign) BOOL awaitingPong;
@property (nonatomic, assign) NSTimeInterval lastPingSentTime;

@property (nonatomic, strong) dispatch_source_t heartbeatTimer;
@property (nonatomic, strong) dispatch_source_t pongTimeoutTimer;
@property (nonatomic, strong) dispatch_source_t reconnectTimer;

// CSaving state (guarded by _lock)
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *pendingMessages;
@property (nonatomic, strong) NSMutableSet<NSString *> *csavingDedupSet;
@property (nonatomic, strong) NSMutableArray<NSString *> *csavingDedupOrder;

// CDeploy pending queue (main thread only)
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *pendingDeployPushes;
@property (nonatomic, assign) BOOL isPresentingDeployAlert;

// Discord Relay queue & rate limit state (guarded by _lock)
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *discordQueue;
@property (nonatomic, strong) NSMutableSet<NSString *> *discordDedupSet;
@property (nonatomic, strong) NSMutableArray<NSString *> *discordDedupOrder;
@property (nonatomic, assign) BOOL isSendingDiscord;
@property (nonatomic, assign) NSTimeInterval nextAllowedDiscordSendTime;

// Bonjour LAN auto-discovery (main thread only)
@property (nonatomic, strong) NSNetServiceBrowser *primaryBrowser;
@property (nonatomic, strong) NSNetServiceBrowser *fallbackBrowser;
@property (nonatomic, strong) NSMutableArray<NSNetService *> *resolvingServices;
@property (nonatomic, strong) dispatch_source_t discoveryTimer;
@property (nonatomic, copy) void (^discoveryCompletion)(NSString *discoveredURL, NSString *message);

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

+ (BOOL)isValidBridgeServerURLString:(NSString *)urlString {
    return ZLModBuildBridgeEndpointURL(urlString, @"/api/cbridge/health") != nil;
}

+ (BOOL)isValidDiscordWebhookURLString:(NSString *)urlString {
    if (![urlString isKindOfClass:[NSString class]]) return NO;
    NSString *trimmed = [urlString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return NO;
    NSURLComponents *comp = [NSURLComponents componentsWithString:trimmed];
    if (!comp) return NO;
    if (![comp.scheme.lowercaseString isEqualToString:@"https"]) return NO;
    if (!ZLModIsAllowedDiscordHost(comp.host)) return NO;
    NSString *path = comp.path ?: @"";
    if (![path hasPrefix:@"/api/"] || ![path containsString:@"/webhooks/"]) return NO;

    NSArray<NSString *> *parts = [path componentsSeparatedByString:@"/"];
    NSUInteger webhookIdx = [parts indexOfObject:@"webhooks"];
    if (webhookIdx == NSNotFound || webhookIdx + 2 >= parts.count) return NO;
    NSString *webhookId = parts[webhookIdx + 1];
    NSString *webhookToken = parts[webhookIdx + 2];
    return (webhookId.length >= 10 && webhookToken.length >= 16);
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _status = ZLModBridgeStatusDisconnected;
        _pendingMessages = [NSMutableArray array];
        _csavingDedupSet = [NSMutableSet set];
        _csavingDedupOrder = [NSMutableArray array];
        _pendingDeployPushes = [NSMutableArray array];
        _discordQueue = [NSMutableArray array];
        _discordDedupSet = [NSMutableSet set];
        _discordDedupOrder = [NSMutableArray array];
        _resolvingServices = [NSMutableArray array];

        NSString *savedSync = [[ZLModPreferences shared] stringForKey:kZLModBridgeLastSync defaultValue:@""];
        _lastSyncDateString = savedSync.length > 0 ? savedSync : @"Chưa đồng bộ";
        _lastErrorMessage = @"";
        _discoveredServerURL = @"";

        NSURLSessionConfiguration *httpCfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        httpCfg.timeoutIntervalForRequest = 10.0;
        httpCfg.timeoutIntervalForResource = 20.0;
        _httpSession = [NSURLSession sessionWithConfiguration:httpCfg];

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
    }
    return self;
}

- (NSUInteger)pendingMessagesCount {
    os_unfair_lock_lock(&_lock);
    NSUInteger count = self.pendingMessages.count;
    os_unfair_lock_unlock(&_lock);
    return count;
}

- (NSURLSession *)ensureWebSocketSession {
    if (!self.session) {
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 15.0;
        config.timeoutIntervalForResource = 60.0;
        self.session = [NSURLSession sessionWithConfiguration:config
                                                     delegate:self
                                                delegateQueue:[NSOperationQueue mainQueue]];
    }
    return self.session;
}

- (void)notifyStatusChanged {
    ZLModRunOnMainThread(^{
        [[NSNotificationCenter defaultCenter] postNotificationName:ZLModBridgeStatusDidChangeNotification object:nil];
    });
}

- (void)transitionToStatus:(ZLModBridgeStatus)newStatus errorMessage:(NSString *)errorMessage forceNotify:(BOOL)forceNotify {
    BOOL changed = (_status != newStatus);
    if (errorMessage != nil && ![_lastErrorMessage isEqualToString:errorMessage]) {
        _lastErrorMessage = [errorMessage copy];
        changed = YES;
    }
    if (_status != newStatus) {
        _status = newStatus;
        ZLMOD_LOG(@"bridge: state -> %ld", (long)newStatus);
    }
    if (changed || forceNotify) {
        [self notifyStatusChanged];
    }
}

#pragma mark - Connection Lifecycle & 4-State WebSocket FSM

- (void)start {
    ZLModRunOnMainThread(^{
        self.isManualStop = NO;
        self.isInBackground = NO;
        self.reconnectAttempt = 0;
        [self reconnect];
    });
}

- (void)stop {
    ZLModRunOnMainThread(^{
        self.isManualStop = YES;
        self.connectionEpoch += 1;
        [self cancelHeartbeat];
        [self cancelPongTimeout];
        [self cancelReconnectTimer];

        if (self.webSocketTask) {
            [self transitionToStatus:ZLModBridgeStatusClosing errorMessage:@"" forceNotify:NO];
            NSURLSessionWebSocketTask *taskToClose = self.webSocketTask;
            self.webSocketTask = nil;
            [taskToClose cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
        }

        if (self.session) {
            [self.session invalidateAndCancel];
            self.session = nil;
        }

        self.awaitingPong = NO;
        self.lastPingLatencyMs = 0;
        [self transitionToStatus:ZLModBridgeStatusDisconnected errorMessage:@"" forceNotify:YES];
    });
}

- (void)reconnect {
    ZLModRunOnMainThread(^{
        if (self.isManualStop || self.isInBackground) return;

        [self cancelHeartbeat];
        [self cancelPongTimeout];
        [self cancelReconnectTimer];

        // Bump epoch BEFORE closing previous socket so stale callbacks are ignored.
        self.connectionEpoch += 1;
        uint64_t activeEpoch = self.connectionEpoch;

        if (self.webSocketTask) {
            [self transitionToStatus:ZLModBridgeStatusClosing errorMessage:nil forceNotify:NO];
            NSURLSessionWebSocketTask *oldTask = self.webSocketTask;
            self.webSocketTask = nil;
            [oldTask cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
        }

        NSString *serverUrlStr = [[ZLModPreferences shared] stringForKey:kZLModBridgeServerURL defaultValue:@""];
        if (serverUrlStr.length == 0) {
            self.lastPingLatencyMs = 0;
            [self transitionToStatus:ZLModBridgeStatusDisconnected errorMessage:@"" forceNotify:YES];
            return;
        }

        NSURLComponents *baseComponents = [NSURLComponents componentsWithString:
                                           [serverUrlStr stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
        NSString *baseScheme = baseComponents.scheme.lowercaseString;
        if (!baseComponents || baseComponents.host.length == 0 ||
            !([baseScheme isEqualToString:@"http"] || [baseScheme isEqualToString:@"https"])) {
            [self transitionToStatus:ZLModBridgeStatusDisconnected
                        errorMessage:@"Địa chỉ máy chủ không hợp lệ (cần http:// hoặc https://)."
                         forceNotify:YES];
            return;
        }

        NSURLComponents *wsComponents = [[NSURLComponents alloc] init];
        wsComponents.scheme = [baseScheme isEqualToString:@"https"] ? @"wss" : @"ws";
        wsComponents.host = baseComponents.host;
        wsComponents.port = baseComponents.port;

        NSString *basePath = baseComponents.path ?: @"";
        while ([basePath hasSuffix:@"/"]) {
            basePath = [basePath substringToIndex:basePath.length - 1];
        }
        wsComponents.path = [basePath stringByAppendingString:@"/cbridge/ws"];

        NSString *accountScope = ZLModCurrentAccountScope() ?: @"";
        NSString *rawUid = ZLModCurrentRawUserId() ?: @"";
        wsComponents.percentEncodedQuery = [NSString stringWithFormat:@"account=%@&userId=%@",
                                            ZLModRFC3986Encode(accountScope),
                                            ZLModRFC3986Encode(rawUid)];

        NSURL *wsUrl = wsComponents.URL;
        if (!wsUrl) {
            [self transitionToStatus:ZLModBridgeStatusDisconnected
                        errorMessage:@"Không thể tạo địa chỉ WebSocket."
                         forceNotify:YES];
            return;
        }

        // Send bridge token via Authorization header (never in URL query string).
        NSMutableURLRequest *wsRequest = [NSMutableURLRequest requestWithURL:wsUrl];
        wsRequest.timeoutInterval = 15.0;
        NSString *token = [[ZLModPreferences shared] stringForKey:kZLModBridgeToken defaultValue:@""];
        if (token.length > 0) {
            [wsRequest setValue:[NSString stringWithFormat:@"Bearer %@", token]
             forHTTPHeaderField:@"Authorization"];
        }
        [wsRequest setValue:ZLMOD_VERSION forHTTPHeaderField:@"X-ZLMod-Version"];

        [self transitionToStatus:ZLModBridgeStatusConnecting errorMessage:@"" forceNotify:YES];
        ZLMOD_LOG(@"bridge: connecting to %@ (epoch=%llu)", wsUrl.host ?: @"unknown", (unsigned long long)activeEpoch);

        NSURLSession *wsSession = [self ensureWebSocketSession];
        NSURLSessionWebSocketTask *task = [wsSession webSocketTaskWithRequest:wsRequest];
        self.webSocketTask = task;
        self.awaitingPong = NO;
        [task resume];

        [self listenForMessagesOnTask:task epoch:activeEpoch];
    });
}

#pragma mark - WebSocket Receive Loop, Heartbeat, Pong Timeout & Backoff

- (void)listenForMessagesOnTask:(NSURLSessionWebSocketTask *)task epoch:(uint64_t)epoch {
    if (!task) return;
    __weak typeof(self) weakSelf = self;
    [task receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage * _Nullable message, NSError * _Nullable error) {
        ZLModRunOnMainThread(^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            // Ignore stale task callbacks completely.
            if (strongSelf.connectionEpoch != epoch || strongSelf.webSocketTask != task) {
                return;
            }

            if (error) {
                ZLMOD_LOG(@"bridge: receive error (epoch=%llu): %@",
                          (unsigned long long)epoch, error.localizedDescription ?: @"unknown");
                [strongSelf handleDisconnectForEpoch:epoch
                                        errorMessage:error.localizedDescription ?: @"Mất kết nối WebSocket"];
                return;
            }

            if (message.type == NSURLSessionWebSocketMessageTypeString && message.string.length > 0) {
                [strongSelf handleIncomingTextMessage:message.string];
            }

            // Continue receive loop while still on same epoch/task.
            if (strongSelf.connectionEpoch == epoch && strongSelf.webSocketTask == task) {
                [strongSelf listenForMessagesOnTask:task epoch:epoch];
            }
        });
    }];
}

- (void)handleDisconnectForEpoch:(uint64_t)epoch errorMessage:(NSString *)errorMessage {
    if (self.connectionEpoch != epoch) return;

    [self cancelHeartbeat];
    [self cancelPongTimeout];
    self.awaitingPong = NO;

    NSURLSessionWebSocketTask *task = self.webSocketTask;
    self.webSocketTask = nil;
    if (task && self.status != ZLModBridgeStatusClosing) {
        [self transitionToStatus:ZLModBridgeStatusClosing errorMessage:errorMessage forceNotify:NO];
        [task cancelWithCloseCode:NSURLSessionWebSocketCloseCodeGoingAway reason:nil];
    }

    [self transitionToStatus:ZLModBridgeStatusDisconnected errorMessage:errorMessage forceNotify:YES];

    if (!self.isManualStop && !self.isInBackground) {
        [self scheduleReconnect];
    }
}

- (void)startHeartbeatForEpoch:(uint64_t)epoch {
    [self cancelHeartbeat];
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kZLModHeartbeatInterval * NSEC_PER_SEC)),
                              (uint64_t)(kZLModHeartbeatInterval * NSEC_PER_SEC),
                              (uint64_t)(1 * NSEC_PER_SEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.connectionEpoch != epoch) return;
        [strongSelf sendHeartbeatPing];
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

- (void)startPongTimeoutForEpoch:(uint64_t)epoch {
    [self cancelPongTimeout];
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kZLModBridgePongTimeoutSec * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER,
                              (uint64_t)(0.5 * NSEC_PER_SEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.connectionEpoch != epoch || !strongSelf.awaitingPong) return;
        ZLMOD_LOG(@"bridge: heartbeat pong timeout (epoch=%llu) — closing half-open socket", (unsigned long long)epoch);
        [strongSelf handleDisconnectForEpoch:epoch errorMessage:@"Heartbeat pong timeout (mất phản hồi máy chủ)"];
    });
    dispatch_resume(timer);
    self.pongTimeoutTimer = timer;
}

- (void)cancelPongTimeout {
    if (self.pongTimeoutTimer) {
        dispatch_source_cancel(self.pongTimeoutTimer);
        self.pongTimeoutTimer = nil;
    }
}

- (void)sendHeartbeatPing {
    if (!self.webSocketTask || self.status != ZLModBridgeStatusConnected) return;

    uint64_t epoch = self.connectionEpoch;
    self.lastPingSentTime = [[NSDate date] timeIntervalSince1970];
    self.awaitingPong = YES;
    [self startPongTimeoutForEpoch:epoch];

    NSDictionary *pingPayload = @{
        @"action": @"ping",
        @"timestamp": @(self.lastPingSentTime)
    };
    [self sendJSONDictionary:pingPayload completion:nil];
}

- (void)cancelReconnectTimer {
    if (self.reconnectTimer) {
        dispatch_source_cancel(self.reconnectTimer);
        self.reconnectTimer = nil;
    }
}

- (void)scheduleReconnect {
    [self cancelReconnectTimer];
    if (self.isManualStop || self.isInBackground) return;

    NSString *serverUrlStr = [[ZLModPreferences shared] stringForKey:kZLModBridgeServerURL defaultValue:@""];
    if (serverUrlStr.length == 0) return;

    NSUInteger cappedShift = MIN(self.reconnectAttempt, (NSUInteger)4);
    NSTimeInterval delay = kZLModBridgeReconnectMinSec * (double)(1U << cappedShift);
    if (delay > kZLModBridgeReconnectMaxSec) delay = kZLModBridgeReconnectMaxSec;
    self.reconnectAttempt += 1;

    ZLMOD_LOG(@"bridge: scheduling reconnect in %.0fs (attempt %lu)", delay, (unsigned long)self.reconnectAttempt);
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER,
                              (uint64_t)(0.5 * NSEC_PER_SEC));
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf cancelReconnectTimer];
        if (!strongSelf.isManualStop && !strongSelf.isInBackground &&
            strongSelf.status == ZLModBridgeStatusDisconnected) {
            [strongSelf reconnect];
        }
    });
    dispatch_resume(timer);
    self.reconnectTimer = timer;
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
    NSString *action = [dict[@"action"] isKindOfClass:[NSString class]] ? dict[@"action"] : @"";

    if ([action isEqualToString:@"pong"]) {
        self.awaitingPong = NO;
        [self cancelPongTimeout];
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if (self.lastPingSentTime > 0) {
            self.lastPingLatencyMs = MAX(0.0, (now - self.lastPingSentTime) * 1000.0);
        }
        [self transitionToStatus:ZLModBridgeStatusConnected errorMessage:@"" forceNotify:YES];
    } else if ([action isEqualToString:@"connected"]) {
        self.reconnectAttempt = 0;
        [self transitionToStatus:ZLModBridgeStatusConnected errorMessage:@"" forceNotify:YES];
        ZLMOD_LOG(@"bridge: server acknowledged connection");
        [self flushPendingMessages];
    } else if ([action isEqualToString:@"cdeploy_push"]) {
        NSDictionary *settings = dict[@"settings"];
        if ([settings isKindOfClass:[NSDictionary class]]) {
            [self handleDeployPushSettings:settings];
        } else {
            [self sendJSONDictionary:@{
                @"action": @"cdeploy_ack",
                @"status": @"rejected",
                @"reason": @"invalid_payload"
            } completion:nil];
        }
    } else if ([action isEqualToString:@"cdeploy_upload_ack"]) {
        NSString *nowStr = ZLModFormatSyncTimestamp([NSDate date]);
        self.lastSyncDateString = nowStr;
        [[ZLModPreferences shared] setString:nowStr forKey:kZLModBridgeLastSync];
        [self notifyStatusChanged];
    }
}

#pragma mark - CDeploy: Allowlisted Server Settings Push & Upload

- (void)handleDeployPushSettings:(NSDictionary *)settings {
    if (![settings isKindOfClass:[NSDictionary class]]) return;
    ZLModRunOnMainThread(^{
        NSDictionary *entry = @{
            @"settings": [settings copy],
            @"retries": @(0)
        };
        [self.pendingDeployPushes addObject:entry];
        [self processNextPendingDeployPush];
    });
}

- (void)processNextPendingDeployPush {
    if (self.isPresentingDeployAlert || self.pendingDeployPushes.count == 0) return;

    NSDictionary *entry = self.pendingDeployPushes.firstObject;
    NSDictionary *settings = entry[@"settings"];
    NSUInteger retries = [entry[@"retries"] unsignedIntegerValue];

    UIViewController *presenter = ZLModTopPresenterViewController();
    if (!presenter || [presenter isKindOfClass:[UIAlertController class]] || presenter.presentedViewController != nil) {
        if (retries < kZLModMaxCDeployPresenterRetries) {
            self.pendingDeployPushes[0] = @{
                @"settings": settings,
                @"retries": @(retries + 1)
            };
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [weakSelf processNextPendingDeployPush];
            });
            return;
        }
        // Guaranteed ACK even when UI cannot present after retries.
        [self.pendingDeployPushes removeObjectAtIndex:0];
        [self sendJSONDictionary:@{
            @"action": @"cdeploy_ack",
            @"status": @"rejected",
            @"reason": @"presenter_unavailable"
        } completion:nil];
        ZLMOD_LOG(@"bridge: deploy push rejected (presenter unavailable)");
        [self processNextPendingDeployPush];
        return;
    }

    [self.pendingDeployPushes removeObjectAtIndex:0];
    self.isPresentingDeployAlert = YES;

    NSSet<NSString *> *allowlist = [ZLModPreferences remoteDeployAllowedKeys];
    NSUInteger validCount = 0;
    for (NSString *key in settings) {
        if ([allowlist containsObject:key]) validCount++;
    }

    NSString *msg = [NSString stringWithFormat:
                     @"Máy chủ cục bộ gửi %lu mục cài đặt hợp lệ cho ZLMod (các trường bí mật và địa chỉ máy chủ được bảo vệ và bỏ qua). Bạn có muốn áp dụng không?",
                     (unsigned long)validCount];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"C-Deploy: Đồng bộ từ máy chủ"
                                                                   message:msg
                                                            preferredStyle:UIAlertControllerStyleAlert];

    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Chấp nhận"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf applyRemoteSettings:settings];
        strongSelf.isPresentingDeployAlert = NO;
        [strongSelf processNextPendingDeployPush];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"Từ chối"
                                              style:UIAlertActionStyleCancel
                                            handler:^(__unused UIAlertAction *action) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf sendJSONDictionary:@{
            @"action": @"cdeploy_ack",
            @"status": @"rejected",
            @"reason": @"user_declined"
        } completion:nil];
        ZLMOD_LOG(@"bridge: deploy push rejected by user");
        strongSelf.isPresentingDeployAlert = NO;
        [strongSelf processNextPendingDeployPush];
    }]];

    [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)applyRemoteSettings:(NSDictionary *)settings {
    ZLModPreferences *prefs = [ZLModPreferences shared];
    NSSet<NSString *> *allowedKeys = [ZLModPreferences remoteDeployAllowedKeys];

    NSMutableArray<NSString *> *rejectedKeys = [NSMutableArray array];
    for (id key in settings) {
        if (![key isKindOfClass:[NSString class]] || ![allowedKeys containsObject:(NSString *)key]) {
            [rejectedKeys addObject:[NSString stringWithFormat:@"%@", key]];
        }
    }

    NSArray<NSString *> *appliedKeys = [prefs applyRemoteSettingsBatch:settings allowedKeys:allowedKeys];

    NSString *nowStr = ZLModFormatSyncTimestamp([NSDate date]);
    self.lastSyncDateString = nowStr;
    [prefs setString:nowStr forKey:kZLModBridgeLastSync];
    [self notifyStatusChanged];

    ZLModShowToast([NSString stringWithFormat:@"Đã áp dụng %lu mục cài đặt từ máy chủ!",
                    (unsigned long)appliedKeys.count]);

    [self sendJSONDictionary:@{
        @"action": @"cdeploy_ack",
        @"status": @"accepted",
        @"appliedCount": @(appliedKeys.count),
        @"rejectedKeys": rejectedKeys,
        @"timestamp": @([[NSDate date] timeIntervalSince1970])
    } completion:nil];
    ZLMOD_LOG(@"bridge: remote settings applied (%lu applied, %lu rejected)",
              (unsigned long)appliedKeys.count, (unsigned long)rejectedKeys.count);
}

- (void)uploadCurrentSettingsWithCompletion:(void (^)(BOOL success, NSString *message))completion {
    if (self.status != ZLModBridgeStatusConnected) {
        if (completion) {
            ZLModRunOnMainThread(^{
                completion(NO, @"Chưa kết nối tới máy chủ C-Bridge.");
            });
        }
        return;
    }

    ZLModPreferences *prefs = [ZLModPreferences shared];
    NSMutableDictionary *current = [NSMutableDictionary dictionary];
    // Strictly upload only allowlisted non-secret preference keys.
    for (NSString *k in [ZLModPreferences remoteDeployAllowedKeys]) {
        if ([k isEqualToString:kZLModThemePreset] || [k isEqualToString:kZLModThemeTintHex]) {
            current[k] = [prefs stringForKey:k defaultValue:@""];
        } else if ([k isEqualToString:kZLModDelaySendSeconds]) {
            current[k] = @([prefs doubleForKey:k defaultValue:kZLModDelaySendDefaultSeconds]);
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

    __weak typeof(self) weakSelf = self;
    [self sendJSONDictionary:payload completion:^(BOOL success) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (success && strongSelf) {
            NSString *nowStr = ZLModFormatSyncTimestamp([NSDate date]);
            strongSelf.lastSyncDateString = nowStr;
            [[ZLModPreferences shared] setString:nowStr forKey:kZLModBridgeLastSync];
            [strongSelf notifyStatusChanged];
        }
        if (completion) {
            completion(success,
                       success ? @"Đã tải cài đặt lên máy chủ thành công!"
                               : @"Không thể gửi dữ liệu lên máy chủ.");
        }
    }];
}

#pragma mark - Decoupled Message Tap Entry (CSaving + Discord Relay)

- (void)handleMessageModel:(ZLModMessageModel *)model eventKind:(ZLModMessageTapEventKind)kind {
    if (!model) return;
    ZLModPreferences *prefs = [ZLModPreferences shared];
    if ([prefs boolForKey:kZLModBridgeSaving]) {
        [self enqueueNormalizedModelForCSaving:model eventKind:kind];
    }
    if ([prefs boolForKey:kZLModBridgeDiscordRelay]) {
        [self enqueueNormalizedModelForDiscordRelay:model eventKind:kind];
    }
}

- (void)enqueueMessageForSaving:(id)chatEntity threadId:(NSString *)threadId {
    if (![[ZLModPreferences shared] boolForKey:kZLModBridgeSaving]) return;
    if (!chatEntity) return;
    ZLModMessageModel *model = [ZLModChatEntityAdapter modelFromChatEntity:chatEntity fallbackThreadId:threadId];
    if (!model) return;
    ZLModMessageTapEventKind kind = model.isRecalled ? ZLModMessageTapEventRecalled : ZLModMessageTapEventObserved;
    [self enqueueNormalizedModelForCSaving:model eventKind:kind];
}

#pragma mark - CSaving: Bounded Dedup + Ordered Retry Queue

- (BOOL)markCSavingKeySeenIfNewLocked:(NSString *)dedupKey {
    if (dedupKey.length == 0) return YES;
    if ([self.csavingDedupSet containsObject:dedupKey]) {
        return NO;
    }
    [self.csavingDedupSet addObject:dedupKey];
    [self.csavingDedupOrder addObject:dedupKey];
    while (self.csavingDedupOrder.count > kZLModBridgeDedupCapacity) {
        NSString *evicted = self.csavingDedupOrder.firstObject;
        [self.csavingDedupOrder removeObjectAtIndex:0];
        if (evicted) [self.csavingDedupSet removeObject:evicted];
    }
    return YES;
}

- (void)enqueueNormalizedModelForCSaving:(ZLModMessageModel *)model eventKind:(ZLModMessageTapEventKind)kind {
    NSString *identityKey = model.identityKey ?: @"";
    if (identityKey.length == 0) return;

    NSString *eventTag = (kind == ZLModMessageTapEventRecalled) ? @"recall" : @"obs";
    NSString *dedupKey = [NSString stringWithFormat:@"%@:%@", eventTag, identityKey];

    NSMutableDictionary *record = [[ZLModChatEntityAdapter csavingDictionaryFromModel:model] mutableCopy];
    if (kind == ZLModMessageTapEventRecalled) {
        record[@"msgType"] = @"chat.undo";
        record[@"isRecalled"] = @YES;
        NSString *recovered = [[ZLModAntiRecallStore shared] recalledTextForGlobalId:model.globalId clientId:model.clientId];
        if (recovered.length > 0) {
            record[@"recoveredText"] = recovered;
        }
    }

    os_unfair_lock_lock(&_lock);
    if (![self markCSavingKeySeenIfNewLocked:dedupKey]) {
        os_unfair_lock_unlock(&_lock);
        return;
    }
    if (self.pendingMessages.count >= kZLModMaxPendingMessages) {
        [self.pendingMessages removeObjectAtIndex:0];
    }
    [self.pendingMessages addObject:[record copy]];
    os_unfair_lock_unlock(&_lock);

    [self flushPendingMessages];
}

- (void)flushPendingMessages {
    ZLModRunOnMainThread(^{
        if (self.status != ZLModBridgeStatusConnected || self.isFlushingMessages) return;

        NSArray<NSDictionary *> *batch = nil;
        os_unfair_lock_lock(&self->_lock);
        if (self.pendingMessages.count > 0) {
            batch = [self.pendingMessages copy];
            [self.pendingMessages removeAllObjects];
        }
        os_unfair_lock_unlock(&self->_lock);

        if (!batch || batch.count == 0) return;

        self.isFlushingMessages = YES;
        NSDictionary *payload = @{
            @"action": @"csaving",
            @"accountScope": ZLModCurrentAccountScope() ?: @"",
            @"messages": batch
        };

        __weak typeof(self) weakSelf = self;
        [self sendJSONDictionary:payload completion:^(BOOL success) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.isFlushingMessages = NO;

            if (success) {
                strongSelf.savedMessagesCount += batch.count;
                ZLMOD_LOG(@"bridge: csaving dispatched %lu messages", (unsigned long)batch.count);
                [strongSelf notifyStatusChanged];
                // Drain any messages queued while this batch was in flight.
                if (strongSelf.pendingMessagesCount > 0) {
                    [strongSelf flushPendingMessages];
                }
            } else {
                // Preserve strict chronological order: prepend failed batch BEFORE newly queued items,
                // then trim oldest beyond kZLModMaxPendingMessages.
                os_unfair_lock_lock(&strongSelf->_lock);
                NSMutableArray<NSDictionary *> *merged = [NSMutableArray arrayWithCapacity:batch.count + strongSelf.pendingMessages.count];
                [merged addObjectsFromArray:batch];
                [merged addObjectsFromArray:strongSelf.pendingMessages];
                while (merged.count > kZLModMaxPendingMessages) {
                    [merged removeObjectAtIndex:0];
                }
                strongSelf.pendingMessages = merged;
                os_unfair_lock_unlock(&strongSelf->_lock);
                ZLMOD_LOG(@"bridge: csaving send failed — re-queued %lu messages in order",
                          (unsigned long)strongSelf.pendingMessagesCount);
            }
        }];
    });
}

#pragma mark - Automatic Discord Webhook Relay

- (BOOL)markDiscordKeySeenIfNewLocked:(NSString *)dedupKey {
    if (dedupKey.length == 0) return YES;
    if ([self.discordDedupSet containsObject:dedupKey]) {
        return NO;
    }
    [self.discordDedupSet addObject:dedupKey];
    [self.discordDedupOrder addObject:dedupKey];
    while (self.discordDedupOrder.count > kZLModBridgeDedupCapacity) {
        NSString *evicted = self.discordDedupOrder.firstObject;
        [self.discordDedupOrder removeObjectAtIndex:0];
        if (evicted) [self.discordDedupSet removeObject:evicted];
    }
    return YES;
}

- (void)enqueueNormalizedModelForDiscordRelay:(ZLModMessageModel *)model eventKind:(ZLModMessageTapEventKind)kind {
    NSString *webhookUrlStr = [[ZLModPreferences shared] stringForKey:kZLModBridgeWebhook defaultValue:@""];
    if (![ZLModBridgeManager isValidDiscordWebhookURLString:webhookUrlStr]) return;

    // Skip normal self-sent messages to avoid echo noise; always relay recalled events.
    if (kind == ZLModMessageTapEventObserved && model.isSelf) return;

    NSString *eventTag = (kind == ZLModMessageTapEventRecalled) ? @"recall" : @"msg";
    NSString *dedupKey = [NSString stringWithFormat:@"%@:%@", eventTag, model.identityKey ?: @""];
    if (model.identityKey.length == 0) return;

    NSString *sender = model.senderName.length > 0 ? model.senderName : (model.senderId.length > 0 ? model.senderId : @"Người dùng");
    NSString *contentBody = model.text ?: @"";
    if (kind == ZLModMessageTapEventRecalled) {
        NSString *recovered = [[ZLModAntiRecallStore shared] recalledTextForGlobalId:model.globalId clientId:model.clientId];
        if (recovered.length > 0) {
            contentBody = recovered;
        } else if (model.originRecallText.length > 0) {
            contentBody = model.originRecallText;
        } else {
            contentBody = @"(Không có bản lưu gốc trước khi thu hồi)";
        }
    } else if (contentBody.length == 0) {
        contentBody = model.hasPhotoAttachment ? @"[Hình ảnh]" : @"[Tin nhắn]";
    }

    if (contentBody.length > 1500) {
        contentBody = [[contentBody substringToIndex:1500] stringByAppendingString:@"..."];
    }

    NSString *prefix = (kind == ZLModMessageTapEventRecalled)
        ? @"⚠️ **[ZLMod — Tin nhắn bị thu hồi]**"
        : @"💬 **[ZLMod — Tin nhắn mới]**";
    NSString *threadTag = model.isGroup ? @"Nhóm" : @"Cá nhân";
    NSString *formatted = [NSString stringWithFormat:@"%@\n**Người gửi:** %@ (%@)\n**Nội dung:** %@",
                           prefix, sender, threadTag, contentBody];

    NSMutableDictionary *job = [@{
        @"content": formatted,
        @"retries": @(0)
    } mutableCopy];

    os_unfair_lock_lock(&_lock);
    if (![self markDiscordKeySeenIfNewLocked:dedupKey]) {
        os_unfair_lock_unlock(&_lock);
        return;
    }
    if (self.discordQueue.count >= kZLModMaxDiscordQueue) {
        [self.discordQueue removeObjectAtIndex:0];
    }
    [self.discordQueue addObject:job];
    os_unfair_lock_unlock(&_lock);

    [self drainDiscordQueue];
}

- (void)drainDiscordQueue {
    os_unfair_lock_lock(&_lock);
    if (self.isSendingDiscord || self.discordQueue.count == 0) {
        os_unfair_lock_unlock(&_lock);
        return;
    }

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval waitSec = self.nextAllowedDiscordSendTime - now;
    if (waitSec > 0.05) {
        os_unfair_lock_unlock(&_lock);
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(waitSec * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [weakSelf drainDiscordQueue];
        });
        return;
    }

    NSMutableDictionary *job = self.discordQueue.firstObject;
    [self.discordQueue removeObjectAtIndex:0];
    self.isSendingDiscord = YES;
    self.nextAllowedDiscordSendTime = now + kZLModDiscordMinIntervalSec;
    os_unfair_lock_unlock(&_lock);

    NSString *webhookUrlStr = [[ZLModPreferences shared] stringForKey:kZLModBridgeWebhook defaultValue:@""];
    if (![[ZLModPreferences shared] boolForKey:kZLModBridgeDiscordRelay] ||
        ![ZLModBridgeManager isValidDiscordWebhookURLString:webhookUrlStr]) {
        os_unfair_lock_lock(&_lock);
        self.isSendingDiscord = NO;
        os_unfair_lock_unlock(&_lock);
        return;
    }

    NSURL *url = [NSURL URLWithString:webhookUrlStr];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.timeoutInterval = 10.0;

    NSDictionary *body = @{@"content": job[@"content"] ?: @""};
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task = [self.httpSession dataTaskWithRequest:req
                                                     completionHandler:^(__unused NSData *data, NSURLResponse *response, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        NSHTTPURLResponse *httpResp = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        NSInteger statusCode = httpResp.statusCode;

        if (!error && (statusCode == 200 || statusCode == 204)) {
            strongSelf.discordRelayedCount += 1;
            [strongSelf notifyStatusChanged];
        } else {
            NSUInteger retries = [job[@"retries"] unsignedIntegerValue];
            BOOL shouldRetry = (retries < kZLModMaxDiscordRetries) &&
                               (error != nil || statusCode == 429 || statusCode >= 500);
            NSTimeInterval retryDelay = kZLModDiscordMinIntervalSec;
            if (statusCode == 429) {
                NSString *retryAfter = httpResp.allHeaderFields[@"Retry-After"];
                double parsed = retryAfter ? [retryAfter doubleValue] : 3.0;
                if (parsed < 1.0) parsed = 2.0;
                if (parsed > 15.0) parsed = 15.0;
                retryDelay = parsed;
            }

            ZLMOD_LOG(@"bridge: discord relay failed (http=%ld retry=%@)",
                      (long)statusCode, shouldRetry ? @"yes" : @"no");

            if (shouldRetry) {
                job[@"retries"] = @(retries + 1);
                os_unfair_lock_lock(&strongSelf->_lock);
                [strongSelf.discordQueue insertObject:job atIndex:0];
                strongSelf.nextAllowedDiscordSendTime = [[NSDate date] timeIntervalSince1970] + retryDelay;
                os_unfair_lock_unlock(&strongSelf->_lock);
            }
        }

        os_unfair_lock_lock(&strongSelf->_lock);
        strongSelf.isSendingDiscord = NO;
        BOOL hasMore = strongSelf.discordQueue.count > 0;
        os_unfair_lock_unlock(&strongSelf->_lock);

        if (hasMore) {
            [strongSelf drainDiscordQueue];
        }
    }];
    [task resume];
}

#pragma mark - CPairing Health Test, Bonjour LAN Auto-Discovery & Webhook Test

- (void)testPairingWithCompletion:(void (^)(BOOL success, NSString *message, NSTimeInterval latencyMs))completion {
    NSString *serverUrl = [[ZLModPreferences shared] stringForKey:kZLModBridgeServerURL defaultValue:@""];
    if (serverUrl.length == 0) {
        if (completion) {
            ZLModRunOnMainThread(^{
                completion(NO, @"Chưa cấu hình địa chỉ máy chủ cục bộ.", 0);
            });
        }
        return;
    }

    NSURL *url = ZLModBuildBridgeEndpointURL(serverUrl, @"/api/cbridge/health");
    if (!url) {
        if (completion) {
            ZLModRunOnMainThread(^{
                completion(NO, @"Địa chỉ máy chủ không hợp lệ (cần http:// hoặc https://).", 0);
            });
        }
        return;
    }

    NSTimeInterval start = [[NSDate date] timeIntervalSince1970];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 5.0;
    NSString *token = [[ZLModPreferences shared] stringForKey:kZLModBridgeToken defaultValue:@""];
    if (token.length > 0) {
        [req setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    }

    NSURLSessionDataTask *task = [self.httpSession dataTaskWithRequest:req
                                                     completionHandler:^(__unused NSData *data, NSURLResponse *response, NSError *error) {
        NSTimeInterval latency = MAX(0.0, ([[NSDate date] timeIntervalSince1970] - start) * 1000.0);
        NSHTTPURLResponse *httpResp = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        NSInteger statusCode = httpResp.statusCode;

        ZLModRunOnMainThread(^{
            if (!error && statusCode == 200) {
                self.lastPingLatencyMs = latency;
                [self notifyStatusChanged];
                if (completion) {
                    completion(YES, [NSString stringWithFormat:@"Kết nối thành công (%.0f ms)", latency], latency);
                }
            } else {
                NSString *errStr = error ? error.localizedDescription : [NSString stringWithFormat:@"HTTP %ld", (long)statusCode];
                if (completion) {
                    completion(NO, [NSString stringWithFormat:@"Lỗi kết nối: %@", errStr], 0);
                }
            }
        });
    }];
    [task resume];
}

- (void)startLANDiscoveryWithCompletion:(void (^)(NSString *discoveredURL, NSString *message))completion {
    ZLModRunOnMainThread(^{
        [self stopLANDiscovery];
        self.isDiscoveringLAN = YES;
        self.discoveryCompletion = completion;
        [self notifyStatusChanged];

        self.primaryBrowser = [[NSNetServiceBrowser alloc] init];
        self.primaryBrowser.delegate = self;
        [self.primaryBrowser searchForServicesOfType:@"_zlmod-cbridge._tcp." inDomain:@"local."];

        self.fallbackBrowser = [[NSNetServiceBrowser alloc] init];
        self.fallbackBrowser.delegate = self;
        [self.fallbackBrowser searchForServicesOfType:@"_http._tcp." inDomain:@"local."];

        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer,
                                  dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                                  DISPATCH_TIME_FOREVER,
                                  (uint64_t)(0.25 * NSEC_PER_SEC));
        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(timer, ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.isDiscoveringLAN) return;
            void (^cb)(NSString *, NSString *) = strongSelf.discoveryCompletion;
            [strongSelf stopLANDiscovery];
            if (cb) {
                cb(nil, @"Không tìm thấy máy chủ C-Bridge trên mạng LAN (mDNS). Hãy nhập địa chỉ thủ công.");
            }
        });
        dispatch_resume(timer);
        self.discoveryTimer = timer;
        ZLMOD_LOG(@"bridge: started Bonjour LAN auto-discovery");
    });
}

- (void)stopLANDiscovery {
    ZLModRunOnMainThread(^{
        if (self.discoveryTimer) {
            dispatch_source_cancel(self.discoveryTimer);
            self.discoveryTimer = nil;
        }
        if (self.primaryBrowser) {
            [self.primaryBrowser stop];
            self.primaryBrowser.delegate = nil;
            self.primaryBrowser = nil;
        }
        if (self.fallbackBrowser) {
            [self.fallbackBrowser stop];
            self.fallbackBrowser.delegate = nil;
            self.fallbackBrowser = nil;
        }
        for (NSNetService *svc in self.resolvingServices) {
            svc.delegate = nil;
            [svc stop];
        }
        [self.resolvingServices removeAllObjects];
        self.discoveryCompletion = nil;
        if (self.isDiscoveringLAN) {
            self.isDiscoveringLAN = NO;
            [self notifyStatusChanged];
        }
    });
}

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser
           didFindService:(NSNetService *)service
               moreComing:(__unused BOOL)moreComing {
    if (!self.isDiscoveringLAN || !service) return;
    if (browser == self.fallbackBrowser) {
        NSString *lowerName = service.name.lowercaseString ?: @"";
        BOOL looksLikeBridge = [lowerName containsString:@"zlmod"] ||
                               [lowerName containsString:@"cbridge"] ||
                               [lowerName containsString:@"zalo-meet"];
        if (!looksLikeBridge) return;
    }
    service.delegate = self;
    [self.resolvingServices addObject:service];
    [service resolveWithTimeout:4.0];
}

- (void)netServiceDidResolveAddress:(NSNetService *)sender {
    if (!self.isDiscoveringLAN || !sender) return;
    NSString *host = ZLModExtractIPv4HostFromAddresses(sender.addresses);
    if (host.length == 0 && sender.hostName.length > 0) {
        host = sender.hostName;
        if ([host hasSuffix:@"."]) host = [host substringToIndex:host.length - 1];
    }
    NSInteger port = sender.port;
    if (host.length == 0 || port <= 0) return;

    NSString *urlString = [NSString stringWithFormat:@"http://%@:%ld", host, (long)port];
    self.discoveredServerURL = urlString;
    ZLMOD_LOG(@"bridge: discovered LAN server via Bonjour (%@:%ld)", host, (long)port);

    void (^cb)(NSString *, NSString *) = self.discoveryCompletion;
    [self stopLANDiscovery];
    if (cb) {
        cb(urlString, [NSString stringWithFormat:@"Tìm thấy máy chủ LAN: %@", urlString]);
    }
}

- (void)netService:(NSNetService *)sender didNotResolve:(__unused NSDictionary<NSString *, NSNumber *> *)errorDict {
    sender.delegate = nil;
    [self.resolvingServices removeObject:sender];
}

- (void)testWebhookWithCompletion:(void (^)(BOOL success, NSString *message))completion {
    NSString *webhookUrlStr = [[ZLModPreferences shared] stringForKey:kZLModBridgeWebhook defaultValue:@""];
    if (webhookUrlStr.length == 0) {
        if (completion) {
            ZLModRunOnMainThread(^{
                completion(NO, @"Chưa nhập URL Discord Webhook.");
            });
        }
        return;
    }

    if (![ZLModBridgeManager isValidDiscordWebhookURLString:webhookUrlStr]) {
        if (completion) {
            ZLModRunOnMainThread(^{
                completion(NO, @"URL Webhook không hợp lệ (chỉ chấp nhận https://discord.com/api/webhooks/...).");
            });
        }
        return;
    }

    NSURL *url = [NSURL URLWithString:webhookUrlStr];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.timeoutInterval = 8.0;

    NSString *accountScope = ZLModCurrentAccountScope() ?: @"none";
    NSDictionary *body = @{
        @"content": [NSString stringWithFormat:@"🔔 **[ZLMod C-Bridge]** Kiểm tra kết nối Webhook thành công từ iPhone!\nTài khoản: `%@`", accountScope]
    };
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    NSURLSessionDataTask *task = [self.httpSession dataTaskWithRequest:req
                                                     completionHandler:^(__unused NSData *data, NSURLResponse *response, NSError *error) {
        NSHTTPURLResponse *httpResp = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
        NSInteger statusCode = httpResp.statusCode;
        ZLModRunOnMainThread(^{
            if (!error && (statusCode == 200 || statusCode == 204)) {
                if (completion) completion(YES, @"Đã gửi thông báo thử nghiệm tới Discord!");
            } else {
                NSString *errStr = error ? @"Lỗi kết nối mạng tới Discord"
                                         : [NSString stringWithFormat:@"Mã lỗi HTTP %ld", (long)statusCode];
                if (completion) completion(NO, [NSString stringWithFormat:@"Lỗi gửi Webhook: %@", errStr]);
            }
        });
    }];
    [task resume];
}

#pragma mark - Helper Send

- (void)sendJSONDictionary:(NSDictionary *)dict completion:(void (^)(BOOL success))completion {
    NSURLSessionWebSocketTask *task = self.webSocketTask;
    if (!task || self.status != ZLModBridgeStatusConnected) {
        if (completion) {
            ZLModRunOnMainThread(^{ completion(NO); });
        }
        return;
    }

    NSError *err = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:&err];
    if (!data || err) {
        if (completion) {
            ZLModRunOnMainThread(^{ completion(NO); });
        }
        return;
    }

    NSString *str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSURLSessionWebSocketMessage *msg = [[NSURLSessionWebSocketMessage alloc] initWithString:str];
    [task sendMessage:msg completionHandler:^(NSError * _Nullable error) {
        if (completion) {
            ZLModRunOnMainThread(^{
                completion(error == nil);
            });
        }
    }];
}

#pragma mark - Notification Handlers

- (void)handleAppDidBecomeActive {
    ZLModRunOnMainThread(^{
        self.isInBackground = NO;
        if (!self.isManualStop && self.status == ZLModBridgeStatusDisconnected) {
            self.reconnectAttempt = 0;
            [self reconnect];
        }
    });
}

- (void)handleAppDidEnterBackground {
    ZLModRunOnMainThread(^{
        self.isInBackground = YES;
        self.connectionEpoch += 1;
        [self cancelHeartbeat];
        [self cancelPongTimeout];
        [self cancelReconnectTimer];
        self.awaitingPong = NO;

        if (self.webSocketTask) {
            [self transitionToStatus:ZLModBridgeStatusClosing errorMessage:@"" forceNotify:NO];
            NSURLSessionWebSocketTask *task = self.webSocketTask;
            self.webSocketTask = nil;
            [task cancelWithCloseCode:NSURLSessionWebSocketCloseCodeGoingAway reason:nil];
        }
        [self transitionToStatus:ZLModBridgeStatusDisconnected errorMessage:@"" forceNotify:YES];
    });
}

- (void)handlePrefsChanged:(NSNotification *)note {
    NSSet<NSString *> *watched = [NSSet setWithObjects:kZLModBridgeServerURL, kZLModBridgeToken, nil];
    if (ZLModPrefNoteMatchesKeys(note, watched)) {
        self.reconnectAttempt = 0;
        [self reconnect];
    }
}

- (void)handleAccountChanged {
    os_unfair_lock_lock(&_lock);
    [self.csavingDedupSet removeAllObjects];
    [self.csavingDedupOrder removeAllObjects];
    [self.discordDedupSet removeAllObjects];
    [self.discordDedupOrder removeAllObjects];
    os_unfair_lock_unlock(&_lock);

    self.reconnectAttempt = 0;
    [self reconnect];
}

#pragma mark - NSURLSessionWebSocketDelegate

- (void)URLSession:(__unused NSURLSession *)session
     webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask
didOpenWithProtocol:(__unused NSString *)protocol {
    if (webSocketTask != self.webSocketTask) return;
    uint64_t epoch = self.connectionEpoch;
    self.reconnectAttempt = 0;
    ZLMOD_LOG(@"bridge: webSocket connected (epoch=%llu)", (unsigned long long)epoch);
    [self transitionToStatus:ZLModBridgeStatusConnected errorMessage:@"" forceNotify:YES];
    [self startHeartbeatForEpoch:epoch];
    [self sendHeartbeatPing];
    [self flushPendingMessages];
}

- (void)URLSession:(__unused NSURLSession *)session
     webSocketTask:(NSURLSessionWebSocketTask *)webSocketTask
  didCloseWithCode:(NSURLSessionWebSocketCloseCode)closeCode
            reason:(__unused NSData *)reason {
    if (webSocketTask != self.webSocketTask) return;
    ZLMOD_LOG(@"bridge: webSocket closed with code %ld", (long)closeCode);
    [self handleDisconnectForEpoch:self.connectionEpoch
                      errorMessage:[NSString stringWithFormat:@"WebSocket đóng (mã %ld)", (long)closeCode]];
}

- (void)URLSession:(__unused NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    if (task != self.webSocketTask) return;
    if (error) {
        ZLMOD_LOG(@"bridge: socket task failed: %@", error.localizedDescription ?: @"unknown");
        [self handleDisconnectForEpoch:self.connectionEpoch
                          errorMessage:error.localizedDescription ?: @"Lỗi kết nối WebSocket"];
    }
}

@end

#pragma mark - Module Installer

static BOOL gBridgeInstalled = NO;

void ZLModBridgeInstall(void) {
    if (gBridgeInstalled) return;
    gBridgeInstalled = YES;

    ZLModBridgeManager *mgr = [ZLModBridgeManager shared];

    // Subscribe directly to ZLModMessageTapBus — completely decoupled from AntiRecall.
    [[ZLModMessageTapBus shared] registerConsumerNamed:@"BridgeCSavingAndDiscord"
                                                 block:^(ZLModMessageModel *model, __unused id rawEntity, ZLModMessageTapEventKind kind) {
        [mgr handleMessageModel:model eventKind:kind];
    }];

    [mgr start];
    ZLModSetModuleStatus(@"Bridge",
                         ZLModModuleStatusHookInstalled,
                         @"WebSocket FSM + CSaving + CDeploy + Discord Relay + Bonjour LAN");
    ZLMOD_LOG(@"bridge: module installed");
}
