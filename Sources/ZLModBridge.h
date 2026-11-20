// language: Objective-C, file: ZLModBridge.h, target: iOS 15.1+ (Zalo 26.10.02 & 26.11.01, arm64)
// ZLMod C-Bridge client — Local Server WebSocket connection, CPairing, CSaving, and CDeploy.

#ifndef ZLMOD_BRIDGE_H
#define ZLMOD_BRIDGE_H

#import <Foundation/Foundation.h>
#import "ZLMod.h"

typedef NS_ENUM(NSInteger, ZLModBridgeStatus) {
    ZLModBridgeStatusDisconnected = 0,
    ZLModBridgeStatusConnecting,
    ZLModBridgeStatusConnected
};

extern NSString *const ZLModBridgeStatusDidChangeNotification;

@interface ZLModBridgeManager : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly) ZLModBridgeStatus status;
@property (nonatomic, readonly) NSTimeInterval lastPingLatencyMs;
@property (nonatomic, readonly) NSUInteger savedMessagesCount;
@property (nonatomic, readonly, copy) NSString *lastSyncDateString;

- (void)start;
- (void)stop;
- (void)reconnect;

- (void)testPairingWithCompletion:(void (^)(BOOL success, NSString *message, NSTimeInterval latencyMs))completion;
- (void)testWebhookWithCompletion:(void (^)(BOOL success, NSString *message))completion;
- (void)uploadCurrentSettingsWithCompletion:(void (^)(BOOL success, NSString *message))completion;

- (void)enqueueMessageForSaving:(id)chatEntity threadId:(NSString *)threadId;

@end

void ZLModBridgeInstall(void);

#endif /* ZLMOD_BRIDGE_H */
