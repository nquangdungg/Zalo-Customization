// language: Objective-C, file: ZLMod.h, target: iOS 15.1+ (Zalo 26.10.02 & 26.11.01, arm64)
// ZLMod umbrella header — shared interfaces across MODULE 01 through MODULE 11.

#ifndef ZLMOD_H
#define ZLMOD_H

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <float.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#import "ZLModVersionData.h"
#import "ZLModConstants.h"

/** Appends a redacted, formatted line to the ring buffer and <Documents>/ZLMod.log (plus App Group fallback). */
void ZLModFileLog(NSString *format, ...);

#define ZLMOD_LOG(fmt, ...) do { \
    NSString *_zlmodMessage = [NSString stringWithFormat:fmt, ##__VA_ARGS__]; \
    NSString *_zlmodSafe = ZLModRedactText(_zlmodMessage); \
    NSLog(@"[ZLMod] %@", _zlmodSafe); \
    ZLModFileLog(@"[ZLMod] %@", _zlmodSafe); \
} while (0)

#pragma mark - Notifications & status constants

extern NSString *const ZLModPrefsDidChangeNotification;
extern NSString *const ZLModPrefsChangedKeysUserInfoKey;
extern NSString *const ZLModAccountDidChangeNotification;
extern NSString *const ZLModConversationPolicyDidChangeNotification;
extern NSString *const ZLModPolicyThreadIdKey;
extern NSString *const ZLModThemeDidChangeNotification;
extern NSString *const ZLModAntiRecallNoticePrefix;

extern NSString *const ZLModModuleStatusNotInstalled;
extern NSString *const ZLModModuleStatusHookInstalled;

#pragma mark - Preference keys (all BOOL OFF / empty default unless noted)

extern NSString *const kZLModGlassTabBar;          // zlmod.appearance.glass
extern NSString *const kZLModThemePreset;          // zlmod.appearance.themePreset (NSString, default @"")
extern NSString *const kZLModThemeTintHex;         // zlmod.appearance.themeTintHex (NSString, default @"")
extern NSString *const kZLModHideTyping;           // zlmod.privacy.hideTyping
extern NSString *const kZLModHideSeen;             // zlmod.privacy.hideSeen
extern NSString *const kZLModHideReadReceipts;     // zlmod.privacy.hideReadReceipts
extern NSString *const kZLModBlockTracking;        // zlmod.privacy.blockTracking
extern NSString *const kZLModBlockFirebase;        // zlmod.privacy.blockFirebase
extern NSString *const kZLModHideAds;              // zlmod.ads.hide
extern NSString *const kZLModBlockAdRequests;      // zlmod.ads.blockRequests
extern NSString *const kZLModRestoreProfileMusic;  // zlmod.features.profileMusic
extern NSString *const kZLModRestoreGDrive;        // zlmod.features.gdriveBackup
extern NSString *const kZLModRestoreMoreTab;       // zlmod.features.moreTab
extern NSString *const kZLModAntiRecall;           // zlmod.messaging.antiRecall
extern NSString *const kZLModDelaySend;            // zlmod.utilities.delaySend
extern NSString *const kZLModDelaySendSeconds;     // zlmod.utilities.delaySendSeconds (double, default 3.0)
extern NSString *const kZLModDisableShakeToOpen;   // zlmod.settings.disableShakeToOpen (BOOL, default NO)
extern NSString *const kZLModBridgeServerURL;      // zlmod.bridge.serverUrl
extern NSString *const kZLModBridgeToken;          // zlmod.bridge.token (Keychain-backed via ZLModSecretStore)
extern NSString *const kZLModBridgeWebhook;        // zlmod.bridge.webhook (Keychain-backed via ZLModSecretStore)
extern NSString *const kZLModBridgeSaving;         // zlmod.bridge.savingEnabled
extern NSString *const kZLModBridgeDiscordRelay;   // zlmod.bridge.discordRelayEnabled
extern NSString *const kZLModBridgeLastSync;       // zlmod.bridge.lastSyncTime

#pragma mark - Storage health & Keychain secret store (MODULE 03)

typedef NS_ENUM(NSInteger, ZLModStorageHealthState) {
    ZLModStorageHealthReady = 0,
    ZLModStorageHealthAccountUnidentified = 1,
    ZLModStorageHealthKeychainUnavailable = 2
};

