// language: Objective-C, file: ZLModUI.m, target: iOS 15.1+ (Zalo 26.10.02 & 26.11.01, arm64)
// ZLMod Customize dashboard & child management screens (MODULE 11):
//   S01: ZLModSettingsViewController (main dashboard + live Bridge/Theme/Policy/Account/Storage updates)
//   S02: ZLModBridgeViewController (CPairing + Bonjour LAN discovery + CSaving + CDeploy + Discord Relay)
//   S03: ZLModConversationPoliciesViewController (real conversation titles + storage health banner)
//   S04: ZLModAntiRecallHistoryViewController (cached date formatter, photo preview, safe decrypt errors)
//   S05: ZLModQuickRepliesViewController (account-scoped CRUD, validation toasts, reset confirmation)
//   S06: ZLModPrivateNotesViewController (real conversation titles, multi-line editor, storage health banner)
//   S07: ZLModModuleStatusViewController (live hook status + pull-to-refresh)
//   S08: ZLModLogViewerController (redacted log viewer + pull-to-refresh + copy/clear)

#import "ZLMod.h"
#import "ZLModBridge.h"

#pragma mark - Shared UI Helpers

static NSString *ZLModFormatTimestamp(NSTimeInterval ts) {
    static NSDateFormatter *fmt = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    });
    if (ts <= 0) return @"—";
    return [fmt stringFromDate:[NSDate dateWithTimeIntervalSince1970:ts]] ?: @"—";
}

static UIActivityIndicatorView *ZLModMakeSpinnerAccessory(void) {
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    [spinner startAnimating];
    return spinner;
}

static UIView *ZLModStorageHealthHeaderViewForWidth(CGFloat width) {
    OSStatus kcStatus = errSecSuccess;
    ZLModStorageHealthState state = ZLModCurrentStorageHealth(&kcStatus);
    if (state == ZLModStorageHealthReady) return nil;

    CGFloat w = MAX(width, 320.0);
    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 72.0)];
    container.backgroundColor = [UIColor clearColor];

    UIView *banner = [[UIView alloc] init];
    banner.translatesAutoresizingMaskIntoConstraints = NO;
    banner.layer.cornerRadius = 12.0;
    banner.backgroundColor = (state == ZLModStorageHealthKeychainUnavailable)
        ? [[UIColor systemRedColor] colorWithAlphaComponent:0.14]
        : [[UIColor systemOrangeColor] colorWithAlphaComponent:0.15];

    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    label.adjustsFontForContentSizeCategory = YES;
    label.numberOfLines = 0;
    label.textColor = (state == ZLModStorageHealthKeychainUnavailable)
        ? [UIColor systemRedColor]
        : [UIColor systemOrangeColor];
    label.text = [NSString stringWithFormat:@"⚠️ %@", ZLModStorageHealthDescription()];
    label.isAccessibilityElement = YES;
    label.accessibilityLabel = label.text;

    [banner addSubview:label];
    [container addSubview:banner];

    [NSLayoutConstraint activateConstraints:@[
        [banner.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16.0],
        [banner.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16.0],
        [banner.topAnchor constraintEqualToAnchor:container.topAnchor constant:8.0],
        [banner.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-4.0],

        [label.leadingAnchor constraintEqualToAnchor:banner.leadingAnchor constant:12.0],
        [label.trailingAnchor constraintEqualToAnchor:banner.trailingAnchor constant:-12.0],
        [label.topAnchor constraintEqualToAnchor:banner.topAnchor constant:10.0],
        [label.bottomAnchor constraintEqualToAnchor:banner.bottomAnchor constant:-10.0]
    ]];

    CGSize fitting = [container systemLayoutSizeFittingSize:CGSizeMake(w, UILayoutFittingCompressedSize.height)
                              withHorizontalFittingPriority:UILayoutPriorityRequired
                                    verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
    container.frame = CGRectMake(0, 0, w, MAX(fitting.height, 56.0));
    return container;
}

static NSString *ZLModBridgeStatusText(ZLModBridgeManager *mgr, UIColor **outColor) {
    switch (mgr.status) {
        case ZLModBridgeStatusConnected:
            if (outColor) *outColor = [UIColor systemGreenColor];
            if (mgr.lastPingLatencyMs > 0.0) {
                return [NSString stringWithFormat:@"Connected (%.0f ms)", mgr.lastPingLatencyMs];
            }
            return @"Connected";
        case ZLModBridgeStatusConnecting:
            if (outColor) *outColor = [UIColor systemOrangeColor];
            return @"Connecting...";
        case ZLModBridgeStatusClosing:
            if (outColor) *outColor = [UIColor systemOrangeColor];
            return @"Closing...";
        case ZLModBridgeStatusDisconnected:
        default:
            if (outColor) *outColor = [UIColor secondaryLabelColor];
            return @"Disconnected";
    }
}

#pragma mark - Lightweight Recalled Photo Viewer (for S04 History)

@interface ZLModHistoryPhotoViewerController : UIViewController <UIScrollViewDelegate>
@property (nonatomic, strong) UIImage *photoImage;
@property (nonatomic, strong) UIScrollView *scrollView;
@property (nonatomic, strong) UIImageView *imageView;
- (instancetype)initWithImage:(UIImage *)image;
@end

@implementation ZLModHistoryPhotoViewerController

- (instancetype)initWithImage:(UIImage *)image {
    self = [super init];
    if (self) {
        _photoImage = image;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Ảnh thu hồi đã lưu";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self
                                                      action:@selector(closeTapped)];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"Lưu ảnh"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(saveTapped)];

    self.scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    self.scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.scrollView.minimumZoomScale = 1.0;
    self.scrollView.maximumZoomScale = 4.0;
    self.scrollView.delegate = self;
    [self.view addSubview:self.scrollView];

    self.imageView = [[UIImageView alloc] initWithImage:self.photoImage];
    self.imageView.contentMode = UIViewContentModeScaleAspectFit;
    self.imageView.frame = self.scrollView.bounds;
    self.imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.imageView.isAccessibilityElement = YES;
    self.imageView.accessibilityLabel = @"Ảnh tin nhắn đã bị thu hồi";
    [self.scrollView addSubview:self.imageView];
}

- (UIView *)viewForZoomingInScrollView:(__unused UIScrollView *)scrollView {
    return self.imageView;
}

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)saveTapped {
    if (!self.photoImage) return;
    UIImageWriteToSavedPhotosAlbum(self.photoImage, nil, NULL, NULL);
    ZLModShowToast(@"Đã lưu ảnh vào Thư viện ảnh");
}

@end

#pragma mark - S02: C-Bridge & Local Server Settings View Controller

@interface ZLModBridgeViewController : UITableViewController
@property (nonatomic, assign) BOOL isTestingPairing;
@property (nonatomic, assign) BOOL isTestingWebhook;
@property (nonatomic, assign) BOOL isUploadingSettings;
@end

@implementation ZLModBridgeViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"C-Bridge & Local Server";
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 48.0;

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self
           selector:@selector(bridgeStateChanged)
               name:ZLModBridgeStatusDidChangeNotification
             object:nil];
    [nc addObserver:self
           selector:@selector(bridgeStateChanged)
               name:ZLModPrefsDidChangeNotification
             object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)bridgeStateChanged {
    ZLModRunOnMainThread(^{
        if (self.isViewLoaded && self.view.window) {
            [self.tableView reloadData];
        }
    });
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    return 5;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case 0: return @"Trạng thái kết nối (CPairing)";
        case 1: return @"Máy chủ cục bộ (Local Server)";
        case 2: return @"Discord Webhook Relay";
        case 3: return @"CDeploy (Đồng bộ Cài đặt)";
        case 4: return @"CSaving (Lưu trữ Tin nhắn)";
        default: return nil;
    }
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    ZLModBridgeManager *mgr = [ZLModBridgeManager shared];
    if (section == 0) {
        if (mgr.lastErrorMessage.length > 0 && mgr.status == ZLModBridgeStatusDisconnected) {
            return [NSString stringWithFormat:@"Lỗi gần nhất: %@\nBạn có thể dùng Quét LAN (Bonjour) hoặc kiểm tra địa chỉ máy chủ.", mgr.lastErrorMessage];
        }
        return @"Hỗ trợ quét tự động qua Bonjour/mDNS trên Wi-Fi LAN hoặc nhập thủ công. Token xác thực luôn được lưu trong iOS Keychain và gửi qua header Authorization.";
    } else if (section == 2) {
        return @"Khi bật, tin nhắn đến và tin nhắn bị thu hồi (kèm nội dung gốc nếu Anti-Recall đã lưu) sẽ tự động chuyển tiếp tới kênh Discord đã cấu hình.";
    } else if (section == 3) {
        return @"Mọi bản cập nhật cấu hình từ máy chủ đều yêu cầu xác nhận hộp thoại và chỉ chấp nhận các khóa cấu hình hợp lệ (không thể ghi đè Token, Webhook hay Server URL).";
    } else if (section == 4) {
        return @"CSaving chạy độc lập với Anti-Recall thông qua ZLModMessageTapBus, tự động loại trùng và giữ nguyên thứ tự tin nhắn khi mạng gián đoạn.";
    }
    return nil;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case 0: return 3;
        case 1: return 2;
        case 2: return 4;
        case 3: return 2;
        case 4: return 2;
        default: return 0;
    }
}

