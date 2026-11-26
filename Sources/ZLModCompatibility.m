// language: Objective-C, file: ZLModCompatibility.m, target: iOS 15.1+ (Zalo 26.10.02 & 26.11.01, arm64)
// Host detection: unified exact manifest match + strict verified runtime anchor quorum.
// Never matches arbitrary bundle substrings ("zalo" / "zing").

#import "ZLMod.h"
#import "ZLModCompatibilityData.h"

static BOOL ZLModHasVerifiedRuntimeAnchorQuorum(void) {
    BOOL hasTabBar = (NSClassFromString(@"ZaloTabBarViewController") != Nil);
    BOOL hasChatData = (NSClassFromString(@"ChatDataManager") != Nil);
    BOOL hasSettings = (NSClassFromString(@"SettingUI40TableViewController") != Nil ||
                        NSClassFromString(@"BasicSettingTableViewController") != Nil);
    return hasTabBar && hasChatData && hasSettings;
}

static void ZLModEvaluateHostCompatibility(BOOL *outSupported, NSString **outReason) {
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    NSString *bundleId = [info[@"CFBundleIdentifier"] isKindOfClass:[NSString class]] ? info[@"CFBundleIdentifier"] : @"";
    NSString *version = [info[@"CFBundleShortVersionString"] isKindOfClass:[NSString class]] ? info[@"CFBundleShortVersionString"] : @"";
    NSString *build = [info[@"CFBundleVersion"] isKindOfClass:[NSString class]] ? info[@"CFBundleVersion"] : @"";

    BOOL versionBuildKnown = NO;
    for (NSDictionary *target in ZLModSupportedHostRecords()) {
        if (![version isEqualToString:target[@"version"]]) continue;
        if (![build isEqualToString:target[@"build"]]) continue;
        versionBuildKnown = YES;
        for (NSString *allowedBundle in target[@"bundleIdentifiers"]) {
            if ([bundleId isEqualToString:allowedBundle]) {
                if (outSupported) *outSupported = YES;
                if (outReason) *outReason = @"supported exact target";
                return;
            }
        }
    }

    // Verified runtime anchor quorum supports re-signed sideload bundle IDs (e.g. free Apple ID)
    // and verified compatible Zalo builds without allowing unrelated apps via substring matching.
    if (ZLModHasVerifiedRuntimeAnchorQuorum()) {
        if (outSupported) *outSupported = YES;
        if (outReason) {
            *outReason = versionBuildKnown
                ? [NSString stringWithFormat:@"compatible host (remapped bundle %@, runtime anchors verified)",
                   bundleId.length > 0 ? bundleId : @"?"]
                : [NSString stringWithFormat:@"compatible host (%@/%@, runtime anchors verified)",
                   version.length > 0 ? version : @"?",
                   build.length > 0 ? build : @"?"];
        }
        return;
    }

    if (outSupported) *outSupported = NO;
    if (outReason) {
        if (versionBuildKnown) {
            *outReason = [NSString stringWithFormat:@"unsupported bundle %@", bundleId.length > 0 ? bundleId : @"?"];
        } else {
            *outReason = [NSString stringWithFormat:@"unsupported version/build %@/%@",
                          version.length > 0 ? version : @"?",
                          build.length > 0 ? build : @"?"];
        }
    }
}

@implementation ZLModCompatibility

+ (BOOL)hostSupported {
    BOOL supported = NO;
    ZLModEvaluateHostCompatibility(&supported, NULL);
    return supported;
}

+ (NSString *)supportReason {
    NSString *reason = @"unsupported host";
    ZLModEvaluateHostCompatibility(NULL, &reason);
    return reason;
}

+ (NSString *)hostVersion {
    NSDictionary *info = [[NSBundle mainBundle] infoDictionary];
    NSString *shortVersion = info[@"CFBundleShortVersionString"] ?: @"?";
    NSString *build = info[@"CFBundleVersion"] ?: @"?";
    return [NSString stringWithFormat:@"%@ (%@) — %@", shortVersion, build, [self supportReason]];
}

+ (BOOL)anchorExists:(NSString *)className {
    if (!className) return NO;
    return NSClassFromString(className) != Nil;
}

@end