ZLModStorageHealthState ZLModCurrentStorageHealth(OSStatus *outStatus);
NSString *ZLModStorageHealthDescription(void);

@interface ZLModSecretStore : NSObject
+ (instancetype)shared;
- (NSString *)secretForKey:(NSString *)key;
- (BOOL)setSecret:(NSString *)value forKey:(NSString *)key errorStatus:(OSStatus *)outStatus;
- (BOOL)removeSecretForKey:(NSString *)key;
- (void)clearAllSecrets;
- (OSStatus)lastErrorStatus;
@end

void ZLModWritePropertyListAsync(id immutableRoot, NSString *storagePath, void (^completion)(BOOL saved));
void ZLModWriteDataAsync(NSData *immutableData, NSString *storagePath, void (^completion)(BOOL saved));
void ZLModFlushDiskIOQueueSync(void);

#pragma mark - ZLModPreferences (MODULE 03)

@interface ZLModPreferences : NSObject
+ (instancetype)shared;
+ (NSSet<NSString *> *)secretPreferenceKeys;
+ (NSSet<NSString *> *)remoteDeployAllowedKeys;
+ (BOOL)isSecretPreferenceKey:(NSString *)key;
- (void)migrateLegacySecretsToKeychainIfNeeded;
- (BOOL)boolForKey:(NSString *)key;
- (void)setBool:(BOOL)value forKey:(NSString *)key;
- (double)doubleForKey:(NSString *)key defaultValue:(double)defaultValue;
- (void)setDouble:(double)value forKey:(NSString *)key;
- (NSString *)stringForKey:(NSString *)key defaultValue:(NSString *)defaultValue;
- (void)setString:(NSString *)value forKey:(NSString *)key;
- (void)removeObjectForKey:(NSString *)key;
/** Runs multiple preference mutations and emits a single coalesced ZLModPrefsDidChangeNotification. */
- (void)performBatchUpdates:(void (^)(void))block;
/** Applies only keys in allowedKeys inside a single transaction; rejects unknown/secret keys. */
- (NSArray<NSString *> *)applyRemoteSettingsBatch:(NSDictionary<NSString *, id> *)settings
                                      allowedKeys:(NSSet<NSString *> *)allowedKeys;
- (void)resetAllPreferences;
/** Mirrors a value into standard defaults + the Zalo settings App Group, remembering the previous value. */
- (void)writeExternalValue:(id)value forKey:(NSString *)key;
- (void)restoreExternalValueForKey:(NSString *)key;
@end

#pragma mark - Runtime hook engine & safe property readers (MODULE 02)

void ZLModEnumerateAppClasses(void (^enumerator)(Class cls));
void ZLModPrewarmSelectorIndex(NSArray<NSString *> *selectorNames);
NSArray<Class> *ZLModClassesImplementingInstanceSelector(SEL sel);
BOOL ZLModIsAppRelatedClass(Class cls);
BOOL ZLModClassHasInstanceMethod(Class cls, SEL sel);
BOOL ZLModClassHasClassMethod(Class cls, SEL sel);
BOOL ZLModClassHasIvar(Class cls, const char *name);

BOOL ZLModReplaceMethod(Class cls, SEL sel, NSUInteger declaredArgs,
                        const char *allowedReturns, id hookBlock);
BOOL ZLModReplaceClassMethod(Class cls, SEL sel, NSUInteger declaredArgs,
                             const char *allowedReturns, id hookBlock);

id ZLModSafeObjectProperty(id obj, SEL sel);
NSString *ZLModSafeStringProperty(id obj, SEL sel);
BOOL ZLModSafeBoolProperty(id obj, SEL sel, BOOL defaultValue);
int64_t ZLModSafeInt64Property(id obj, SEL sel, int64_t defaultValue);
double ZLModSafeDoubleProperty(id obj, SEL sel, double defaultValue);
UIWindow *ZLModActiveKeyWindow(void);
UIViewController *ZLModTopPresenterViewController(void);
BOOL ZLModIsAnyTextInputActive(void);

#pragma mark - ChatEntity Adapter & Normalized Message Model (MODULE 02)