- (UITableViewCell *)dequeueValueCellInTableView:(UITableView *)tableView {
    static NSString *cid = @"ZLModBridgeValueCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:cid];
        cell.textLabel.adjustsFontForContentSizeCategory = YES;
        cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    }
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.textLabel.textColor = [UIColor labelColor];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

- (UITableViewCell *)dequeueActionCellInTableView:(UITableView *)tableView {
    static NSString *cid = @"ZLModBridgeActionCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid];
        cell.textLabel.adjustsFontForContentSizeCategory = YES;
    }
    cell.accessoryView = nil;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.textLabel.textColor = [UIColor systemBlueColor];
    cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    return cell;
}

- (UITableViewCell *)dequeueSwitchCellInTableView:(UITableView *)tableView
                                            title:(NSString *)title
                                               on:(BOOL)isOn
                                           action:(SEL)action {
    static NSString *cid = @"ZLModBridgeSwitchCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cid];
        cell.textLabel.adjustsFontForContentSizeCategory = YES;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    cell.textLabel.text = title;
    cell.textLabel.textColor = [UIColor labelColor];

    UISwitch *sw = [cell.accessoryView isKindOfClass:[UISwitch class]] ? (UISwitch *)cell.accessoryView : [[UISwitch alloc] init];
    [sw removeTarget:nil action:NULL forControlEvents:UIControlEventValueChanged];
    sw.on = isOn;
    [sw addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = sw;
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    ZLModPreferences *prefs = [ZLModPreferences shared];
    ZLModBridgeManager *mgr = [ZLModBridgeManager shared];

    if (indexPath.section == 0) {
        if (indexPath.row == 0) {
            UITableViewCell *cell = [self dequeueValueCellInTableView:tableView];
            cell.textLabel.text = @"Trạng thái CPairing";
            UIColor *statusColor = nil;
            cell.detailTextLabel.text = ZLModBridgeStatusText(mgr, &statusColor);
            cell.detailTextLabel.textColor = statusColor;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            return cell;
        } else if (indexPath.row == 1) {
            UITableViewCell *cell = [self dequeueActionCellInTableView:tableView];
            cell.textLabel.text = self.isTestingPairing ? @"Đang kiểm tra kết nối..." : @"Kiểm tra kết nối ngay (Ping Server)";
            cell.accessoryView = self.isTestingPairing ? ZLModMakeSpinnerAccessory() : nil;
            return cell;
        } else {
            UITableViewCell *cell = [self dequeueActionCellInTableView:tableView];
            cell.textLabel.text = mgr.isDiscoveringLAN ? @"Đang quét mạng LAN (Bonjour)..." : @"Tự động tìm máy chủ LAN (Bonjour)";
            cell.accessoryView = mgr.isDiscoveringLAN ? ZLModMakeSpinnerAccessory() : nil;
            return cell;
        }
    } else if (indexPath.section == 1) {
        UITableViewCell *cell = [self dequeueValueCellInTableView:tableView];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Địa chỉ Server URL";
            NSString *url = [prefs stringForKey:kZLModBridgeServerURL defaultValue:@""];
            cell.detailTextLabel.text = url.length > 0 ? url : @"Chưa nhập (http://...)";
        } else {
            cell.textLabel.text = @"Bridge Token";
            NSString *tok = [prefs stringForKey:kZLModBridgeToken defaultValue:@""];
            cell.detailTextLabel.text = tok.length > 0 ? @"Keychain ••••••" : @"Chưa thiết lập";
        }
        return cell;
    } else if (indexPath.section == 2) {
        if (indexPath.row == 0) {
            return [self dequeueSwitchCellInTableView:tableView
                                                title:@"Tự động chuyển tiếp tới Discord"
                                                   on:[prefs boolForKey:kZLModBridgeDiscordRelay]
                                               action:@selector(discordRelaySwitchChanged:)];
        } else if (indexPath.row == 1) {
            UITableViewCell *cell = [self dequeueValueCellInTableView:tableView];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            cell.textLabel.text = @"Webhook URL";
            NSString *hook = [prefs stringForKey:kZLModBridgeWebhook defaultValue:@""];
            cell.detailTextLabel.text = hook.length > 0 ? @"Keychain (Đã cấu hình)" : @"Chưa nhập";
            return cell;
        } else if (indexPath.row == 2) {
            UITableViewCell *cell = [self dequeueActionCellInTableView:tableView];
            cell.textLabel.text = self.isTestingWebhook ? @"Đang gửi thử tới Discord..." : @"Gửi thông báo kiểm tra tới Discord";
            cell.accessoryView = self.isTestingWebhook ? ZLModMakeSpinnerAccessory() : nil;
            return cell;
        } else {
            UITableViewCell *cell = [self dequeueValueCellInTableView:tableView];
            cell.textLabel.text = @"Tin nhắn đã gửi tới Discord";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu tin", (unsigned long)mgr.discordRelayedCount];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            return cell;
        }
    } else if (indexPath.section == 3) {
        if (indexPath.row == 0) {
            UITableViewCell *cell = [self dequeueActionCellInTableView:tableView];
            cell.textLabel.text = self.isUploadingSettings ? @"Đang tải cài đặt lên máy chủ..." : @"Tải toàn bộ cài đặt lên Máy chủ ngay";
            cell.accessoryView = self.isUploadingSettings ? ZLModMakeSpinnerAccessory() : nil;
            return cell;
        } else {
            UITableViewCell *cell = [self dequeueValueCellInTableView:tableView];
            cell.textLabel.text = @"Lần đồng bộ gần nhất";
            cell.detailTextLabel.text = mgr.lastSyncDateString ?: @"Chưa đồng bộ";
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            return cell;
        }
    } else if (indexPath.section == 4) {
        if (indexPath.row == 0) {
            return [self dequeueSwitchCellInTableView:tableView
                                                title:@"Bật CSaving (Lưu tin nhắn)"
                                                   on:[prefs boolForKey:kZLModBridgeSaving]
                                               action:@selector(savingSwitchChanged:)];
        } else {
            UITableViewCell *cell = [self dequeueValueCellInTableView:tableView];
            cell.textLabel.text = @"Tin nhắn đã chuyển tiếp";
            cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu đã gửi • %lu chờ",
                                         (unsigned long)mgr.savedMessagesCount,
                                         (unsigned long)mgr.pendingMessagesCount];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            return cell;
        }
    }

    return [self dequeueValueCellInTableView:tableView];
}

- (void)savingSwitchChanged:(UISwitch *)sw {
    [[ZLModPreferences shared] setBool:sw.on forKey:kZLModBridgeSaving];
}

