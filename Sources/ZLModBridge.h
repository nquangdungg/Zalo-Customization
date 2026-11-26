// language: Objective-C, file: ZLModBridge.h, target: iOS 15.1+ (Zalo 26.10.02 & 26.11.01, arm64)
// ZLMod C-Bridge client (MODULE 10) — Local Server WebSocket FSM, CPairing + Bonjour LAN
// auto-discovery, decoupled CSaving, allowlisted CDeploy, and automatic Discord Webhook relay.

#ifndef ZLMOD_BRIDGE_H
#define ZLMOD_BRIDGE_H

#import <Foundation/Foundation.h>
#import "ZLMod.h"

typedef NS_ENUM(NSInteger, ZLModBridgeStatus) {
    ZLModBridgeStatusDisconnected = 0,
    ZLModBridgeStatusConnecting   = 1,
    ZLModBridgeStatusConnected    = 2,
    ZLModBridgeStatusClosing      = 3
};

extern NSString *const ZLModBridgeStatusDidChangeNotification;

@interface ZLModBridgeManager : NSObject

+ (instancetype)shared;

+ (BOOL)isValidBridgeServerURLString:(NSString *)urlString;
+ (BOOL)isValidDiscordWebhookURLString:(NSString *)urlString;

@property (nonatomic, readonly) ZLModBridgeStatus status;
@property (nonatomic, readonly) NSTimeInterval lastPingLatencyMs;
@property (nonatomic, readonly) NSUInteger savedMessagesCount;
@property (nonatomic, readonly) NSUInteger pendingMessagesCount;
@property (nonatomic, readonly) NSUInteger discordRelayedCount;
@property (nonatomic, readonly) BOOL isDiscoveringLAN;
@property (nonatomic, readonly, copy) NSString *discoveredServerURL;
@property (nonatomic, readonly, copy) NSString *lastSyncDateString;
@property (nonatomic, readonly, copy) NSString *lastErrorMessage;

- (void)start;
- (void)stop;
- (void)reconnect;

- (void)testPairingWithCompletion:(void (^)(BOOL success, NSString *message, NSTimeInterval latencyMs))completion;
- (void)startLANDiscoveryWithCompletion:(void (^)(NSString *discoveredURL, NSString *message))completion;
- (void)stopLANDiscovery;

- (void)testWebhookWithCompletion:(void (^)(BOOL success, NSString *message))completion;
- (void)uploadCurrentSettingsWithCompletion:(void (^)(BOOL success, NSString *message))completion;

/** Handles a normalized message from ZLModMessageTapBus (decoupled from AntiRecall). */
- (void)handleMessageModel:(ZLModMessageModel *)model eventKind:(ZLModMessageTapEventKind)kind;

/** Backward-compatible entry point wrapping raw ChatEntity through ZLModChatEntityAdapter. */
- (void)enqueueMessageForSaving:(id)chatEntity threadId:(NSString *)threadId;

@end

void ZLModBridgeInstall(void);

#endif /* ZLMOD_BRIDGE_H */