@interface ZLModMessageModel : NSObject <NSCopying>
@property (nonatomic, readonly) int64_t globalId;
@property (nonatomic, readonly) int64_t clientId;
@property (nonatomic, readonly, copy) NSString *msgIdString;
@property (nonatomic, readonly, copy) NSString *cliMsgIdString;
@property (nonatomic, readonly, copy) NSString *threadId;
@property (nonatomic, readonly) NSInteger threadType;
@property (nonatomic, readonly, copy) NSString *senderId;
@property (nonatomic, readonly, copy) NSString *senderName;
@property (nonatomic, readonly, copy) NSString *text;
@property (nonatomic, readonly, copy) NSString *originRecallText;
@property (nonatomic, readonly, copy) NSString *msgType;
@property (nonatomic, readonly) NSTimeInterval timestampSec;
@property (nonatomic, readonly) int64_t timestampMs;
@property (nonatomic, readonly) BOOL isSelf;
@property (nonatomic, readonly) BOOL isGroup;
@property (nonatomic, readonly) BOOL isRecalled;
@property (nonatomic, readonly) BOOL hasPhotoAttachment;
@property (nonatomic, readonly, copy) NSString *accountScope;
@property (nonatomic, readonly, copy) NSString *identityKey;
@end

@interface ZLModChatEntityAdapter : NSObject
+ (ZLModMessageModel *)modelFromChatEntity:(id)chatEntity fallbackThreadId:(NSString *)fallbackThreadId;
+ (BOOL)isPlaceholderRecalledText:(NSString *)text;
+ (UIImage *)extractPhotoImageFromChatEntity:(id)chatEntity;
+ (NSString *)extractThreadIdFromObject:(id)obj;
+ (NSString *)extractConversationTypeFromObject:(id)obj;
+ (NSString *)extractDisplayTitleFromObject:(id)obj;
+ (NSDictionary<NSString *, id> *)csavingDictionaryFromModel:(ZLModMessageModel *)model;
@end

#pragma mark - Decoupled Message Tap Bus (MODULE 07)

typedef NS_ENUM(NSInteger, ZLModMessageTapEventKind) {
    ZLModMessageTapEventObserved = 0,
    ZLModMessageTapEventRecalled = 1
};

typedef void (^ZLModMessageTapConsumer)(ZLModMessageModel *model, id rawEntity, ZLModMessageTapEventKind kind);

@interface ZLModMessageTapBus : NSObject
+ (instancetype)shared;
- (NSString *)registerConsumerNamed:(NSString *)name block:(ZLModMessageTapConsumer)block;
- (void)unregisterConsumerWithToken:(NSString *)token;
- (BOOL)hasActiveTapDemand;
- (void)publishRawEntity:(id)chatEntity fallbackThreadId:(NSString *)fallbackThreadId kind:(ZLModMessageTapEventKind)kind;
- (void)clearDedupCache;
@end

#pragma mark - Diagnostics, hashing & account scope (MODULE 01 & 03)

NSString *ZLModRedactText(NSString *input);
NSArray<NSString *> *ZLModReadRecentLogs(NSUInteger maxLines);
void ZLModClearLogs(void);
NSString *ZLModPrimaryLogPath(void);

void ZLModSetModuleStatus(NSString *moduleName, NSString *status, NSString *detail);
NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *ZLModAllModuleStatuses(void);

NSString *ZLModSha256Hex(NSString *input);
NSString *ZLModSafeIdHash(NSString *identifier);
NSString *ZLModCurrentRawUserId(void);
NSString *ZLModCurrentAccountScope(void);
NSArray<NSString *> *ZLModCandidateAccountScopesForMigration(void);
void ZLModInvalidateCachedAccountScope(void);

#pragma mark - Encrypted local storage box (MODULE 03)

@interface ZLModCryptoBox : NSObject
+ (instancetype)shared;
- (BOOL)isReady;
- (OSStatus)lastKeychainStatus;
- (NSData *)encryptData:(NSData *)plainData metadata:(NSData *)metadata;
- (NSData *)decryptRawData:(NSData *)packageData metadata:(NSData *)metadata;
- (NSData *)encryptString:(NSString *)plainText metadata:(NSData *)metadata;
- (NSString *)decryptData:(NSData *)packageData metadata:(NSData *)metadata;
@end

#pragma mark - Per-conversation policies & chat context (MODULE 05)

typedef NS_ENUM(NSInteger, ZLModSeenPolicy) {
    ZLModSeenPolicyFollowOriginal = 0,
    ZLModSeenPolicyHideSeen = 1
};

typedef NS_ENUM(NSInteger, ZLModTypingPolicy) {
    ZLModTypingPolicyFollowOriginal = 0,
    ZLModTypingPolicyHideTyping = 1
};