- (void)discordRelaySwitchChanged:(UISwitch *)sw {
    if (sw.on) {
        NSString *hook = [[ZLModPreferences shared] stringForKey:kZLModBridgeWebhook defaultValue:@""];
        if (![ZLModBridgeManager isValidDiscordWebhookURLString:hook]) {
            sw.on = NO;
            ZLModShowToast(@"Hãy cấu hình Discord Webhook URL hợp lệ trước khi bật.");
            return;
        }
    }
    [[ZLModPreferences shared] setBool:sw.on forKey:kZLModBridgeDiscordRelay];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    ZLModPreferences *prefs = [ZLModPreferences shared];
    ZLModBridgeManager *mgr = [ZLModBridgeManager shared];

    if (indexPath.section == 0 && indexPath.row == 1) {
        if (self.isTestingPairing) return;
        self.isTestingPairing = YES;
        [self.tableView reloadData];
        __weak typeof(self) weakSelf = self;
        [mgr testPairingWithCompletion:^(__unused BOOL success, NSString *message, __unused NSTimeInterval latencyMs) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.isTestingPairing = NO;
            ZLModShowToast(message);
            [strongSelf.tableView reloadData];
        }];
    } else if (indexPath.section == 0 && indexPath.row == 2) {
        if (mgr.isDiscoveringLAN) {
            [mgr stopLANDiscovery];
            ZLModShowToast(@"Đã dừng quét mạng LAN");
            return;
        }
        __weak typeof(self) weakSelf = self;
        [mgr startLANDiscoveryWithCompletion:^(NSString *discoveredURL, NSString *message) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (discoveredURL.length > 0) {
                UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"Tìm thấy máy chủ C-Bridge"
                                                                                 message:[NSString stringWithFormat:@"Áp dụng địa chỉ %@ làm Local Server?", discoveredURL]
                                                                          preferredStyle:UIAlertControllerStyleAlert];
                [confirm addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
                [confirm addAction:[UIAlertAction actionWithTitle:@"Áp dụng"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(__unused UIAlertAction *action) {
                    [prefs setString:discoveredURL forKey:kZLModBridgeServerURL];
                    ZLModShowToast(@"Đã cập nhật Server URL và đang kết nối...");
                }]];
                [strongSelf presentViewController:confirm animated:YES completion:nil];
            } else {
                ZLModShowToast(message);
            }
            [strongSelf.tableView reloadData];
        }];
    } else if (indexPath.section == 1) {
        if (indexPath.row == 0) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Địa chỉ Local Server"
                                                                           message:@"Nhập IP và Port của máy chủ trong mạng LAN (VD: http://192.168.1.15:3000). Để trống để ngắt kết nối."
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull tf) {
                tf.placeholder = @"http://192.168.1.x:3000";
                tf.text = [prefs stringForKey:kZLModBridgeServerURL defaultValue:@""];
                tf.keyboardType = UIKeyboardTypeURL;
                tf.autocorrectionType = UITextAutocorrectionTypeNo;
                tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
                tf.clearButtonMode = UITextFieldViewModeWhileEditing;
            }];
            [alert addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
            [alert addAction:[UIAlertAction actionWithTitle:@"Lưu" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                NSString *raw = alert.textFields.firstObject.text ?: @"";
                NSString *trimmed = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (trimmed.length > 0 && ![ZLModBridgeManager isValidBridgeServerURLString:trimmed]) {
                    ZLModShowToast(@"URL không hợp lệ — cần bắt đầu bằng http:// hoặc https://");
                    return;
                }
                [prefs setString:trimmed forKey:kZLModBridgeServerURL];
            }]];
            [self presentViewController:alert animated:YES completion:nil];
        } else if (indexPath.row == 1) {
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Bridge Token (iOS Keychain)"
                                                                           message:@"Token được lưu bảo mật trong iOS Keychain (không lưu plaintext trong NSUserDefaults). Để trống để xóa."
                                                                    preferredStyle:UIAlertControllerStyleAlert];
            [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull tf) {
                tf.placeholder = @"Nhập token bí mật mới";
                tf.secureTextEntry = YES;
                tf.autocorrectionType = UITextAutocorrectionTypeNo;
                tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
                tf.clearButtonMode = UITextFieldViewModeWhileEditing;
            }];
            [alert addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
            [alert addAction:[UIAlertAction actionWithTitle:@"Lưu vào Keychain" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                NSString *val = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
                [prefs setString:val forKey:kZLModBridgeToken];
                ZLModShowToast(val.length > 0 ? @"Đã lưu Bridge Token vào iOS Keychain" : @"Đã xóa Bridge Token");
            }]];
            [self presentViewController:alert animated:YES completion:nil];
        }
    } else if (indexPath.section == 2 && indexPath.row == 1) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Discord Webhook URL (iOS Keychain)"
                                                                       message:@"Chỉ chấp nhận URL chính thức https://discord.com/api/webhooks/... Lưu an toàn trong iOS Keychain. Để trống để xóa."
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull tf) {
            tf.placeholder = @"https://discord.com/api/webhooks/...";
            tf.secureTextEntry = YES;
            tf.keyboardType = UIKeyboardTypeURL;
            tf.autocorrectionType = UITextAutocorrectionTypeNo;
            tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
            tf.clearButtonMode = UITextFieldViewModeWhileEditing;
        }];
        [alert addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Lưu vào Keychain" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            NSString *val = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
            if (val.length > 0 && ![ZLModBridgeManager isValidDiscordWebhookURLString:val]) {
                ZLModShowToast(@"URL Discord Webhook không hợp lệ (phải là https://discord.com/api/webhooks/...)");
                return;
            }
            [prefs setString:val forKey:kZLModBridgeWebhook];
            if (val.length == 0) {
                [prefs setBool:NO forKey:kZLModBridgeDiscordRelay];
            }
            ZLModShowToast(val.length > 0 ? @"Đã lưu Webhook vào iOS Keychain" : @"Đã xóa Webhook và tắt relay");
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    } else if (indexPath.section == 2 && indexPath.row == 2) {
        if (self.isTestingWebhook) return;
        self.isTestingWebhook = YES;
        [self.tableView reloadData];
        __weak typeof(self) weakSelf = self;
        [mgr testWebhookWithCompletion:^(__unused BOOL success, NSString *message) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.isTestingWebhook = NO;
            ZLModShowToast(message);
            [strongSelf.tableView reloadData];
        }];
    } else if (indexPath.section == 3 && indexPath.row == 0) {
        if (self.isUploadingSettings) return;
        self.isUploadingSettings = YES;
        [self.tableView reloadData];
        __weak typeof(self) weakSelf = self;
        [mgr uploadCurrentSettingsWithCompletion:^(__unused BOOL success, NSString *message) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.isUploadingSettings = NO;
            ZLModShowToast(message);
            [strongSelf.tableView reloadData];
        }];
    }
}

@end

#pragma mark - S03: Per-Conversation Policies Viewer

@interface ZLModConversationPoliciesViewController : UITableViewController
@property (nonatomic, strong) NSArray<NSDictionary<NSString *, id> *> *entries;
@end

@implementation ZLModConversationPoliciesViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Per-Conversation Policies";
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 52.0;
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"Xóa tất cả"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(clearAllTapped:)];
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(reloadEntries) name:ZLModConversationPolicyDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(reloadEntries) name:ZLModAccountDidChangeNotification object:nil];
    [self reloadEntries];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)reloadEntries {
    ZLModRunOnMainThread(^{
        self.tableView.tableHeaderView = ZLModStorageHealthHeaderViewForWidth(self.view.bounds.size.width);
        self.entries = [[ZLModConversationPolicyStore shared] summaryEntriesForCurrentAccount];
        self.navigationItem.rightBarButtonItem.enabled = (self.entries.count > 0);
        [self.tableView reloadData];
    });
}

