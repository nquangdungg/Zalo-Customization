// language: Objective-C, file: ZLModURIFilter.m, target: iOS 15.1+ (Zalo 26.10.02 & 26.11.01, arm64)
// In-process URL blocking for telemetry and ad endpoints via BOTH NSURLProtocol registration
// AND NSURLSessionConfiguration (+defaultSessionConfiguration / +ephemeralSessionConfiguration)
// protocolClasses injection so modern NSURLSession instances cannot bypass filtering.
// Never intercepts C-Bridge local server, Discord webhooks, or WebSocket upgrades.
// Note: out-of-process WKWebView networking runs in WebContent/Networking XPC and cannot be hooked via NSURLProtocol.

#import "ZLMod.h"
#import <os/lock.h>

static os_unfair_lock gURIFilterLock = OS_UNFAIR_LOCK_INIT;
static BOOL gBlockTracking = NO;
static BOOL gBlockAds = NO;
static NSString *gBridgeExemptHost = nil;
static BOOL gURIFilterObserversInstalled = NO;

static BOOL ZLModURLIsExempt(NSURLRequest *request) {
    NSURL *url = request.URL;
    if (!url) return YES;

    // Never intercept WebSocket upgrades.
    NSString *upgrade = [request valueForHTTPHeaderField:@"Upgrade"];
    if (upgrade && [upgrade.lowercaseString isEqualToString:@"websocket"]) return YES;

    NSString *host = url.host.lowercaseString ?: @"";
    if ([host isEqualToString:@"discord.com"] ||
        [host hasSuffix:@".discord.com"] ||
        [host isEqualToString:@"discordapp.com"] ||
        [host hasSuffix:@".discordapp.com"]) {
        return YES;
    }

    os_unfair_lock_lock(&gURIFilterLock);
    NSString *bridgeHost = gBridgeExemptHost;
    os_unfair_lock_unlock(&gURIFilterLock);
    if (bridgeHost.length > 0 && [host isEqualToString:bridgeHost]) {
        return YES;
    }
    return NO;
}

static BOOL ZLModURLIsTracking(NSURL *url) {
    NSString *host = url.host.lowercaseString;
    NSString *path = url.path ?: @"";
    if ([host isEqualToString:@"log.api.zaloapp.com"]) return YES;
    if ([path hasPrefix:@"/tracking"]) return YES;
    if ([path containsString:@"/tracking-v3"]) return YES;
    if ([path containsString:@"/tracking-rt"]) return YES;
    return NO;
}

static BOOL ZLModURLIsAd(NSURL *url) {
    NSString *host = url.host.lowercaseString;
    NSString *path = url.path ?: @"";
    if ([host isEqualToString:@"ads.platform.zalo.me"]) return YES;
    if ([path containsString:@"/zpads/"]) return YES;
    if ([path containsString:@"/get/ads"]) return YES;
    if ([path containsString:@"/ads_out_stream"]) return YES;
    if ([path containsString:@"/ads_boost"]) return YES;
    if ([path containsString:@"/v1/ads/"]) return YES;
    return NO;
}

@interface ZLModBlockURLProtocol : NSURLProtocol
@end

@implementation ZLModBlockURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if (!request.URL) return NO;
    NSString *scheme = request.URL.scheme.lowercaseString;
    if (!([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])) return NO;
    if ([NSURLProtocol propertyForKey:@"ZLModHandled" inRequest:request]) return NO;
    if (ZLModURLIsExempt(request)) return NO;

    os_unfair_lock_lock(&gURIFilterLock);
    BOOL blockTrack = gBlockTracking;
    BOOL blockAds = gBlockAds;
    os_unfair_lock_unlock(&gURIFilterLock);

    if (blockTrack && ZLModURLIsTracking(request.URL)) return YES;
    if (blockAds && ZLModURLIsAd(request.URL)) return YES;
    return NO;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSMutableURLRequest *mutableRequest = [self.request mutableCopy];
    if (mutableRequest) {
        [NSURLProtocol setProperty:@YES forKey:@"ZLModHandled" inRequest:mutableRequest];
    }
    BOOL isTrack = ZLModURLIsTracking(self.request.URL);
    ZLMOD_LOG(@"blocked %@ endpoint: %@%@", isTrack ? @"tracking" : @"ads",
              self.request.URL.host ?: @"", self.request.URL.path ?: @"");
    NSHTTPURLResponse *response =
        [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
                                    statusCode:204
                                   HTTPVersion:@"HTTP/1.1"
                                  headerFields:@{ @"Content-Length": @"0" }];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)stopLoading {
}