@interface ZLModPrivacyContext : NSObject
+ (void)noteChatControllerDidAppear:(id)controller
                           threadId:(NSString *)threadId
                   conversationType:(NSString *)convType;
+ (void)noteChatControllerWillDisappear:(id)controller;
+ (id)activeChatController;
+ (NSString *)activeThreadId;
+ (NSString *)activeConversationType;
+ (void)clearActiveContext;
@end

@interface ZLModConversationPolicyStore : NSObject
+ (instancetype)shared;
- (ZLModSeenPolicy)seenPolicyForAccountScope:(NSString *)accountScope
                             conversationType:(NSString *)convType
                                     threadId:(NSString *)threadId;
- (BOOL)setSeenPolicy:(ZLModSeenPolicy)policy
      forAccountScope:(NSString *)accountScope
     conversationType:(NSString *)convType
             threadId:(NSString *)threadId;
- (BOOL)isHideSeenForThreadId:(NSString *)threadId conversationType:(NSString *)convType;

- (ZLModTypingPolicy)typingPolicyForAccountScope:(NSString *)accountScope
                                 conversationType:(NSString *)convType
                                         threadId:(NSString *)threadId;
- (BOOL)setTypingPolicy:(ZLModTypingPolicy)policy
        forAccountScope:(NSString *)accountScope
       conversationType:(NSString *)convType
               threadId:(NSString *)threadId;
- (BOOL)isHideTypingForThreadId:(NSString *)threadId conversationType:(NSString *)convType;

- (BOOL)isLocalUnreadForAccountScope:(NSString *)accountScope
                     conversationType:(NSString *)convType
                             threadId:(NSString *)threadId;
- (BOOL)setLocalUnread:(BOOL)marked
       forAccountScope:(NSString *)accountScope
      conversationType:(NSString *)convType
              threadId:(NSString *)threadId;
- (BOOL)isLocalUnreadAnyTypeForThreadId:(NSString *)threadId;

- (void)updateDisplayTitle:(NSString *)displayTitle
           forAccountScope:(NSString *)accountScope
          conversationType:(NSString *)convType
                  threadId:(NSString *)threadId;

- (NSArray<NSDictionary<NSString *, id> *> *)summaryEntriesForCurrentAccount;
- (NSUInteger)customizedCountForCurrentAccount;
- (BOOL)resetPolicyAtCompoundKey:(NSString *)compoundKey;
- (NSUInteger)resetPoliciesForCurrentAccount;
- (void)resetAllPolicies;
@end

#pragma mark - Anti-Recall store (MODULE 07)

@interface ZLModAntiRecallStore : NSObject
+ (instancetype)shared;
- (BOOL)saveSnapshotWithGlobalId:(int64_t)globalId
                        clientId:(int64_t)clientId
                         message:(NSString *)message
                      senderName:(NSString *)senderName
                        senderId:(NSString *)senderId
                        threadId:(NSString *)threadId
                       timestamp:(NSTimeInterval)timestamp;
- (BOOL)saveSnapshotFromModel:(ZLModMessageModel *)model photoImage:(UIImage *)photoImage;
- (NSString *)recalledTextForGlobalId:(int64_t)globalId clientId:(int64_t)clientId;
- (NSString *)formattedNoticeForGlobalId:(int64_t)globalId clientId:(int64_t)clientId;
- (UIImage *)preservedPhotoForGlobalId:(int64_t)globalId clientId:(int64_t)clientId;
- (NSArray<NSDictionary<NSString *, id> *> *)entriesForCurrentAccount;
- (NSString *)revealTextForEntryKey:(NSString *)entryKey;
- (NSUInteger)preservedCountForCurrentAccount;
- (void)clearCurrentAccountHistory;
- (void)clearAllHistory;
- (void)pruneExpiredEntries;
@end

#pragma mark - Utilities (MODULE 08)

typedef NS_ENUM(NSInteger, ZLModDelaySendState) {
    ZLModDelaySendStatePending = 0,
    ZLModDelaySendStateCancelled = 1,
    ZLModDelaySendStateDispatching = 2,
    ZLModDelaySendStateDispatched = 3,
    ZLModDelaySendStateFailed = 4
};