- (void)clearAllTapped:(__unused id)sender {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Đặt lại chính sách hội thoại?"
                                                                   message:@"Xóa toàn bộ thiết lập Ẩn đã xem, Ẩn đang nhập và Chấm xanh chưa đọc của tài khoản hiện tại."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Đặt lại"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        [[ZLModConversationPolicyStore shared] resetPoliciesForCurrentAccount];
        [self reloadEntries];
        ZLModShowToast(@"Đã đặt lại chính sách hội thoại");
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section {
    return (NSInteger)MAX(self.entries.count, (NSUInteger)1);
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(__unused NSInteger)section {
    return @"Mẹo: Nhấn giữ vào một cuộc trò chuyện bất kỳ ở danh sách tin nhắn Zalo để bật/tắt Ẩn đã xem, Ẩn đang nhập, Đánh dấu chưa đọc (Chấm xanh) hoặc Ghi chú riêng tư.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.entries.count == 0) {
        static NSString *emptyId = @"ZLModPolicyEmptyCell";
        UITableViewCell *empty = [tableView dequeueReusableCellWithIdentifier:emptyId]
            ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:emptyId];
        ZLModStorageHealthState health = ZLModCurrentStorageHealth(NULL);
        empty.textLabel.text = (health == ZLModStorageHealthReady)
            ? @"Chưa có hội thoại nào được tùy chỉnh riêng"
            : @"Không thể đọc danh sách (xem cảnh báo phía trên)";
        empty.textLabel.textColor = [UIColor secondaryLabelColor];
        empty.textLabel.numberOfLines = 0;
        empty.selectionStyle = UITableViewCellSelectionStyleNone;
        return empty;
    }

    static NSString *cellId = @"ZLModPolicyCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
        cell.textLabel.adjustsFontForContentSizeCategory = YES;
        cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    }

    NSDictionary *entry = self.entries[(NSUInteger)indexPath.row];
    NSString *convType = [entry[@"convType"] isEqualToString:@"group"] ? @"Nhóm" : @"Cá nhân";
    NSString *title = [entry[@"displayTitle"] isKindOfClass:[NSString class]] ? entry[@"displayTitle"] : @"";
    NSString *labelName = (title.length > 0) ? title : (entry[@"threadHash"] ?: @"id");
    cell.textLabel.text = [NSString stringWithFormat:@"%@ • %@", convType, labelName];

    NSMutableArray<NSString *> *flags = [NSMutableArray array];
    if ([entry[@"hideSeen"] boolValue]) [flags addObject:@"Ẩn đã xem"];
    if ([entry[@"hideTyping"] boolValue]) [flags addObject:@"Ẩn đang nhập"];
    if ([entry[@"localUnread"] boolValue]) [flags addObject:@"Chấm xanh chưa đọc"];
    cell.detailTextLabel.text = [flags componentsJoinedByString:@" • "];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.entries.count == 0 || (NSUInteger)indexPath.row >= self.entries.count) return;

    NSDictionary *entry = self.entries[(NSUInteger)indexPath.row];
    NSString *compoundKey = entry[@"key"];
    if (![compoundKey isKindOfClass:[NSString class]]) return;

    NSString *displayTitle = [entry[@"displayTitle"] isKindOfClass:[NSString class]] ? entry[@"displayTitle"] : nil;
    NSString *title = displayTitle.length > 0
        ? displayTitle
        : (entry[@"threadHash"] ?: @"Hội thoại");
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:title
                                                                   message:@"Đặt lại cuộc trò chuyện này về mặc định?"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Khôi phục mặc định"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        [[ZLModConversationPolicyStore shared] resetPolicyAtCompoundKey:compoundKey];
        [self reloadEntries];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) {
        UITableViewCell *c = [tableView cellForRowAtIndexPath:indexPath];
        sheet.popoverPresentationController.sourceView = c ?: self.view;
        sheet.popoverPresentationController.sourceRect = c ? c.bounds : self.view.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

@end

#pragma mark - S04: Anti-Recall Local History Viewer

@interface ZLModAntiRecallHistoryViewController : UITableViewController
@property (nonatomic, strong) NSArray<NSDictionary<NSString *, id> *> *entries;
@end

@implementation ZLModAntiRecallHistoryViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Ghost Preview History";
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 54.0;
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"Xóa lịch sử"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(clearTapped:)];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reloadEntries)
                                                 name:ZLModAccountDidChangeNotification
                                               object:nil];
    [self reloadEntries];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)reloadEntries {
    ZLModRunOnMainThread(^{
        self.tableView.tableHeaderView = ZLModStorageHealthHeaderViewForWidth(self.view.bounds.size.width);
        self.entries = [[ZLModAntiRecallStore shared] entriesForCurrentAccount];
        self.navigationItem.rightBarButtonItem.enabled = (self.entries.count > 0);
        [self.tableView reloadData];
    });
}

- (void)clearTapped:(__unused id)sender {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Xóa bản sao tin nhắn thu hồi?"
                                                                   message:@"Xóa toàn bộ lịch sử Ghost Preview và ảnh đã mã hóa của tài khoản hiện tại."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Xóa sạch"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        [[ZLModAntiRecallStore shared] clearCurrentAccountHistory];
        [self reloadEntries];
        ZLModShowToast(@"Đã xóa lịch sử Anti-Recall");
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section {
    return (NSInteger)MAX(self.entries.count, (NSUInteger)1);
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(__unused NSInteger)section {
    return @"Văn bản và ảnh thu hồi được mã hóa AES-256-CBC + HMAC-SHA256 bằng khóa trong iOS Keychain, tự động hết hạn sau 14 ngày (tối đa 20 MB ảnh). Chạm vào một dòng để giải mã.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.entries.count == 0) {
        static NSString *emptyId = @"ZLModRecallEmptyCell";
        UITableViewCell *empty = [tableView dequeueReusableCellWithIdentifier:emptyId]
            ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:emptyId];
        ZLModStorageHealthState health = ZLModCurrentStorageHealth(NULL);
        empty.textLabel.text = (health == ZLModStorageHealthReady)
            ? @"Chưa có bản sao tin nhắn thu hồi nào"
            : @"Không thể đọc lịch sử (xem cảnh báo phía trên)";
        empty.textLabel.textColor = [UIColor secondaryLabelColor];
        empty.textLabel.numberOfLines = 0;
        empty.selectionStyle = UITableViewCellSelectionStyleNone;
        return empty;
    }

    static NSString *cellId = @"ZLModRecallCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
        cell.textLabel.adjustsFontForContentSizeCategory = YES;
        cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    }

    NSDictionary *rec = self.entries[(NSUInteger)indexPath.row];
    NSString *savedStr = ZLModFormatTimestamp([rec[@"savedAt"] doubleValue]);
    BOOL hasPhoto = [rec[@"hasPhoto"] boolValue];
    NSString *photoTag = hasPhoto ? @" 📷[Ảnh]" : @"";

    cell.textLabel.text = [NSString stringWithFormat:@"Hội thoại %@ • Người gửi %@%@",
                           rec[@"threadHash"] ?: @"none",
                           rec[@"senderHash"] ?: @"none",
                           photoTag];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"Lưu lúc %@ (Chạm để giải mã)", savedStr];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.entries.count == 0 || (NSUInteger)indexPath.row >= self.entries.count) return;

    NSDictionary *rec = self.entries[(NSUInteger)indexPath.row];
    NSString *key = rec[@"key"];
    int64_t gid = [rec[@"globalId"] longLongValue];
    int64_t cid = [rec[@"clientId"] longLongValue];

    NSString *revealed = [[ZLModAntiRecallStore shared] revealTextForEntryKey:key];
    UIImage *preservedPhoto = ([rec[@"hasPhoto"] boolValue])
        ? [[ZLModAntiRecallStore shared] preservedPhotoForGlobalId:gid clientId:cid]
        : nil;

    if (!revealed && !preservedPhoto) {
        UIAlertController *errAlert = [UIAlertController alertControllerWithTitle:@"Không thể giải mã"
                                                                          message:@"Không thể giải mã bản ghi này (khóa Keychain hoặc ngữ cảnh tài khoản không khớp)."
                                                                   preferredStyle:UIAlertControllerStyleAlert];
        [errAlert addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:errAlert animated:YES completion:nil];
        return;
    }

    NSString *displayBody = revealed.length > 0 ? revealed : @"[Chỉ có hình ảnh được lưu]";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Bản sao cục bộ"
                                                                   message:displayBody
                                                            preferredStyle:UIAlertControllerStyleAlert];
    if (preservedPhoto) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Xem ảnh đã lưu"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *action) {
            ZLModHistoryPhotoViewerController *viewer = [[ZLModHistoryPhotoViewerController alloc] initWithImage:preservedPhoto];
            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:viewer];
            [self presentViewController:nav animated:YES completion:nil];
        }]];
    }
    if (revealed.length > 0) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Sao chép"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *action) {
            [UIPasteboard generalPasteboard].string = revealed;
            ZLModShowToast(@"Đã sao chép vào bộ nhớ tạm");
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - S05: Quick Replies View Controller

@interface ZLModQuickRepliesViewController : UITableViewController
@property (nonatomic, strong) NSArray<NSString *> *templates;
@end

@implementation ZLModQuickRepliesViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Quick Reply Templates";
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 48.0;
    UIBarButtonItem *addBtn = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
                                                                            target:self
                                                                            action:@selector(addTapped:)];
    self.navigationItem.rightBarButtonItems = @[addBtn, self.editButtonItem];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reloadTemplates)
                                                 name:ZLModAccountDidChangeNotification
                                               object:nil];
    [self reloadTemplates];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)reloadTemplates {
    ZLModRunOnMainThread(^{
        self.templates = [[ZLModQuickReplyStore shared] quickReplies];
        [self.tableView reloadData];
    });
}

