// language: Objective-C, file: ZLModOverlayUI.m, target: iOS 15.1+ (Zalo 26.10.02 & 26.11.01, arm64)
// Shared UI Kit (MODULE 04): main-thread dispatch guarantees and queued accessible
// toast overlay manager. Decouples Core/Bridge/Utilities/UI from ConversationMenu.

#import "ZLMod.h"

void ZLModRunOnMainThread(dispatch_block_t block) {
    if (!block) return;
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_async(dispatch_get_main_queue(), block);
    }
}

void ZLModRunOnMainThreadSync(dispatch_block_t block) {
    if (!block) return;
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
}

#pragma mark - Queued Accessible Toast Overlay Manager

@interface ZLModToastOverlayManager : NSObject
@property (nonatomic, strong) NSMutableArray<NSString *> *queue;
@property (nonatomic, assign) BOOL isShowing;
@property (nonatomic, copy) NSString *currentlyDisplayedMessage;
+ (instancetype)shared;
- (void)enqueueMessage:(NSString *)message;
@end

@implementation ZLModToastOverlayManager

+ (instancetype)shared {
    static ZLModToastOverlayManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ZLModToastOverlayManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _queue = [NSMutableArray array];
        _isShowing = NO;
    }
    return self;
}

- (void)enqueueMessage:(NSString *)message {
    if (![message isKindOfClass:[NSString class]] || message.length == 0) return;
    NSString *copied = [message copy];
    ZLModRunOnMainThread(^{
        // Deduplicate identical consecutive message currently shown or queued last.
        if ([self.currentlyDisplayedMessage isEqualToString:copied] ||
            [self.queue.lastObject isEqualToString:copied]) {
            return;
        }
        if (self.queue.count >= 5) {
            [self.queue removeObjectAtIndex:0];
        }
        [self.queue addObject:copied];
        if (!self.isShowing) {
            [self drainNextOnMain];
        }
    });
}

- (void)drainNextOnMain {
    if (self.queue.count == 0) {
        self.isShowing = NO;
        self.currentlyDisplayedMessage = nil;
        return;
    }

    UIWindow *window = ZLModActiveKeyWindow();
    if (!window) {
        self.isShowing = NO;
        self.currentlyDisplayedMessage = nil;
        [self.queue removeAllObjects];
        return;
    }

    NSString *message = self.queue.firstObject;
    [self.queue removeObjectAtIndex:0];
    self.isShowing = YES;
    self.currentlyDisplayedMessage = message;

    UIView *existing = [window viewWithTag:kZLModToastOverlayViewTag];
    if (existing) {
        [existing removeFromSuperview];
    }

    UIView *banner = [[UIView alloc] init];
    banner.tag = kZLModToastOverlayViewTag;
    banner.userInteractionEnabled = NO;
    banner.isAccessibilityElement = YES;
    banner.accessibilityIdentifier = @"zlmod.toast";
    banner.accessibilityLabel = message;
    banner.backgroundColor = [UIColor colorWithRed:0.09 green:0.10 blue:0.13 alpha:0.94];
    banner.layer.cornerRadius = 18.0;
    banner.layer.masksToBounds = YES;

    UILabel *label = [[UILabel alloc] init];
    label.text = message;
    label.textColor = [UIColor whiteColor];
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    label.adjustsFontForContentSizeCategory = YES;
    label.numberOfLines = 3;
    label.textAlignment = NSTextAlignmentCenter;

    CGFloat maxWidth = MAX(window.bounds.size.width - 36.0, 200.0);
    CGSize textSize = [label sizeThatFits:CGSizeMake(maxWidth - 28.0, 96.0)];
    CGFloat bannerW = MIN(MAX(textSize.width + 28.0, 160.0), maxWidth);
    CGFloat bannerH = MAX(textSize.height + 16.0, 36.0);
    CGFloat topY = MAX(window.safeAreaInsets.top + 8.0, 44.0);

    banner.frame = CGRectMake((window.bounds.size.width - bannerW) * 0.5, topY, bannerW, bannerH);
    label.frame = CGRectInset(banner.bounds, 14.0, 6.0);
    [banner addSubview:label];

    banner.alpha = 0.0;
    banner.transform = CGAffineTransformMakeTranslation(0.0, -8.0);
    [window addSubview:banner];

    if (UIAccessibilityIsVoiceOverRunning()) {
        UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, message);
    }

    __weak typeof(self) weakSelf = self;
    [UIView animateWithDuration:0.20
                     animations:^{
        banner.alpha = 1.0;
        banner.transform = CGAffineTransformIdentity;
    } completion:^(__unused BOOL finished) {
        NSTimeInterval holdTime = (weakSelf.queue.count > 0) ? 1.5 : 2.2;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(holdTime * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.20
                             animations:^{
                banner.alpha = 0.0;
            } completion:^(__unused BOOL done) {
                [banner removeFromSuperview];
                [weakSelf drainNextOnMain];
            }];
        });
    }];
}

@end

void ZLModShowToast(NSString *message) {
    [[ZLModToastOverlayManager shared] enqueueMessage:message];
}