@interface ZLModPrivateNotesStore : NSObject
+ (instancetype)shared;
- (NSString *)noteForThreadId:(NSString *)threadId;
- (BOOL)setNote:(NSString *)note forThreadId:(NSString *)threadId;
- (BOOL)setNote:(NSString *)note displayTitle:(NSString *)displayTitle forThreadId:(NSString *)threadId;
- (BOOL)removeNoteForThreadId:(NSString *)threadId;
- (NSUInteger)countForCurrentAccount;
- (NSArray<NSDictionary<NSString *, NSString *> *> *)allEntriesForCurrentAccount;
- (void)clearCurrentAccountNotes;
@end

@interface ZLModQuickReplyStore : NSObject
+ (instancetype)shared;
- (NSArray<NSString *> *)quickReplies;
- (BOOL)addQuickReply:(NSString *)text;
- (BOOL)updateQuickReplyAtIndex:(NSUInteger)index withText:(NSString *)text;
- (BOOL)removeQuickReplyAtIndex:(NSUInteger)index;
- (BOOL)moveQuickReplyFromIndex:(NSUInteger)fromIndex toIndex:(NSUInteger)toIndex;
- (void)resetDefaults;
/** Inserts into active chat bar or active text input only; returns NO if none active (never auto-sends). */
- (BOOL)insertTemplateIntoComposer:(NSString *)text;
@end

@interface ZLModDelaySendManager : NSObject
+ (instancetype)shared;
- (NSTimeInterval)delayDuration;
- (void)setDelayDuration:(NSTimeInterval)seconds;
- (NSUInteger)pendingCount;
- (BOOL)cancelPendingSendWithId:(NSString *)sendId;
- (void)cancelAllPendingSends;
@end

#pragma mark - Unified Appearance Coordinator, Theme & Glass (MODULE 09)

@interface ZLModAppearanceCoordinator : NSObject
+ (instancetype)shared;
- (void)captureBaselineForWindowIfNeeded:(UIWindow *)window;
- (void)captureBaselineForNavBarIfNeeded:(UINavigationBar *)navBar;
- (void)captureBaselineForTabBarIfNeeded:(UITabBar *)tabBar;
- (void)registerTabBar:(UITabBar *)tabBar;
- (void)reapplyAllAppearance;
- (void)restoreAllBaselines;
@end

@interface ZLModThemeManager : NSObject
+ (instancetype)shared;
- (NSArray<NSString *> *)availablePresetIds;
- (NSString *)displayNameForPreset:(NSString *)presetId;
- (NSString *)activePresetId;
- (NSString *)customTintHex;
- (BOOL)applyPresetNamed:(NSString *)presetId;
- (BOOL)applyCustomTintHex:(NSString *)hex;
- (void)resetTheme;
- (void)refreshAppChrome;
@end

NSString *ZLModGlassMaterialDescription(void);

#pragma mark - Shared UI Kit & Overlay Helpers (MODULE 04 & 08)

void ZLModRunOnMainThread(dispatch_block_t block);
void ZLModRunOnMainThreadSync(dispatch_block_t block);
void ZLModShowToast(NSString *message);
void ZLModPresentPrivateNoteEditor(UIViewController *presenter,
                                   NSString *threadId,
                                   NSString *displayTitle,
                                   void (^completion)(BOOL saved));
void ZLModPresentQuickReplyPicker(UIViewController *presenter);

#pragma mark - Module installers (called by ZLModCore)

void ZLModMessageTapInstall(void);
void ZLModURIFilterInstall(void);
void ZLModPrivacyInstall(void);
void ZLModAdsInstall(void);
void ZLModFeaturesInstall(void);
void ZLModSettingsInstall(void);
void ZLModGlassInstall(void);
void ZLModConversationMenuInstall(void);
void ZLModAntiRecallInstall(void);
void ZLModUtilitiesInstall(void);
void ZLModThemeInstall(void);
void ZLModBridgeInstall(void);

#pragma mark - Compatibility (MODULE 01)

@interface ZLModCompatibility : NSObject
+ (BOOL)hostSupported;
+ (NSString *)hostVersion;
+ (NSString *)supportReason;
+ (BOOL)anchorExists:(NSString *)className;
@end

#pragma mark - Dashboard UI (MODULE 11)

@interface ZLModSettingsViewController : UITableViewController
+ (instancetype)make;
/** Pushes the dashboard on the host's navigation controller (presents a wrapper if none). */
+ (void)pushFrom:(UIViewController *)host;
@end

#endif /* ZLMOD_H */