- (void)addTapped:(__unused id)sender {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Thêm mẫu trả lời nhanh"
                                                                   message:@"Nội dung chỉ được điền vào ô nhập tin nhắn (hoặc chọn nhanh từ nút ⚡ trong khung chat), không bao giờ tự động gửi."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Nhập nội dung mẫu...";
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Thêm"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        NSString *text = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
        if (text.length == 0) {
            ZLModShowToast(@"Không thể thêm mẫu câu trống");
            return;
        }
        if ([[ZLModQuickReplyStore shared] addQuickReply:text]) {
            [self reloadTemplates];
            ZLModShowToast(@"Đã thêm mẫu trả lời nhanh");
        } else {
            ZLModShowToast(@"Mẫu câu đã tồn tại hoặc đã đạt giới hạn 50 mẫu");
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    return 2;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return (NSInteger)MAX(self.templates.count, (NSUInteger)1);
    return 1;
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return (section == 0) ? @"Mẫu câu theo tài khoản (Chạm để chèn hoặc sửa)" : @"Tác vụ";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 1) {
        static NSString *resetId = @"ZLModQuickReplyResetCell";
        UITableViewCell *resetCell = [tableView dequeueReusableCellWithIdentifier:resetId]
            ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:resetId];
        resetCell.textLabel.text = @"Khôi phục mẫu câu mặc định";
        resetCell.textLabel.textColor = [UIColor systemRedColor];
        return resetCell;
    }

    if (self.templates.count == 0) {
        static NSString *emptyId = @"ZLModQuickReplyEmptyCell";
        UITableViewCell *empty = [tableView dequeueReusableCellWithIdentifier:emptyId]
            ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:emptyId];
        empty.textLabel.text = @"Chưa có mẫu câu nào (Nhấn + để thêm)";
        empty.textLabel.textColor = [UIColor secondaryLabelColor];
        empty.selectionStyle = UITableViewCellSelectionStyleNone;
        return empty;
    }

    static NSString *cellId = @"ZLModQuickReplyCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cellId];
        cell.textLabel.numberOfLines = 2;
        cell.textLabel.adjustsFontForContentSizeCategory = YES;
    }
    cell.textLabel.text = self.templates[(NSUInteger)indexPath.row];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (BOOL)tableView:(__unused UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return (indexPath.section == 0 && self.templates.count > 0);
}

- (BOOL)tableView:(__unused UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return (indexPath.section == 0 && self.templates.count > 1);
}

- (void)tableView:(__unused UITableView *)tableView
commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle == UITableViewCellEditingStyleDelete && indexPath.section == 0) {
        [[ZLModQuickReplyStore shared] removeQuickReplyAtIndex:(NSUInteger)indexPath.row];
        [self reloadTemplates];
    }
}

- (void)tableView:(__unused UITableView *)tableView
moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath
      toIndexPath:(NSIndexPath *)destinationIndexPath {
    if (sourceIndexPath.section != 0 || destinationIndexPath.section != 0) {
        [self reloadTemplates];
        return;
    }
    [[ZLModQuickReplyStore shared] moveQuickReplyFromIndex:(NSUInteger)sourceIndexPath.row
                                                   toIndex:(NSUInteger)destinationIndexPath.row];
    [self reloadTemplates];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1) {
        UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"Khôi phục mẫu câu mặc định?"
                                                                         message:@"Thao tác này sẽ thay thế toàn bộ danh sách mẫu câu hiện tại của tài khoản bằng 4 mẫu mặc định."
                                                                  preferredStyle:UIAlertControllerStyleAlert];
        [confirm addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
        [confirm addAction:[UIAlertAction actionWithTitle:@"Khôi phục"
                                                    style:UIAlertActionStyleDestructive
                                                  handler:^(__unused UIAlertAction *action) {
            [[ZLModQuickReplyStore shared] resetDefaults];
            [self reloadTemplates];
            ZLModShowToast(@"Đã khôi phục mẫu câu mặc định");
        }]];
        [self presentViewController:confirm animated:YES completion:nil];
        return;
    }
    if (self.templates.count == 0 || (NSUInteger)indexPath.row >= self.templates.count) return;

    NSUInteger rowIdx = (NSUInteger)indexPath.row;
    NSString *templateText = self.templates[rowIdx];

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Mẫu trả lời nhanh"
                                                                   message:templateText
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Chèn vào khung chat đang mở"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        if ([[ZLModQuickReplyStore shared] insertTemplateIntoComposer:templateText]) {
            ZLModShowToast(@"Đã điền vào khung nhập tin nhắn");
        } else {
            [UIPasteboard generalPasteboard].string = templateText;
            ZLModShowToast(@"Không có khung chat đang mở — đã sao chép vào bộ nhớ tạm");
        }
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Chỉnh sửa mẫu câu..."
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        UIAlertController *edit = [UIAlertController alertControllerWithTitle:@"Chỉnh sửa mẫu câu"
                                                                      message:nil
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [edit addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.text = templateText;
        }];
        [edit addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
        [edit addAction:[UIAlertAction actionWithTitle:@"Lưu"
                                                 style:UIAlertActionStyleDefault
                                               handler:^(__unused UIAlertAction *a) {
            NSString *updated = edit.textFields.firstObject.text ?: @"";
            if ([[ZLModQuickReplyStore shared] updateQuickReplyAtIndex:rowIdx withText:updated]) {
                [self reloadTemplates];
                ZLModShowToast(@"Đã cập nhật mẫu câu");
            } else {
                ZLModShowToast(@"Không thể lưu (nội dung trống hoặc trùng mẫu khác)");
            }
        }]];
        [self presentViewController:edit animated:YES completion:nil];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Xóa mẫu này"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        [[ZLModQuickReplyStore shared] removeQuickReplyAtIndex:rowIdx];
        [self reloadTemplates];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) {
        UITableViewCell *c = [tableView cellForRowAtIndexPath:indexPath];
        sheet.popoverPresentationController.sourceView = c ?: self.view;
        sheet.popoverPresentationController.sourceRect = c ? c.bounds : self.view.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

@end

#pragma mark - S06: Encrypted Private Notes Viewer

@interface ZLModPrivateNotesViewController : UITableViewController
@property (nonatomic, strong) NSArray<NSDictionary<NSString *, NSString *> *> *entries;
@end

@implementation ZLModPrivateNotesViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Encrypted Private Notes";
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 56.0;
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"Xóa tất cả"
                                         style:UIBarButtonItemStylePlain
                                        target:self
                                        action:@selector(clearAllTapped:)];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reloadNotes)
                                                 name:ZLModAccountDidChangeNotification
                                               object:nil];
    [self reloadNotes];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)reloadNotes {
    ZLModRunOnMainThread(^{
        self.tableView.tableHeaderView = ZLModStorageHealthHeaderViewForWidth(self.view.bounds.size.width);
        self.entries = [[ZLModPrivateNotesStore shared] allEntriesForCurrentAccount];
        self.navigationItem.rightBarButtonItem.enabled = (self.entries.count > 0);
        [self.tableView reloadData];
    });
}

- (void)clearAllTapped:(__unused id)sender {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Xóa toàn bộ ghi chú?"
                                                                   message:@"Xóa toàn bộ ghi chú riêng tư đã mã hóa của tài khoản hiện tại."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Xóa"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        [[ZLModPrivateNotesStore shared] clearCurrentAccountNotes];
        [self reloadNotes];
        ZLModShowToast(@"Đã xóa tất cả ghi chú riêng tư");
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section {
    return (NSInteger)MAX(self.entries.count, (NSUInteger)1);
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForFooterInSection:(__unused NSInteger)section {
    return @"Mẹo: Nhấn giữ vào một cuộc trò chuyện ở danh sách tin nhắn Zalo rồi chọn \"Ghi chú riêng tư\" để thêm hoặc sửa ghi chú mã hóa nhiều dòng.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.entries.count == 0) {
        static NSString *emptyId = @"ZLModNoteEmptyCell";
        UITableViewCell *empty = [tableView dequeueReusableCellWithIdentifier:emptyId]
            ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:emptyId];
        ZLModStorageHealthState health = ZLModCurrentStorageHealth(NULL);
        empty.textLabel.text = (health == ZLModStorageHealthReady)
            ? @"Chưa có ghi chú riêng tư nào"
            : @"Không thể đọc ghi chú (xem cảnh báo phía trên)";
        empty.textLabel.textColor = [UIColor secondaryLabelColor];
        empty.textLabel.numberOfLines = 0;
        empty.selectionStyle = UITableViewCellSelectionStyleNone;
        return empty;
    }

    static NSString *cellId = @"ZLModNoteCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
        cell.textLabel.adjustsFontForContentSizeCategory = YES;
        cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
        cell.detailTextLabel.numberOfLines = 2;
    }
    NSDictionary *entry = self.entries[(NSUInteger)indexPath.row];
    NSString *title = entry[@"displayTitle"];
    cell.textLabel.text = (title.length > 0)
        ? title
        : [NSString stringWithFormat:@"Hội thoại: %@", entry[@"threadHash"] ?: @"none"];
    cell.detailTextLabel.text = entry[@"note"] ?: @"";
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (self.entries.count == 0 || (NSUInteger)indexPath.row >= self.entries.count) return;
    NSDictionary *entry = self.entries[(NSUInteger)indexPath.row];
    NSString *tid = entry[@"threadId"];
    if (tid.length == 0) return;
    NSString *displayTitle = [entry[@"displayTitle"] isKindOfClass:[NSString class]] ? entry[@"displayTitle"] : nil;
    NSString *title = displayTitle.length > 0 ? displayTitle : entry[@"threadHash"];

    ZLModPresentPrivateNoteEditor(self, tid, title, ^(__unused BOOL saved) {
        [self reloadNotes];
    });
}