@end

static NSURLSessionConfiguration *ZLModAttachProtocolToConfiguration(NSURLSessionConfiguration *config) {
    if (!config) return nil;
    NSArray<Class> *existing = config.protocolClasses ?: @[];
    if (![existing containsObject:[ZLModBlockURLProtocol class]]) {
        NSMutableArray<Class> *updated = [NSMutableArray arrayWithObject:[ZLModBlockURLProtocol class]];
        [updated addObjectsFromArray:existing];
        config.protocolClasses = [updated copy];
    }
    return config;
}

static NSUInteger ZLModInstallSessionConfigurationHooks(void) {
    Class cfgCls = [NSURLSessionConfiguration class];
    if (!cfgCls) return 0;
    NSUInteger count = 0;

    SEL defSel = @selector(defaultSessionConfiguration);
    if (ZLModClassHasClassMethod(cfgCls, defSel)) {
        IMP orig = class_getMethodImplementation(object_getClass(cfgCls), defSel);
        if (ZLModReplaceClassMethod(cfgCls, defSel, 0, "@", ^id(id clsSelf) {
            NSURLSessionConfiguration *cfg = orig ? ((id (*)(id, SEL))orig)(clsSelf, defSel) : nil;
            return ZLModAttachProtocolToConfiguration(cfg);
        })) {
            count++;
        }
    }

    SEL ephSel = @selector(ephemeralSessionConfiguration);
    if (ZLModClassHasClassMethod(cfgCls, ephSel)) {
        IMP orig = class_getMethodImplementation(object_getClass(cfgCls), ephSel);
        if (ZLModReplaceClassMethod(cfgCls, ephSel, 0, "@", ^id(id clsSelf) {
            NSURLSessionConfiguration *cfg = orig ? ((id (*)(id, SEL))orig)(clsSelf, ephSel) : nil;
            return ZLModAttachProtocolToConfiguration(cfg);
        })) {
            count++;
        }
    }

    return count;
}

static void ZLModURIFilterRefresh(void) {
    ZLModPreferences *prefs = [ZLModPreferences shared];
    BOOL track = [prefs boolForKey:kZLModBlockTracking];
    BOOL ads = [prefs boolForKey:kZLModBlockAdRequests];
    NSString *bridgeStr = [prefs stringForKey:kZLModBridgeServerURL defaultValue:@""];
    NSURL *bridgeUrl = bridgeStr.length > 0 ? [NSURL URLWithString:bridgeStr] : nil;
    NSString *exemptHost = bridgeUrl.host.lowercaseString;

    os_unfair_lock_lock(&gURIFilterLock);
    gBlockTracking = track;
    gBlockAds = ads;
    gBridgeExemptHost = [exemptHost copy];
    os_unfair_lock_unlock(&gURIFilterLock);
}

void ZLModURIFilterInstall(void) {
    ZLModURIFilterRefresh();
    if (!gURIFilterObserversInstalled) {
        gURIFilterObserversInstalled = YES;
        [[NSNotificationCenter defaultCenter] addObserverForName:ZLModPrefsDidChangeNotification
                                                          object:nil
                                                           queue:nil
                                                      usingBlock:^(NSNotification *note) {
            NSString *key = [note.object isKindOfClass:[NSString class]] ? (NSString *)note.object : @"";
            if ([key isEqualToString:kZLModBlockTracking] ||
                [key isEqualToString:kZLModBlockAdRequests] ||
                [key isEqualToString:kZLModBridgeServerURL] ||
                [key isEqualToString:@"*"]) {
                ZLModURIFilterRefresh();
            }
        }];
    }

    BOOL registered = [NSURLProtocol registerClass:[ZLModBlockURLProtocol class]];
    NSUInteger sessionHooks = ZLModInstallSessionConfigurationHooks();
    ZLModSetModuleStatus(@"URIFilter",
                         (registered || sessionHooks > 0) ? ZLModModuleStatusHookInstalled : ZLModModuleStatusNotInstalled,
                         [NSString stringWithFormat:@"protocol=%d sessionConfigHooks=%lu",
                          registered, (unsigned long)sessionHooks]);
    ZLMOD_LOG(@"URL filter installed (protocol=%d sessionConfigHooks=%lu)", registered, (unsigned long)sessionHooks);
}
