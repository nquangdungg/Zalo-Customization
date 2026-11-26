// language: Objective-C, file: ZLModConstants.h, target: iOS 15.1+ (Zalo 26.10.02 & 26.11.01, arm64)
// Centralized constants — eliminates magic numbers and scattered configuration values.

#ifndef ZLMOD_CONSTANTS_H
#define ZLMOD_CONSTANTS_H

#import <Foundation/Foundation.h>

#pragma mark - Storage suites, paths & Keychain identifiers

static NSString *const kZLModPreferencesSuiteName     = @"vn.com.vng.zingalo.zlmod";
static NSString *const kZLModAppGroupSuiteName        = @"group.zsettings.vn.com.vng.zingalo";
static NSString *const kZLModPrevExternalPrefix       = @"zlmod.internal.prev.";
static NSString *const kZLModKeychainServiceName      = @"vn.com.vng.zingalo.zlmod.keystore";
static NSString *const kZLModKeychainMasterKeyAccount = @"master_key_v2";
static NSString *const kZLModKeychainSecretPrefix     = @"secret.v1.";

#pragma mark - View tags & action IDs

static const NSInteger kZLModUnreadBlueDotViewTag = 0x5A1D;
static const NSInteger kZLModUndoBannerViewTag    = 0x5A1E;
static const NSInteger kZLModToastOverlayViewTag  = 0x5A1F;
static const NSInteger kZLModSettingsButtonTag    = 0x5A20;

static const NSInteger kZLModConvActionHideSeen    = 98001;
static const NSInteger kZLModConvActionHideTyping  = 98002;
static const NSInteger kZLModConvActionLocalUnread = 98003;
static const NSInteger kZLModConvActionPrivateNote = 98004;

static const NSInteger kZLModActionUnhideRecall = 99001;
static const NSInteger kZLModActionHideRecall   = 99002;

#pragma mark - Logging & persistence bounds

static const NSUInteger kZLModLogRingCapacity             = 200;
static const unsigned long long kZLModLogMaxFileBytes     = 512ULL * 1024ULL;
static const NSUInteger kZLModLogKeepTailBytes            = 256U * 1024U;

static const NSUInteger kZLModMenuSessionMaxCount         = 32;
static const NSTimeInterval kZLModMenuSessionTTLSeconds   = 120.0;

static const NSUInteger kZLModAntiRecallMaxLiveSnapshots  = 500;
static const NSUInteger kZLModAntiRecallMaxRecordsPerAcc  = 400;
static const NSTimeInterval kZLModAntiRecallTTLSeconds    = 14.0 * 86400.0;
static const unsigned long long kZLModAntiRecallMaxPhotoBytes = 20ULL * 1024ULL * 1024ULL;

static const NSUInteger kZLModMaxQuickRepliesCount        = 50;
static const NSTimeInterval kZLModDelaySendMinSeconds     = 1.0;
static const NSTimeInterval kZLModDelaySendMaxSeconds     = 10.0;
static const NSTimeInterval kZLModDelaySendDefaultSeconds = 3.0;

#pragma mark - Message tap & C-Bridge limits

static const NSUInteger kZLModMessageTapDedupCapacity     = 1000;
static const NSUInteger kZLModBridgeMaxPendingMessages    = 50;
static const NSUInteger kZLModBridgeDedupCapacity         = 500;
static const NSTimeInterval kZLModBridgeHeartbeatSeconds  = 20.0;
static const NSTimeInterval kZLModBridgePongTimeoutSec    = 10.0;
static const NSTimeInterval kZLModBridgeReconnectMinSec   = 2.0;
static const NSTimeInterval kZLModBridgeReconnectMaxSec   = 30.0;
static const NSTimeInterval kZLModDiscordMinIntervalSec   = 1.5;

#endif /* ZLMOD_CONSTANTS_H */