@end

#pragma mark - S07: Module Status Viewer

@interface ZLModModuleStatusViewController : UITableViewController
@property (nonatomic, strong) NSArray<NSString *> *moduleNames;
@property (nonatomic, strong) NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *statuses;
@end

@implementation ZLModModuleStatusViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Module Hook Status";
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 52.0;

    UIRefreshControl *rc = [[UIRefreshControl alloc] init];
    [rc addTarget:self action:@selector(refreshStatuses:) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = rc;

    [self reloadStatuses];
}

- (void)refreshStatuses:(UIRefreshControl *)rc {
    [self reloadStatuses];
    [rc endRefreshing];
}

- (void)reloadStatuses {
    self.statuses = ZLModAllModuleStatuses();
    self.moduleNames = [[self.statuses allKeys] sortedArrayUsingSelector:@selector(compare:)];
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section {
    return (NSInteger)self.moduleNames.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellId = @"ZLModStatusCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
        cell.textLabel.adjustsFontForContentSizeCategory = YES;
        cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
        cell.detailTextLabel.numberOfLines = 0;
    }
    NSString *name = self.moduleNames[(NSUInteger)indexPath.row];
    NSDictionary *info = self.statuses[name];
    NSString *status = info[@"status"] ?: ZLModModuleStatusNotInstalled;
    NSString *detail = info[@"detail"] ?: @"";
    BOOL installed = [status isEqualToString:ZLModModuleStatusHookInstalled];

    cell.textLabel.text = [NSString stringWithFormat:@"%@ — %@", name, status];
    cell.textLabel.textColor = installed ? [UIColor labelColor] : [UIColor systemOrangeColor];
    cell.detailTextLabel.text = detail;
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

@end

#pragma mark - S08: Redacted Log Viewer

@interface ZLModLogViewerController : UITableViewController
@property (nonatomic, strong) NSArray<NSString *> *lines;
@end

@implementation ZLModLogViewerController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Runtime Logs (Redacted)";
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 36.0;

    UIBarButtonItem *clipboardBarBtn = [[UIBarButtonItem alloc] initWithTitle:@"Sao chép"
                                                                        style:UIBarButtonItemStylePlain
                                                                       target:self
                                                                       action:@selector(handleCopyLogs:)];
    UIBarButtonItem *clearBtn = [[UIBarButtonItem alloc] initWithTitle:@"Xóa"
                                                                 style:UIBarButtonItemStylePlain
                                                                target:self
                                                                action:@selector(clearLogs:)];
    self.navigationItem.rightBarButtonItems = @[clearBtn, clipboardBarBtn];

    UIRefreshControl *rc = [[UIRefreshControl alloc] init];
    [rc addTarget:self action:@selector(refreshLogs:) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = rc;

    [self reloadLogs];
}

- (void)refreshLogs:(UIRefreshControl *)rc {
    [self reloadLogs];
    [rc endRefreshing];
}

- (void)reloadLogs {
    self.lines = ZLModReadRecentLogs(kZLModLogRingCapacity);
    [self.tableView reloadData];
}

- (void)handleCopyLogs:(__unused id)sender {
    NSString *joined = [self.lines componentsJoinedByString:@"\n"];
    [UIPasteboard generalPasteboard].string = joined ?: @"";
    ZLModShowToast(@"Đã sao chép log vào bộ nhớ tạm");
}

- (void)clearLogs:(__unused id)sender {
    ZLModClearLogs();
    [self reloadLogs];
    ZLModShowToast(@"Đã xóa bộ đệm log");
}

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(__unused NSInteger)section {
    return (NSInteger)MAX(self.lines.count, (NSUInteger)1);
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(__unused NSInteger)section {
    return ZLModPrimaryLogPath();
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellId = @"ZLModLogLineCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cellId];
        cell.textLabel.font = [UIFont monospacedSystemFontOfSize:11.5 weight:UIFontWeightRegular];
        cell.textLabel.numberOfLines = 0;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    if (self.lines.count == 0) {
        cell.textLabel.text = @"Log trống";
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
    } else {
        cell.textLabel.text = self.lines[(NSUInteger)indexPath.row];
        cell.textLabel.textColor = [UIColor labelColor];
    }
    return cell;
}

@end

#pragma mark - S01: Main ZLModSettingsViewController

@interface ZLModSettingsViewController ()
@property (nonatomic, strong) NSArray<NSDictionary *> *model;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UISwitch *> *switches;
@end

@implementation ZLModSettingsViewController

+ (instancetype)make {
    ZLModSettingsViewController *vc = [[ZLModSettingsViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    vc.title = @"ZLMod Customize";
    return vc;
}

+ (void)pushFrom:(UIViewController *)host {
    ZLModSettingsViewController *dash = [ZLModSettingsViewController make];
    UINavigationController *nav = host.navigationController;
    if (nav) {
        [nav pushViewController:dash animated:YES];
        return;
    }
    UINavigationController *wrapper = [[UINavigationController alloc] initWithRootViewController:dash];
    dash.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:dash
                                                      action:@selector(dismissSelf:)];
    wrapper.modalPresentationStyle = UIModalPresentationFormSheet;
    [host presentViewController:wrapper animated:YES completion:nil];
}

- (void)dismissSelf:(__unused id)sender {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.switches = [NSMutableDictionary dictionary];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 52.0;
    [self buildModel];

    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self selector:@selector(externalStateDidChange:) name:ZLModConversationPolicyDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(externalStateDidChange:) name:ZLModAccountDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(externalStateDidChange:) name:ZLModThemeDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(externalStateDidChange:) name:ZLModBridgeStatusDidChangeNotification object:nil];
    [nc addObserver:self selector:@selector(externalStateDidChange:) name:ZLModPrefsDidChangeNotification object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)externalStateDidChange:(__unused NSNotification *)note {
    ZLModRunOnMainThread(^{
        if (!self.isViewLoaded || !self.view.window) return;
        [self buildModel];
        [self.tableView reloadData];
    });
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self buildModel];
    [self.tableView reloadData];
}

- (void)buildModel {
    self.tableView.tableHeaderView = ZLModStorageHealthHeaderViewForWidth(self.view.bounds.size.width);

    ZLModThemeManager *themeMgr = [ZLModThemeManager shared];
    NSString *presetLabel = [themeMgr displayNameForPreset:[themeMgr activePresetId]];
    NSString *tintLabel = ([themeMgr customTintHex].length > 0) ? [themeMgr customTintHex] : @"Mặc định";

    NSArray *appearance = @[
        @{ @"title": @"Blur Tab Bar", @"subtitle": ZLModGlassMaterialDescription(),
           @"key": kZLModGlassTabBar, @"switch": @YES },
        @{ @"title": @"Theme Preset", @"value": presetLabel, @"action": @"theme_preset" },
        @{ @"title": @"Custom Accent Tint (#HEX)", @"value": tintLabel, @"action": @"theme_tint" },
    ];

    NSArray *privacy = @[
        @{ @"title": @"Hide Typing Indicator", @"subtitle": @"Không gửi trạng thái đang nhập (Toàn cục)", @"key": kZLModHideTyping, @"switch": @YES },
        @{ @"title": @"Control Seen Status", @"subtitle": @"Không gửi thông báo đã xem tin nhắn (Toàn cục)", @"key": kZLModHideSeen, @"switch": @YES },
        @{ @"title": @"Control Read Receipts", @"subtitle": @"Không gửi biên nhận đã đọc lên máy chủ", @"key": kZLModHideReadReceipts, @"switch": @YES },
        @{ @"title": @"Disable Tracking & Analytics", @"subtitle": @"Chặn endpoint tracking của Zalo (cả NSURLSession)", @"key": kZLModBlockTracking, @"switch": @YES },
        @{ @"title": @"Disable Firebase Collection", @"subtitle": @"Tắt thu thập Firebase Analytics/Performance (khôi phục ngay khi tắt)", @"key": kZLModBlockFirebase, @"switch": @YES },
    ];

    NSUInteger policyCount = [[ZLModConversationPolicyStore shared] customizedCountForCurrentAccount];
    NSArray *perConversation = @[
        @{ @"title": @"Per-Conversation Policies",
           @"value": [NSString stringWithFormat:@"%lu hội thoại", (unsigned long)policyCount],
           @"action": @"conv_policies" },
    ];

    NSUInteger recallCount = [[ZLModAntiRecallStore shared] preservedCountForCurrentAccount];
    NSArray *messaging = @[
        @{ @"title": @"Anti-Recall (Ghost Preview)",
           @"subtitle": @"Giữ bản sao chữ & ảnh mã hóa cục bộ khi đối phương thu hồi (TTL 14 ngày)",
           @"key": kZLModAntiRecall, @"switch": @YES },
        @{ @"title": @"Ghost Preview History",
           @"value": [NSString stringWithFormat:@"%lu bản ghi", (unsigned long)recallCount],
           @"action": @"antirecall_history" },
    ];

    NSTimeInterval delaySec = [[ZLModDelaySendManager shared] delayDuration];
    NSUInteger quickCount = [[ZLModQuickReplyStore shared] quickReplies].count;
    NSUInteger notesCount = [[ZLModPrivateNotesStore shared] countForCurrentAccount];
    NSArray *utilities = @[
        @{ @"title": @"Delay Send Undo",
           @"subtitle": @"Hoãn gửi tin nhắn kèm thanh Hủy gửi đếm ngược trực tiếp",
           @"key": kZLModDelaySend, @"switch": @YES },
        @{ @"title": @"Delay Duration",
           @"value": [NSString stringWithFormat:@"%.0f giây", delaySec],
           @"action": @"delay_duration" },
        @{ @"title": @"Quick Reply Templates",
           @"value": [NSString stringWithFormat:@"%lu mẫu", (unsigned long)quickCount],
           @"action": @"quick_replies" },
        @{ @"title": @"Encrypted Private Notes",
           @"value": [NSString stringWithFormat:@"%lu ghi chú", (unsigned long)notesCount],
           @"action": @"private_notes" },
    ];

    NSArray *ads = @[
        @{ @"title": @"Hide Ads", @"subtitle": @"Ẩn thành phần quảng cáo (khôi phục ngay khi tắt)", @"key": kZLModHideAds, @"switch": @YES },
        @{ @"title": @"Block Ad Requests", @"subtitle": @"Chặn endpoint quảng cáo (zpads, ads api)", @"key": kZLModBlockAdRequests, @"switch": @YES },
    ];

    NSArray *features = @[
        @{ @"title": @"Profile Music", @"subtitle": @"Khôi phục nhạc trang cá nhân", @"key": kZLModRestoreProfileMusic, @"switch": @YES },
        @{ @"title": @"Google Drive Backup", @"subtitle": @"Khôi phục mục sao lưu Google Drive", @"key": kZLModRestoreGDrive, @"switch": @YES },
        @{ @"title": @"More Tab", @"subtitle": @"Khôi phục tab More (enable_tabmore)", @"key": kZLModRestoreMoreTab, @"switch": @YES },
    ];

    ZLModBridgeManager *bridgeMgr = [ZLModBridgeManager shared];
    NSString *bridgeStatusVal = ZLModBridgeStatusText(bridgeMgr, NULL);
    NSArray *bridgeRows = @[
        @{ @"title": @"C-Bridge & Local Server",
           @"value": bridgeStatusVal,
           @"action": @"bridge_settings" },
        @{ @"title": @"CSaving (Lưu tin nhắn)",
           @"subtitle": @"Chuyển tiếp tin nhắn tới SQLite Local Server (độc lập với Anti-Recall)",
           @"key": kZLModBridgeSaving, @"switch": @YES },
        @{ @"title": @"Discord Webhook Relay",
           @"subtitle": @"Tự động gửi tin nhắn đến & tin bị thu hồi sang Discord",
           @"key": kZLModBridgeDiscordRelay, @"switch": @YES },
    ];

    NSDictionary *statuses = ZLModAllModuleStatuses();
    NSUInteger installedModules = 0;
    for (NSString *m in statuses) {
        if ([statuses[m][@"status"] isEqualToString:ZLModModuleStatusHookInstalled]) {
            installedModules++;
        }
    }
    NSString *scope = ZLModCurrentAccountScope() ?: @"unidentified (fail-closed)";
    NSArray *diagnostics = @[
        @{ @"title": @"Tắt lắc máy để mở ZLMod",
           @"subtitle": @"Ngăn xung đột với tính năng Lắc để hoàn tác nhập liệu của iOS",
           @"key": kZLModDisableShakeToOpen, @"switch": @YES },
        @{ @"title": @"Storage & Keychain Health", @"value": ZLModStorageHealthDescription() },
        @{ @"title": @"Module Hook Status",
           @"value": [NSString stringWithFormat:@"%lu/%lu active", (unsigned long)installedModules, (unsigned long)statuses.count],
           @"action": @"module_status" },
        @{ @"title": @"Runtime Log Viewer",
           @"value": [NSString stringWithFormat:@"%lu dòng", (unsigned long)ZLModReadRecentLogs(kZLModLogRingCapacity).count],
           @"action": @"log_viewer" },
        @{ @"title": @"Active Account Scope", @"value": scope },
        @{ @"title": @"Reset All ZLMod Settings", @"value": @"Đặt lại", @"action": @"reset_all" },
    ];

    NSArray *about = @[
        @{ @"title": @"Version", @"value": [NSString stringWithFormat:@"%@ (%@)", ZLMOD_VERSION, ZLMOD_BUILD] },
        @{ @"title": @"Zalo", @"value": [ZLModCompatibility hostVersion] },
        @{ @"title": @"Compatibility", @"value": [ZLModCompatibility supportReason] },
        @{ @"title": @"Settings anchor", @"value": [ZLModCompatibility anchorExists:@"SettingUI40TableViewController"] ? @"✔︎ SettingUI40TableViewController" : @"—" },
        @{ @"title": @"Tab bar anchor", @"value": [ZLModCompatibility anchorExists:@"ZaloTabBarViewController"] ? @"✔︎ ZaloTabBarViewController" : @"—" },
        @{ @"title": @"Inbox menu anchor", @"value": [ZLModCompatibility anchorExists:@"InboxContextMenuManager"] ? @"✔︎ InboxContextMenuManager" : @"—" },
        @{ @"title": @"Chat VC anchor", @"value": [ZLModCompatibility anchorExists:@"BaseChatTVC"] ? @"✔︎ BaseChatTVC" : @"—" },
        @{ @"title": @"Anti-Recall anchor", @"value": [ZLModCompatibility anchorExists:@"ConversationModel"] ? @"✔︎ ConversationModel" : @"—" },
    ];

    self.model = @[
        @{ @"header": @"Appearance & Theme", @"rows": appearance },
        @{ @"header": @"Privacy (Global)", @"rows": privacy },
        @{ @"header": @"Per-Conversation Privacy & Unread", @"rows": perConversation },
        @{ @"header": @"Messaging & Anti-Recall", @"rows": messaging },
        @{ @"header": @"Utilities", @"rows": utilities },
        @{ @"header": @"C-Bridge & Local Server", @"rows": bridgeRows },
        @{ @"header": @"Ad Blocking", @"rows": ads },
        @{ @"header": @"Feature Restoration", @"rows": features },
        @{ @"header": @"Diagnostics & Maintenance", @"rows": diagnostics },
        @{ @"header": @"About ZLMod", @"rows": about },
    ];
}

#pragma mark - Table Data Source & Delegate

- (NSInteger)numberOfSectionsInTableView:(__unused UITableView *)tableView {
    return (NSInteger)self.model.count;
}

- (NSInteger)tableView:(__unused UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)[self.model[(NSUInteger)section][@"rows"] count];
}

- (NSString *)tableView:(__unused UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.model[(NSUInteger)section][@"header"];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *row = self.model[(NSUInteger)indexPath.section][@"rows"][(NSUInteger)indexPath.row];
    NSString *key = row[@"key"];
    NSString *action = row[@"action"];

    if (key) {
        static NSString *cellId = @"ZLModSwitchCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellId];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cellId];
            cell.textLabel.adjustsFontForContentSizeCategory = YES;
            cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
        }
        cell.textLabel.text = row[@"title"];
        cell.detailTextLabel.text = row[@"subtitle"];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        cell.detailTextLabel.numberOfLines = 2;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;

        UISwitch *sw = self.switches[key];
        if (!sw) {
            sw = [[UISwitch alloc] init];
            objc_setAssociatedObject(sw, "zlmod.pref.key", key, OBJC_ASSOCIATION_COPY_NONATOMIC);
            [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
            self.switches[key] = sw;
        }
        sw.on = [[ZLModPreferences shared] boolForKey:key];
        sw.accessibilityLabel = row[@"title"];
        cell.accessoryView = sw;
        return cell;
    }

    if (action) {
        static NSString *actionId = @"ZLModActionCell";
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:actionId];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:actionId];
            cell.textLabel.adjustsFontForContentSizeCategory = YES;
            cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
        }
        cell.textLabel.text = row[@"title"];
        cell.detailTextLabel.text = row[@"value"];
        if ([action isEqualToString:@"reset_all"]) {
            cell.textLabel.textColor = [UIColor systemRedColor];
            cell.accessoryType = UITableViewCellAccessoryNone;
        } else {
            cell.textLabel.textColor = [UIColor labelColor];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        }
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        return cell;
    }

    static NSString *infoId = @"ZLModInfoCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:infoId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:infoId];
        cell.textLabel.adjustsFontForContentSizeCategory = YES;
        cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    }
    cell.textLabel.text = row[@"title"];
    cell.textLabel.textColor = [UIColor labelColor];
    cell.detailTextLabel.text = row[@"value"];
    cell.detailTextLabel.numberOfLines = 2;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *row = self.model[(NSUInteger)indexPath.section][@"rows"][(NSUInteger)indexPath.row];
    NSString *action = row[@"action"];
    if (!action) return;

    if ([action isEqualToString:@"theme_preset"]) {
        [self presentThemePresetPickerFromIndexPath:indexPath];
    } else if ([action isEqualToString:@"theme_tint"]) {
        [self presentThemeTintEditor];
    } else if ([action isEqualToString:@"conv_policies"]) {
        ZLModConversationPoliciesViewController *vc = [[ZLModConversationPoliciesViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
        [self.navigationController pushViewController:vc animated:YES];
    } else if ([action isEqualToString:@"antirecall_history"]) {
        ZLModAntiRecallHistoryViewController *vc = [[ZLModAntiRecallHistoryViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
        [self.navigationController pushViewController:vc animated:YES];
    } else if ([action isEqualToString:@"delay_duration"]) {
        [self presentDelayDurationPickerFromIndexPath:indexPath];
    } else if ([action isEqualToString:@"quick_replies"]) {
        ZLModQuickRepliesViewController *vc = [[ZLModQuickRepliesViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
        [self.navigationController pushViewController:vc animated:YES];
    } else if ([action isEqualToString:@"private_notes"]) {
        ZLModPrivateNotesViewController *vc = [[ZLModPrivateNotesViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
        [self.navigationController pushViewController:vc animated:YES];
    } else if ([action isEqualToString:@"bridge_settings"]) {
        ZLModBridgeViewController *vc = [[ZLModBridgeViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
        [self.navigationController pushViewController:vc animated:YES];
    } else if ([action isEqualToString:@"module_status"]) {
        ZLModModuleStatusViewController *vc = [[ZLModModuleStatusViewController alloc] initWithStyle:UITableViewStyleInsetGrouped];
        [self.navigationController pushViewController:vc animated:YES];
    } else if ([action isEqualToString:@"log_viewer"]) {
        ZLModLogViewerController *vc = [[ZLModLogViewerController alloc] initWithStyle:UITableViewStylePlain];
        [self.navigationController pushViewController:vc animated:YES];
    } else if ([action isEqualToString:@"reset_all"]) {
        [self presentResetAllConfirmation];
    }
}

#pragma mark - Action sheets & dialogs

- (void)presentThemePresetPickerFromIndexPath:(NSIndexPath *)indexPath {
    ZLModThemeManager *mgr = [ZLModThemeManager shared];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Chọn Theme Preset"
                                                                   message:@"Mặc định hệ thống sẽ giữ nguyên hoàn toàn giao diện gốc của Zalo."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *presetId in [mgr availablePresetIds]) {
        NSString *title = [mgr displayNameForPreset:presetId];
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *action) {
            [mgr applyPresetNamed:presetId];
            [self buildModel];
            [self.tableView reloadData];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) {
        UITableViewCell *c = [self.tableView cellForRowAtIndexPath:indexPath];
        sheet.popoverPresentationController.sourceView = c ?: self.view;
        sheet.popoverPresentationController.sourceRect = c ? c.bounds : self.view.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)presentThemeTintEditor {
    ZLModThemeManager *mgr = [ZLModThemeManager shared];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Màu nhấn tùy chỉnh (#RRGGBB)"
                                                                   message:@"Nhập đúng 6 ký tự HEX (VD: #0068FF). Để trống để dùng màu mặc định của Preset hoặc Zalo."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Ví dụ: #0068FF";
        tf.text = [mgr customTintHex];
        tf.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
        tf.autocorrectionType = UITextAutocorrectionTypeNo;
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Áp dụng"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        NSString *hex = alert.textFields.firstObject.text ?: @"";
        if (![mgr applyCustomTintHex:hex]) {
            ZLModShowToast(@"Mã màu HEX không hợp lệ — cần dạng #RRGGBB (VD: #0068FF)");
            return;
        }
        [self buildModel];
        [self.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)presentDelayDurationPickerFromIndexPath:(NSIndexPath *)indexPath {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Thời gian hoãn gửi"
                                                                   message:@"Chọn khoảng thời gian hiển thị nút Hủy gửi trước khi tin nhắn được gửi đi."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSNumber *sec in @[@1, @3, @5, @8, @10]) {
        NSString *label = [NSString stringWithFormat:@"%ld giây", (long)sec.integerValue];
        [sheet addAction:[UIAlertAction actionWithTitle:label
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *action) {
            [[ZLModDelaySendManager shared] setDelayDuration:sec.doubleValue];
            [self buildModel];
            [self.tableView reloadData];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) {
        UITableViewCell *c = [self.tableView cellForRowAtIndexPath:indexPath];
        sheet.popoverPresentationController.sourceView = c ?: self.view;
        sheet.popoverPresentationController.sourceRect = c ? c.bounds : self.view.bounds;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)presentResetAllConfirmation {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Đặt lại toàn bộ ZLMod?"
                                                                   message:@"Tắt mọi công tắc tính năng, xóa Token/Webhook trong Keychain, khôi phục giao diện gốc của Zalo và xóa chính sách hội thoại tùy chỉnh."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Đặt lại tất cả"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        [[ZLModDelaySendManager shared] cancelAllPendingSends];
        [[ZLModPreferences shared] resetAllPreferences];
        [[ZLModThemeManager shared] resetTheme];
        [[ZLModConversationPolicyStore shared] resetAllPolicies];
        [self buildModel];
        [self.tableView reloadData];
        ZLModShowToast(@"Đã đặt lại toàn bộ cài đặt ZLMod");
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)switchChanged:(UISwitch *)sw {
    NSString *key = objc_getAssociatedObject(sw, "zlmod.pref.key");
    if (!key) return;
    if ([key isEqualToString:kZLModBridgeDiscordRelay] && sw.on) {
        NSString *hook = [[ZLModPreferences shared] stringForKey:kZLModBridgeWebhook defaultValue:@""];
        if (![ZLModBridgeManager isValidDiscordWebhookURLString:hook]) {
            sw.on = NO;
            ZLModShowToast(@"Hãy cấu hình Discord Webhook URL trong C-Bridge trước khi bật.");
            return;
        }
    }
    [[ZLModPreferences shared] setBool:sw.on forKey:key];
}

@end
