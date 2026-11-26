# FEATURE_SPEC.md — Danh mục Chức năng & Xác thực Thực tế

> **Nguyên tắc kiểm định:** Mọi chức năng dưới đây được truy vết trực tiếp trong mã nguồn (`Sources/`, `Packaging/`, `Scripts/`, `Resources/`, `.github/workflows/`). Không gắn `IMPLEMENTED` chỉ vì có nút bấm hoặc dòng chữ trong README. Các chức năng chưa thể xác minh hành vi runtime trên thiết bị iOS thật (do thiếu macOS build / iPhone vật lý) được ghi rõ phạm vi xác minh tĩnh vs **`UNKNOWN — NEEDS VERIFICATION`** ở tầng thiết bị thật.

---

## Bảng tổng hợp trạng thái toàn bộ tính năng

| # | Feature | Module | Status | Tóm tắt nguyên nhân |
|---|---|---|---|---|
| F01 | Bootstrap & Module Isolation | `ZLModCore.m` | `IMPLEMENTED` | Chạy constructor + 3 trigger + `@try/@catch` 11 module; có rủi ro thread-safety (boot trên background queue) |
| F02 | Host Compatibility Gate | `ZLModCompatibility.m` | `PARTIAL` | Có allowlist `compatibility.json`, nhưng fallback động dòng 22-30 vô hiệu hóa cơ chế fail-closed strict như README/docs mô tả |
| F03 | Runtime Hook Engine & Safe Property Readers | `ZLModHookEngine.m` | `IMPLEMENTED` | Có kiểm tra arity/return-encoding/dedup; cache class vĩnh viễn không cập nhật ảnh load muộn |
| F04 | Preferences & App Group Mirror | `ZLModPreferences.m` | `IMPLEMENTED` | Hoạt động với 21 keys; gọi deprecated `synchronize`, App Group fail im lặng trên free Apple ID sideload |
| F05 | Keychain AES-256-CBC + HMAC-SHA256 & Account Scope | `ZLModCryptoStore.m` | `IMPLEMENTED` | Fail-closed đúng khi thiếu `userId` hoặc Keychain lỗi; chưa kiểm chứng hành vi khi sideload mất Keychain entitlement |
| F06 | Settings Row Injection & Universal Shake Gesture | `ZLModSettings.m` | `PARTIAL` | Clone native cell bằng `memcpy` + BFS 4.000 node có rủi ro bộ nhớ ARC/weak ivar; fallback row bị lệch index các delegate method khác; Shake không có công tắc tắt và đụng iOS Undo Typing |
| F07 | ZLMod Customize Dashboard & Diagnostics UI | `ZLModUI.m` | `IMPLEMENTED` | 10 sections + 7 child VCs; có bug duplicate notification & 3x reconnect ở màn C-Bridge |
| F08 | Liquid Glass / Blur Tab Bar | `ZLModGlass.m` | `PARTIAL` | Chỉ dùng `UIBlurEffectStyleSystemUltraThinMaterial` (đã bỏ `UIGlassEffect` dù README/docs vẫn ghi iOS 26 `UIGlassEffect`); xung đột baseline với `ZLModTheme` |
| F09 | Theme Presets & Custom Accent Tint | `ZLModTheme.m` | `IMPLEMENTED` | 4 preset + `#RRGGBB`, có lưu/khôi phục baseline; xung đột `UITabBarAppearance` với `ZLModGlass`, không tự đổi lại theme cho các VC tạo sau khi đã apply |
| F10 | Hide Typing Indicator (Global & Per-Chat) | `ZLModPrivacy.m`, `ZLModPolicyStore.m` | `PARTIAL` | Hook `ChatDataManager` & `ChatSocketCmdHelper`; socket hook dùng `activeThreadId` thay vì dest trong packet nên dễ nhầm khi gửi typing không từ active VC |
| F11 | Control Seen Status & Read Receipts (Global & Per-Chat) | `ZLModPrivacy.m`, `ZLModPolicyStore.m` | `IMPLEMENTED` | 11 hooks trên `ChatSendSeenDataManager`, `ChatSocketCmdHelper`, `FriendRequestManager`, và scan class toàn cục; cần verify runtime trên iOS thật |
| F12 | Disable Tracking & Analytics (URL Filter) | `ZLModURIFilter.m` | `PARTIAL` | Đăng ký `[NSURLProtocol registerClass:]` → chỉ chặn `NSURLConnection`/`sharedSession`, **bỏ lọt** custom `NSURLSessionConfiguration` và `WKWebView` |
| F13 | Disable Firebase Collection | `ZLModPrivacy.m` | `PARTIAL` | Chỉ tắt khi bật toggle (`if (!blocked) return;`), **KHÔNG BAO GIỜ bật lại** khi tắt toggle; `FIRAnalytics`/`FIRPerformance`/`FIRCrashlytics` cần verify hiện diện trên từng bản Zalo |
| F14 | Per-Conversation Long-Press Menu | `ZLModConversationMenu.m` | `PARTIAL` | Hỗ trợ mảng lồng section cho 26.10/26.11, nhưng selector `contextMenu:didSelectActionId:forIdentifier:` **KHÔNG TỒN TẠI** trong bản IPA `260401/708` đang commit trong `Decrypted/`! |
| F15 | Local Mark Unread (Blue Dot `#0068FF`) | `ZLModConversationMenu.m`, `ZLModPolicyStore.m` | `IMPLEMENTED` | Hook `UXInboxMessageCell` + `ChatListItemCell` (`ChatListItemCell` không có trong 260401); lưu cục bộ theo `accountScope` |
| F16 | Anti-Recall Ghost Preview & In-Place Unhide/Hide | `ZLModAntiRecall.m` | `PARTIAL` | Hoạt động text snapshot + mã hóa 14 ngày + nút Hiện/Ẩn tại chỗ; nhưng có bug lọc sai tin chứa chữ `"thu hồi"`/`"recalled"`, rò bộ nhớ `liveByKey` alt-key, gọi `set_originTextRecallMsg:` trái claim non-mutating, không lưu ảnh xuống disk (mất ảnh khi Zalo xóa/restart), không dọn associated object ở `prepareForReuse`, có hàm dead code `ZLModPresentRecalledMessageContent` |
| F17 | Delay Send Undo (5-State FSM + Banner) | `ZLModUtilities.m` | `IMPLEMENTED` | Hook `ZAChatSendingManager -sendChat:checkUpload:`, đếm ngược 1–10s, hủy an toàn khi background/terminate/logout/disable; không cập nhật text đếm ngược từng giây (đứng yên `"Đang chờ gửi (3s)..."`) |
| F18 | Quick Reply Templates (Safe Composer Insert) | `ZLModUtilities.m`, `ZLModUI.m` | `IMPLEMENTED` | CRUD, reorder, reset defaults, chèn qua `BaseChatTVC -fillChatBarWithText:` hoặc `firstResponder`, fallback clipboard; không bao giờ tự gửi |
| F19 | Encrypted Private Notes per Conversation | `ZLModUtilities.m`, `ZLModUI.m` | `IMPLEMENTED` | Mã hóa AES-256-CBC + HMAC-SHA256 theo `(accountScope, threadId)` lưu trong `ZLModNotes.plist`; chỉ mở bằng `UIAlertController` 1 dòng `UITextField` (không hỗ trợ multi-line note) |
| F20 | Ad Blocking (UI View Disarming + Ad Request Filter) | `ZLModAds.m`, `ZLModURIFilter.m` | `PARTIAL` | Ẩn `ZInstantFeedAdsView` & `LocationOAAdsCell` + chặn URL ads qua `NSURLProtocol` (cùng hạn chế bypass custom `NSURLSessionConfiguration`; `/ads_out_stream` thiếu trong 260401) |
| F21 | Feature Restoration (Profile Music, GDrive Backup, More Tab) | `ZLModFeatures.m` | `PARTIAL` | Ghi đè getter & mirror external `NSUserDefaults`; GDrive selectors `_basicBackupGDriveSectionZInstantData` & key `features@profile_music` **thiếu trong 260401**; hiệu lực thực phụ thuộc server flags của Zalo (`UNKNOWN — NEEDS VERIFICATION`) |
| F22 | C-Bridge: CPairing (WebSocket + Health Ping + LAN Auto-Discovery) | `ZLModBridge.m`, `ZLModUI.m` | `BROKEN` | (1) `testPairingWithCompletion:` bị **bug phá URL** `http://` → `http:/` ở `ZLModBridge.m:472`; (2) **KHÔNG CÓ** code LAN auto-discovery dù UI/release notes quảng cáo; (3) Stale WebSocket task race condition + 3x reconnect khi lưu URL/Token |
| F23 | C-Bridge: CSaving (Message Streaming to Local SQLite) | `ZLModBridge.m`, `ZLModAntiRecall.m` | `BROKEN` | (1) **Chết hoàn toàn nếu tắt Anti-Recall** do phụ thuộc `ZLModChatEntityArrivedNotification` (`ZLModAntiRecall.m:1068,1136,1151`); (2) Không deduplicate cục bộ; (3) Re-enqueue khi gửi lỗi làm đảo thứ tự & phá trần 50 tin; (4) Thiếu fallback selector (`globalMsgId`/`cliMsgId`/`fuid`/`displayname`) và thiếu loại `Undo` |
| F24 | C-Bridge: CDeploy (Two-Way Settings Sync) | `ZLModBridge.m`, `ZLModUI.m` | `PARTIAL` | Push từ server có hộp thoại xác nhận, nhưng `applyRemoteSettings:` **không có allowlist key** (lỗ hổng ghi đè bất kỳ key nào kể cả serverUrl/token); `uploadCurrentSettings` không cập nhật `kZLModBridgeLastSync` và không chờ server ACK |
| F25 | C-Bridge: Discord Webhook Relay | `ZLModBridge.m`, `ZLModUI.m` | `PARTIAL` | Chỉ có nút **Test Webhook** thủ công (`testWebhookWithCompletion:`); **KHÔNG CÓ** bất kỳ luồng tự động relay cảnh báo/tin thu hồi/tin nhắn nào tới Discord trong toàn bộ codebase |
| F26 | In-App Redacted Runtime Log Viewer | `ZLModCore.m`, `ZLModUI.m` | `IMPLEMENTED` | Ring buffer 200 dòng + file `ZLMod.log` xoay vòng 512 KB + regex redact token/Bearer/số ≥ 10 chữ số |
| F27 | IPA Packaging, Mach-O Injector & Preflight Forensics | `Packaging/*.py` | `PARTIAL` | Đóng gói được IPA full & noappex, nhưng có 2 bug thật: (1) `macho_injector.py:159` tiêm `LC_RPATH` sai căn lề 8-byte (`12 + align8(...)` = `4 mod 8`!); (2) `ipa_preflight.py:281-297` gắn sai trạng thái `PROVISIONED_AND_SIGNED` khi `CodeResources=True` & `MobileProvision=False` |
| F28 | Dead Code: Modal Alert Anti-Recall Viewer | `ZLModAntiRecall.m:980-1056` | `UNUSED` | Hàm `ZLModPresentRecalledMessageContent` gắn `__attribute__((unused))`, không được gọi ở bất kỳ đâu |

---

## Chi tiết từng chức năng (Phase 1 Full Specification)

### F01 — Bootstrap, Module Isolation & Session Lifecycle
- **Feature name:** Dylib Entry, Delayed Boot & Session Observers
- **Purpose:** Khởi tạo an toàn toàn bộ 11 module sau khi Zalo launch, cô lập lỗi theo từng module và phát hiện chuyển đổi tài khoản.
- **User goal:** Zalo khởi động ổn định không crash kể cả khi có module lỗi hoặc inject trễ.
- **Entry point:** `__attribute__((constructor)) ZLModEntry()` (`Sources/ZLModCore.m:407`)
- **UI location:** Toast khởi động `"✨ ZLMod Customize đã kích hoạt! Lắc máy hoặc vào Cài đặt để mở menu."` (`ZLModCore.m:349`).
- **Frontend implementation:** Không có UI riêng (chỉ bắn toast và ghi trạng thái vào `gModuleStatuses` để `ZLModModuleStatusViewController` đọc).
- **Backend implementation:** `ZLModCore.m:262-412` (`ZLModBoot`, `ZLModRunInstaller`, `ZLModInstallSessionLifecycleObservers`).
- **API:** Hook `AppDelegate -didLogout` (`ZLModCore.m:279`), `AppDelegate -didLogin` (`ZLModCore.m:288`), observe `kNotifyDidLogoutAnimation` (`ZLModCore.m:295`).
- **Database:** Ghi log ra `<Documents>/ZLMod.log` (fallback `NSTemporaryDirectory`) và App Group `group.zsettings.vn.com.vng.zingalo/ZLMod.log`.
- **Realtime:** Phát `ZLModAccountDidChangeNotification` trên main queue (`ZLModCore.m:267`).
- **Dependencies:** `ZLModCompatibility`, `ZLModHookEngine`, `ZLModCryptoStore`, `ZLModPolicyStore`, tất cả 11 module installers, `ZLModShowToast` (từ `ZLModConversationMenu.m`).
- **Current behavior:** 3 trigger khởi động (`UIApplicationDidFinishLaunchingNotification`, 5s timer, 1s timer nếu keyWindow tồn tại) gọi `ZLModBootAsync()` → chạy `ZLModBoot()` trên global background queue → kiểm tra `hostSupported` → cài session observers → gọi lần lượt 11 installer trong `@try/@catch` → hiển thị toast.
- **Edge cases:** Nếu `hostSupported` trả về `NO`, toàn bộ 11 module không được cài và toast không hiện.
- **Error handling:** Ngoại lệ ObjC (`@catch`) được ghi log + set trạng thái module là `NOT_INSTALLED`; không bắt được C++ exception hoặc `EXC_BAD_ACCESS`/SIGSEGV.
- **Current limitations:** Chạy 11 installer trên background queue trong khi nhiều module đụng UIKit (`UIWindow`, `UITabBar`, `UINavigationBar`).
- **Current bugs:**
  1. `ZLModCore.m:390` gọi `ZLModActiveKeyWindow()` trong block `dispatch_after` main queue (ổn), nhưng `ZLModBoot()` ở dòng 355 chạy trên background queue và gọi `ZLModSettingsInstall`, `ZLModThemeInstall`, `ZLModGlassInstall`.
  2. Toast startup luôn hiện ngay cả khi tất cả toggle đang OFF và chưa xác minh Settings row đã gắn thành công hay chưa.
- **Status:** `IMPLEMENTED`

---

### F02 — Host Compatibility Gate
- **Feature name:** Compatibility Policy & Runtime Anchor Verification
- **Purpose:** Xác định app host có phải phiên bản Zalo được hỗ trợ trước khi cài đặt hook.
- **User goal:** Ngăn dylib chạy trên app lạ hoặc bản Zalo không tương thích gây crash.
- **Entry point:** `[ZLModCompatibility hostSupported]` (`ZLModCore.m:329`), hiển thị trong `ZLModUI.m:1020-1026`.
- **UI location:** Section **About ZLMod** trong `ZLModSettingsViewController`.
- **Frontend implementation:** `ZLModUI.m:1018-1027` hiển thị `hostVersion`, `supportReason`, và trạng thái 5 anchor classes.
- **Backend implementation:** `ZLModCompatibility.m:9-71`, `Resources/compatibility.json`, `Scripts/generate_compatibility.py` → `Sources/ZLModCompatibilityData.h`.
- **API:** Đọc `[NSBundle mainBundle].infoDictionary` (`CFBundleIdentifier`, `CFBundleShortVersionString`, `CFBundleVersion`) và `NSClassFromString(...)`.
- **Database:** Static manifest `Resources/compatibility.json` (build-time codegen thành `ZLModSupportedHostRecords()`).
- **Realtime:** Không.
- **Dependencies:** `Foundation`, `objc/runtime`.
- **Current behavior:** Kiểm tra khớp chính xác `261002/261002802` hoặc `261101/261101802` với bundle `vn.com.vng.zingalo` / `vn.com.vng.zingalo2`. Nếu không khớp, **rơi vào fallback động** (`ZLModCompatibility.m:22-30`): trả `YES` nếu tồn tại bất kỳ class nào trong 5 class (`ZaloTabBarViewController`, `SettingUI40TableViewController`, `BasicSettingTableViewController`, `ChatDataManager`, `ChatMessage`) HOẶC `bundleId` chứa `"zalo"`/`"zing"`.
- **Edge cases:** Khi sideload bằng Apple ID miễn phí (bundle ID đổi thành `com.user.zalo`), fallback trả `YES`, nhưng `supportReason` (dòng 48-50) lại trả `"unsupported bundle ..."` nếu version/build khớp `261002`/`261101` — gây mâu thuẫn giữa `hostSupported == YES` và `supportReason == "unsupported bundle"`.
- **Error handling:** Fallback trả `NO` nếu không khớp bất kỳ điều kiện nào.
- **Current limitations:** Khác biệt hoàn toàn với tài liệu thiết kế ("fail-closed strict exact allowlist") và khác với `Packaging/ipa_preflight.py:33-48` (không có fallback).
- **Current bugs:**
  1. `hostSupported` (`ZLModCompatibility.m:27-28`) chấp nhận mọi app có chữ `"zalo"` hoặc `"zing"` trong bundleId (kể cả Zing MP3 / ZaloPay!).
  2. Mâu thuẫn logic giữa `hostSupported` (`YES`) và `supportReason` (`"unsupported bundle ..."`) khi bundleId bị đổi trên bản `261002`/`261101`.
  3. Bundled IPA `Decrypted/vn.com.vng.zingalo_260401_decrypted_by_TTJB.ipa` (`260401/708`) không có trong `Resources/compatibility.json`, chạy nhờ fallback động và mất 6/86 anchor.
- **Status:** `PARTIAL`

---

### F03 — Runtime Hook Engine & Safe Property Readers
- **Feature name:** Objective-C Method Replacement & ABI-Safe Introspection
- **Purpose:** Thay thế an toàn các phương thức instance (`-`) và class (`+`) của Zalo không cần Substrate/Theos, và đọc property an toàn ABI.
- **User goal:** Tránh crash do sai chữ ký hàm (arity / return type) khi Zalo cập nhật.
- **Entry point:** `ZLModReplaceMethod`, `ZLModReplaceClassMethod`, `ZLModEnumerateAppClasses`, `ZLModSafe*Property` (`Sources/ZLModHookEngine.m`).
- **UI location:** Không có UI trực tiếp.
- **Frontend implementation:** Không.
- **Backend implementation:** `ZLModHookEngine.m:1-243`.
- **API:** `objc_getClassList`, `class_getImageName`, `class_getInstanceMethod`, `class_getClassMethod`, `method_getNumberOfArguments`, `method_getTypeEncoding`, `imp_implementationWithBlock`, `class_replaceMethod`, `objc_msgSend`.
- **Database:** Cache in-memory `gAppClasses` (`dispatch_once`) và `gHookedMethods` (`NSMutableSet` khóa `@synchronized`).
- **Realtime:** Không.
- **Dependencies:** `objc/runtime`, `UIKit`.
- **Current behavior:** Lọc danh sách class toàn ứng dụng 1 lần duy nhất (`class_getImageName` chứa `.app/` hoặc `/Zalo` và không chứa `/libZLMod.dylib`). Trước khi hook: xác thực `numberOfArguments == declaredArgs + 2`, return type nằm trong `allowedReturns`, và chưa bị hook trước đó.
- **Edge cases:** Class nằm trong dynamic framework chưa được `dlopen` tại thời điểm `ZLModBoot()` sẽ không nằm trong `gAppClasses`.
- **Error handling:** Sai arity / return type → log và bỏ qua (`return NO`), không crash.
- **Current limitations:** Không kiểm tra type encoding của từng tham số (chỉ kiểm tra số lượng tham số và ký tự đầu của return type). Không có cơ chế unhook/restore original IMP.
- **Current bugs:**
  1. `ZLModSafeObjectProperty` (`ZLModHookEngine.m:140-150`) chỉ nhận return type `'@'` hoặc `'#'` và có thể nhận `nil`/NSException (bọc `@try/@catch`); nhưng `ZLModSafeStringProperty` không chuyển `NSNumber` (có chuyển ở dòng 160 `stringValue` — tốt).
  2. `ZLModActiveKeyWindow()` (`ZLModHookEngine.m:208-221`) duyệt `UIApplication.sharedApplication.connectedScenes` — gọi từ background thread là vi phạm UIKit main-thread assertion.
- **Status:** `IMPLEMENTED`

---

### F04 — Preferences & App Group Mirror
- **Feature name:** Persistent Settings Store & Host External Flag Mirror
- **Purpose:** Lưu cấu hình 21 key của ZLMod và phản chiếu/khôi phục các external flag vào `NSUserDefaults` của Zalo (`standardUserDefaults` + App Group).
- **User goal:** Mọi toggle mặc định OFF, lưu bền vững giữa các lần mở app, và khôi phục nguyên trạng khi Reset All.
- **Entry point:** `[ZLModPreferences shared]` (`Sources/ZLModPreferences.m`).
- **UI location:** Toàn bộ switch & giá trị trong `ZLModSettingsViewController` và `ZLModBridgeViewController`.
- **Frontend implementation:** `ZLModUI.m` đọc/ghi qua `[ZLModPreferences shared]`.
- **Backend implementation:** `ZLModPreferences.m:1-254`.
- **API:** `NSUserDefaults` (`initWithSuiteName:@"vn.com.vng.zingalo.zlmod"`, `initWithSuiteName:@"group.zsettings.vn.com.vng.zingalo"`, `standardUserDefaults`).
- **Database:** 3 domain `NSUserDefaults` (file plist trong `Library/Preferences/` và App Group container).
- **Realtime:** Post `ZLModPrefsDidChangeNotification` với `object = key` (hoặc `@"*"` khi `resetAllPreferences`).
- **Dependencies:** `Foundation`.
- **Current behavior:** Đọc ưu tiên `self.own`, fallback `self.group`; mặc định trả `NO` cho mọi BOOL chưa set. Khi ghi: ghi cả `own` và `group`, gọi `synchronize`, post notification. `writeExternalValue:forKey:` lưu giá trị cũ vào `zlmod.internal.prev.<key>` trước khi ghi đè Zalo defaults; `restoreExternalValueForKey:` hoàn nguyên.
- **Edge cases:** Sideload bằng free Apple ID không có entitlement `group.zsettings.vn.com.vng.zingalo` → `self.group` trở thành `nil` (hoạt động tiếp chỉ trên `self.own`).
- **Error handling:** Fallback sang `standardUserDefaults` nếu `initWithSuiteName:kZLModSuite` trả về `nil`.
- **Current limitations:** Secrets (`kZLModBridgeToken`, `kZLModBridgeWebhook`) lưu plaintext trong `NSUserDefaults` (và mirror sang App Group!).
- **Current bugs:**
  1. `README.md:14` ghi sai suite name là `com.zlmod.preferences`, thực tế code dùng `vn.com.vng.zingalo.zlmod`.
  2. `resetAllPreferences` (`ZLModPreferences.m:170-185`) bắn 21 notification riêng lẻ (dòng 181) RỒI bắn thêm 1 notification `@"*"` (dòng 183) → kích hoạt hàng loạt cascade observer.
  3. Gọi deprecated `[NSUserDefaults synchronize]` trên mọi thao tác ghi.
- **Status:** `IMPLEMENTED`

---

### F05 — Keychain Encryption & Multi-Account Scope Isolation
- **Feature name:** `ZLModCryptoBox` & `ZLModCurrentAccountScope`
- **Purpose:** Bảo vệ dữ liệu nhạy cảm cục bộ (Anti-Recall, Private Notes) bằng mã hóa AES-256-CBC + HMAC-SHA256 dùng khóa Keychain, và cách ly dữ liệu theo tài khoản Zalo đang đăng nhập.
- **User goal:** Chuyển tài khoản Zalo không bị rò rỉ ghi chú/tin thu hồi giữa các tài khoản; người khác đọc file `.plist` trong container không thấy plaintext.
- **Entry point:** `[ZLModCryptoBox shared]`, `ZLModCurrentAccountScope()` (`Sources/ZLModCryptoStore.m`).
- **UI location:** Hiển thị `Active Account Scope` trong section Diagnostics của `ZLModSettingsViewController` (`ZLModUI.m:1014`).
- **Frontend implementation:** Không có UI riêng (chỉ hiện chuỗi `acc_<16hex>` hoặc `"unidentified (fail-closed)"`).
- **Backend implementation:** `ZLModCryptoStore.m:1-414`.
- **API:** `Security.framework` (`SecItemCopyMatching`, `SecItemAdd`, `SecItemDelete`), `CommonCrypto` (`CCCrypt`, `CCHmac`, `CC_SHA256`, `CCRandomGenerateBytes`). Đọc `userId` từ 4 singleton Zalo (`ZAApplicationContext +sharedContext`, `ChatDataManager +sharedChatDataManager`, `ChatSendSeenDataManager +shared`, `FTSDatabaseManager +sharedInstance`).
- **Database:** Keychain item `kSecClassGenericPassword`, service `vn.com.vng.zingalo.zlmod.keystore`, account `master_key_v2`, accessibility `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
- **Realtime:** Cache `gCachedAccountScope` bị xóa khi `ZLModAccountDidChangeNotification` (`ZLModCore.m:264`).
- **Dependencies:** `Security.framework`, `CommonCrypto`, `ZLModHookEngine`.
- **Current behavior:** Sinh 32-byte master key, dẫn xuất `encKey = SHA256("ZLMod.v2.ENC|" + masterKey)` và `macKey = SHA256("ZLMod.v2.MAC|" + masterKey)`. Package format v2: `[0x02 (1B)][IV (16B)][Ciphertext (N*16B)][HMAC-SHA256 (32B)]` với MAC tính trên `version || iv || ciphertext || metaLen(uint32 BE) || metadata`. Kiểm tra MAC hằng thời gian trước khi giải mã.
- **Edge cases:** Nếu device bị khóa trước first unlock, hoặc Keychain trả lỗi OSStatus, hoặc không tìm thấy `userId` hợp lệ (khác `"0"`, `"null"`, `"(null)"`) → **fail-closed** (`nil`), từ chối đọc/ghi.
- **Error handling:** Log `OSStatus` khi Keychain lỗi; giải mã sai MAC/padding trả `nil`.
- **Current limitations:** Không dùng key rotation; không bảo vệ `kZLModBridgeToken` hay `kZLModBridgeWebhook`.
- **Current bugs:**
  1. `ZLModCryptoStore.m:119` khai báo `ZLModCandidateAccountScopesForMigration()` nhưng chỉ trả về `@[current]` (migration đa scope chưa thực sự triển khai).
  2. Khi sideload bằng một số công cụ thiếu Keychain access entitlement, `SecItemAdd` có thể trả `-34018` (`errSecMissingEntitlement`), khiến toàn bộ Anti-Recall và Private Notes bị fail-closed im lặng mà không có cảnh báo rõ ràng trên UI (`UNKNOWN — NEEDS VERIFICATION` trên thiết bị thật).
- **Status:** `IMPLEMENTED`

---

### F06 — Settings Row Injection & Universal Shake Gesture
- **Feature name:** Native Settings Entry (`ZLMod Customize`) & Shake-to-Open
- **Purpose:** Cung cấp 2 lối vào bảng điều khiển `ZLModSettingsViewController`: hàng cài đặt native trong Cài đặt Zalo và cử chỉ lắc máy mọi nơi.
- **User goal:** Mở nhanh menu ZLMod dù Zalo thay đổi cấu trúc màn Cài đặt.
- **Entry point:** Vào tab Cá nhân → Cài đặt của Zalo, HOẶC lắc iPhone.
- **UI location:** Hàng `"ZLMod Customize"` cạnh `"Tài khoản và bảo mật"` trong `SettingUI40TableViewController`; hoặc modal sheet ở bất kỳ màn hình nào khi lắc máy.
- **Frontend implementation:** `Sources/ZLModSettings.m:1-789`.
- **Backend implementation:** Không.
- **API:** Hook `UIWindow -motionEnded:withEvent:` (`ZLModSettings.m:647`) và 7 phương thức của `SettingUI40TableViewController` (hoặc 4 fallback class).
- **Database:** Không.
- **Realtime:** Không.
- **Dependencies:** `ZLModHookEngine`, `ZLModUI` (`ZLModSettingsViewController`).
- **Current behavior:**
  - Khi mở Settings của Zalo: chạy BFS (tối đa độ sâu 7, 4.000 node) duyệt ivar để tìm `NSMutableArray` chứa `_accountAndSecurityObject` / text `"Tài khoản và bảo mật"` / `"Account and security"`, nhân bản cell object qua `class_createInstance` + `memcpy` từng ivar + `CFRetain` object ivar, gán title `"ZLMod Customize"`, chèn vào section. Nếu không tìm được → bật `gFallbackActive` chèn cell `UITableViewCellStyleDefault` ở `(section 0, row 0)`.
  - Khi lắc máy: gọi `ZLModPresentSettingsUniversal()` push/present `ZLModSettingsViewController`.
- **Edge cases:** Late-injection quét cây VC hiện tại 1 lần trên main queue (`ZLModSettings.m:762-782`) nếu user đã ở sẵn trong Settings.
- **Error handling:** Bọc `@try/@catch` quanh `ZLModEnsureRow`; nếu không thấy Settings class nào trong 5 ứng viên thì chỉ dựa vào Shake gesture và ghi `Settings = NOT_INSTALLED`.
- **Current limitations:** Không có setting tắt cử chỉ lắc máy.
- **Current bugs:**
  1. **Nguy cơ crash bộ nhớ cao (ARC/Weak Ivar):** `ZLModCloneObject` (`ZLModSettings.m:56-105`) dùng `memcpy` và `CFRetain` trên ivar object nhưng KHÔNG phân biệt `__weak`, `__unsafe_unretained`, C++ struct, hay block ivar — có thể làm hỏng ARC reference count hoặc crash khi dealloc.
  2. **Off-by-one trong Fallback Mode:** `ZLModSettings.m:734-753` chỉ dịch `indexPath.row - 1` ở 3 delegate (`numberOfRows`, `cellForRow`, `didSelectRow`), bỏ sót `heightForRowAtIndexPath:`, `willDisplayCell:`, v.v.
  3. **Xung đột Shake Gesture:** Lắc máy khi đang nhập liệu vừa kích hoạt hộp thoại "Hoàn tác nhập" (Undo Typing) của iOS vừa gọi `ZLModPresentSettingsUniversal()`.
  4. **Static global `gOurRow` / `gFallbackActive`:** Không được reset khi Zalo hủy và tạo instance `SettingUI40TableViewController` mới.
- **Status:** `PARTIAL`

---

### F07 — ZLMod Customize Dashboard & Diagnostic Viewers
- **Feature name:** `ZLModSettingsViewController` + 7 Child Controllers
- **Purpose:** Trung tâm điều khiển toàn bộ tính năng, xem lịch sử, quản lý mẫu câu/ghi chú, cấu hình C-Bridge và chẩn đoán runtime.
- **User goal:** Bật/tắt và quản lý mọi tính năng ZLMod ngay trong app Zalo.
- **Entry point:** `ZLModSettingsViewController +pushFrom:` (`Sources/ZLModUI.m:871`).
- **UI location:** 10 sections trong `ZLModSettingsViewController` + 7 màn hình push qua `UINavigationController`.
- **Frontend implementation:** `Sources/ZLModUI.m:15-1247`.
- **Backend implementation:** Gọi trực tiếp các singleton (`ZLModPreferences`, `ZLModThemeManager`, `ZLModConversationPolicyStore`, `ZLModAntiRecallStore`, `ZLModDelaySendManager`, `ZLModQuickReplyStore`, `ZLModPrivateNotesStore`, `ZLModBridgeManager`, `ZLModCompatibility`, `ZLModCore`).
- **API:** Nội bộ Objective-C + C-Bridge actions (`testPairing`, `testWebhook`, `uploadCurrentSettings`).
- **Database:** Đọc/ghi qua các store tương ứng.
- **Realtime:** Observe `ZLModConversationPolicyDidChangeNotification`, `ZLModAccountDidChangeNotification`, `ZLModThemeDidChangeNotification` (`ZLModUI.m:899-901`); `ZLModBridgeViewController` observe `ZLModBridgeStatusDidChangeNotification` (`ZLModUI.m:25-28`).
- **Dependencies:** Toàn bộ module trong `Sources/`.
- **Current behavior:** Hiển thị đủ 10 section, live counts (số hội thoại policy, số bản ghi anti-recall, số mẫu quick reply, số ghi chú, số dòng log, số module active), dialog xác nhận Reset All.
- **Edge cases:** `ZLModSettingsViewController` không observe `ZLModBridgeStatusDidChangeNotification` nên dòng trạng thái Bridge ở màn chính không tự cập nhật cho đến khi `viewWillAppear:`.
- **Error handling:** Hiện toast khi lỗi mạng/giải mã thất bại.
- **Current limitations:** Không dùng cell reuse ở `ZLModBridgeViewController` (alloc `UITableViewCell` mới mỗi lần `cellForRowAtIndexPath:`, `ZLModUI.m:89-169`).
- **Current bugs:**
  1. `ZLModUI.m:174, 204, 222, 242` tự post `ZLModPrefsDidChangeNotification` trùng lặp với notification do `ZLModPreferences` vừa post; riêng ServerURL và Token còn gọi thêm `[mgr reconnect]` trực tiếp → **kích hoạt `reconnect` 3 lần liên tiếp!**
  2. `ZLModAntiRecallHistoryViewController` tạo `NSDateFormatter` mới trong `cellForRowAtIndexPath:` (`ZLModUI.m:439`) gây tốn CPU khi cuộn danh sách.
  3. `Reset All ZLMod Settings` (`ZLModUI.m:1230-1234`) KHÔNG xóa `ZLModAntiRecallStore`, KHÔNG xóa `ZLModPrivateNotesStore`, KHÔNG reset `ZLModQuickReplyStore`, và KHÔNG ngắt kết nối `ZLModBridgeManager` (dù prefs `serverUrl` bị xóa, chỉ có `kZLModBridgeServerURL` notification được bắn).
- **Status:** `IMPLEMENTED`

---

### F08 — Liquid Glass / Blur Tab Bar
- **Feature name:** Liquid Glass Tab Bar (`kZLModGlassTabBar`)
- **Purpose:** Áp dụng hiệu ứng mờ kính (`UIBlurEffectStyleSystemUltraThinMaterial`) cho thanh Tab Bar của Zalo.
- **User goal:** Làm thanh Tab Bar trong suốt kiểu Glass.
- **Entry point:** Toggle `"Liquid Glass Tab Bar"` trong Appearance & Theme.
- **UI location:** `ZaloTabBarViewController`'s `UITabBar`.
- **Frontend implementation:** `Sources/ZLModGlass.m:1-134`.
- **Backend implementation:** Không.
- **API:** Hook `ZaloTabBarViewController -viewDidAppear:` (`ZLModGlass.m:113`), chỉnh `UITabBar.standardAppearance` & `scrollEdgeAppearance`.
- **Database:** `kZLModGlassTabBar` trong `ZLModPreferences`.
- **Realtime:** Observe `ZLModPrefsDidChangeNotification`.
- **Dependencies:** `ZLModPreferences`, `ZLModHookEngine`.
- **Current behavior:** Lưu bản sao `standardAppearance`/`scrollEdgeAppearance` gốc vào static `gSavedStandard`/`gSavedScrollEdge`, sau đó gán `backgroundEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial]`. Tắt toggle sẽ phục hồi từ `gSavedStandard`/`gSavedScrollEdge`.
- **Edge cases:** Nếu `ZaloTabBarViewController` không tồn tại → `Glass = NOT_INSTALLED`.
- **Error handling:** Kiểm tra `gActiveTabBar` yếu (`__weak`).
- **Current limitations:** **KHÔNG dùng `UIGlassEffect` trên iOS 26** (code đã bỏ hoàn toàn vì gây freeze khi Zalo có `UIDesignRequiresCompatibility = YES`), trái ngược với mô tả trong `README.md`, `docs/FEATURES.md`, và `Scripts/report.sh`.
- **Current bugs:**
  1. Xung đột trực tiếp với `ZLModTheme.m`: nếu bật Theme trước rồi bật Glass, `gSavedStandard` lưu appearance của Theme; sau đó reset Theme rồi tắt Glass sẽ khôi phục lại appearance của Theme đã reset!
  2. `ZLModUI.m:13` phải dùng `extern NSString *ZLModGlassMaterialDescription(void);` vì hàm không khai báo trong `ZLMod.h`.
- **Status:** `PARTIAL`

---

### F09 — Theme Presets & Custom Accent Tint
- **Feature name:** Theme Engine (`kZLModThemePreset`, `kZLModThemeTintHex`)
- **Purpose:** Cho phép chọn 4 bảng màu (`classic_blue`, `dark_oled`, `pure_black`, `ocean_teal`) hoặc màu nhấn `#RRGGBB` tùy chỉnh.
- **User goal:** Đổi giao diện sáng/tối OLED và màu nhấn của Zalo, có thể quay về nguyên bản.
- **Entry point:** `"Theme Preset"` & `"Custom Accent Tint (#HEX)"` trong Appearance & Theme.
- **UI location:** ActionSheet chọn preset & Alert nhập hex (`ZLModUI.m:1152-1197`), áp dụng lên toàn bộ `UIWindow`, `UINavigationBar`, `UITabBar`.
- **Frontend implementation:** `Sources/ZLModTheme.m:1-370`.
- **Backend implementation:** Không.
- **API:** UIKit appearance APIs trên tất cả `UIWindow` đang mở + duyệt đệ quy tìm `UINavigationController`/`UITabBarController`.
- **Database:** `kZLModThemePreset`, `kZLModThemeTintHex` trong `ZLModPreferences`.
- **Realtime:** Observe `ZLModPrefsDidChangeNotification` và `UIApplicationDidBecomeActiveNotification`, post `ZLModThemeDidChangeNotification`.
- **Dependencies:** `ZLModPreferences`, `UIKit`.
- **Current behavior:** Mặc định `@""` (tắt hoàn toàn, không chạm UI Zalo). Trước khi áp dụng lần đầu, lưu baseline vào associated object của từng window/navBar/tabBar. Khi đổi sang `"Mặc định hệ thống"` hoặc Reset All, khôi phục baseline.
- **Edge cases:** Chuỗi hex không hợp lệ (không phải 6 ký tự `[0-9A-Fa-f]`) sẽ bị xóa về `@""`.
- **Error handling:** Bỏ qua màu hex sai định dạng một cách an toàn (không có thông báo lỗi cho user khi nhập sai hex!).
- **Current limitations:** Chỉ đổi `UIWindow`/`UINavigationBar`/`UITabBar` — **không** đổi được màu chat bubble, background cell, hay custom views vẽ bằng `ZDSColor` của Zalo (dù roadmap Phase 3 từng dự định). Các `UINavigationController` modal mở sau khi đã apply sẽ không được áp dụng cho đến lần `DidBecomeActive` hoặc đổi lại theme.
- **Current bugs:** Xung đột baseline `UITabBarAppearance` với `ZLModGlass.m`; thiếu phản hồi lỗi khi user gõ mã hex sai (chỉ lặng lẽ đặt lại "Mặc định").
- **Status:** `IMPLEMENTED`

---

### F10 — Hide Typing Indicator (Global & Per-Conversation)
- **Feature name:** Hide Typing (`kZLModHideTyping` + per-chat `ZLModTypingPolicy`)
- **Purpose:** Chặn Zalo gửi trạng thái "đang soạn tin nhắn..." sang đối phương (toàn cục hoặc riêng từng hội thoại).
- **User goal:** Soạn tin riêng tư không để người nhận thấy biểu tượng đang gõ.
- **Entry point:** Toggle `"Hide Typing Indicator"` trong Privacy (Global) HOẶC nhấn giữ hội thoại → `"Ẩn đang nhập"`.
- **UI location:** Dashboard Privacy section + Inbox long-press menu + `ZLModConversationPoliciesViewController`.
- **Frontend implementation:** `ZLModUI.m`, `ZLModConversationMenu.m`.
- **Backend implementation:** `Sources/ZLModPrivacy.m:310-352`, `Sources/ZLModPolicyStore.m`.
- **API:**
  - `ChatDataManager -sendTypingWithType:toUserId:messageType:isE2eeChat:` (instance, 4 args, return `Bc` → trả `NO` khi chặn).
  - `ChatSocketCmdHelper +sendStatusTyping:withCommand:withSubCommand:withDestType:withGlobalMessageId:` (class `+`, 5 args, return `Q` → trả `0` khi chặn).
- **Database:** Global toggle trong `ZLModPreferences`; per-chat trong `Documents/ZLModPolicies.plist`.
- **Realtime:** Đọc toggle & policy trực tiếp tại thời điểm gọi hàm (tác dụng tức thì không cần restart).
- **Dependencies:** `ZLModHookEngine`, `ZLModPreferences`, `ZLModPolicyStore` (`ZLModPrivacyContext`).
- **Current behavior:** Khi global `kZLModHideTyping == YES` HOẶC `ZLModConversationPolicyStore` có `hideTyping == YES` cho `toUserId` (hoặc `activeThreadId`), hook chặn không gọi `origIMP`.
- **Edge cases:** Khi `accountScope == nil` (fail-closed), per-chat policy trả `FollowOriginal` (`NO`), chỉ còn global toggle có tác dụng.
- **Error handling:** Thiếu class/selector → log và skip, ghi số hook vào `TypingPrivacy`.
- **Current limitations:** Hành vi thực tế trên thiết bị iOS thật là `UNKNOWN — NEEDS VERIFICATION` (mới xác minh tĩnh Mach-O).
- **Current bugs:** `ChatSocketCmdHelper +sendStatusTyping:...` (`ZLModPrivacy.m:337-350`) **không phân tích địa chỉ đích trong tham số socket** mà chỉ hỏi `[ZLModPrivacyContext activeThreadId]` — nếu socket gửi typing/retry cho một hội thoại khác hoặc sau khi vừa thoát màn chat, per-chat policy sẽ kiểm tra sai hội thoại!
- **Status:** `PARTIAL`

---

### F11 — Control Seen Status & Read Receipts (Global & Per-Conversation)
- **Feature name:** Control Seen (`kZLModHideSeen`) & Control Read Receipts (`kZLModHideReadReceipts`) + per-chat `ZLModSeenPolicy`
- **Purpose:** Chặn gửi tín hiệu "Đã xem" và biên nhận đọc tin lên máy chủ Zalo (toàn cục hoặc từng cuộc trò chuyện).
- **User goal:** Đọc tin nhắn mà không hiển thị trạng thái "Đã xem" cho người gửi.
- **Entry point:** 2 toggle toàn cục trong Privacy (Global) + nút `"Ẩn đã xem"` trong menu nhấn giữ hội thoại.
- **UI location:** Dashboard Privacy section + Inbox long-press menu + `ZLModConversationPoliciesViewController`.
- **Frontend implementation:** `ZLModUI.m`, `ZLModConversationMenu.m`.
- **Backend implementation:** `Sources/ZLModPrivacy.m:100-308`, `Sources/ZLModPolicyStore.m`.
- **API:** 13 hooks:
  - Context tracker: `BaseChatTVC -zaloViewDidAppear:`, `-zaloViewWillDisappear:`
  - Class-wide scan: `-sendSeenMessageWithChatEntity:`, `-sendSeenMessageWithTalkTableItem:`, `-sendSeenMessages:messageDict:incomingData:`
  - `ChatSendSeenDataManager`: `-_sendSeenMessageWithSeenData:messageType:`, `-sendSeenServer`, `-forceSendSeenServer`, `-sendSeenLastMessageWithThreadIds:withMessageType:` (lọc mảng `threadIds` bỏ các thread có `hideSeen=YES`!)
  - `ChatSocketCmdHelper`: `+sendSeenChatACK:withSubCommandType:`, `+sendSeenGroupChatACKByData:withSubCommandType:`
  - `FriendRequestManager`: `-sendSeenCurrentUnreadFriendRequest:sourceView:`, `-sendSeenCurrentUnreadFriendRequest:retryTime:sourceView:`
- **Database:** Global trong `ZLModPreferences`; per-chat trong `Documents/ZLModPolicies.plist`.
- **Realtime:** Kiểm tra động ngay lúc gọi hàm.
- **Dependencies:** `ZLModHookEngine`, `ZLModPreferences`, `ZLModPolicyStore`.
- **Current behavior:** Khi chặn Seen: các hàm gửi seen cho entity/item bị drop; batch `sendSeenLastMessageWithThreadIds:` lọc bỏ từng thread được bảo vệ rồi vẫn gửi các thread còn lại! Khi chặn Read Receipts: `sendSeenServer`, `forceSendSeenServer`, và 2 hàm socket ACK bị chặn.
- **Edge cases:** `sendSeenServer` và `forceSendSeenServer` không có tham số threadId nên nếu chỉ bật per-chat Hide Seen (không bật global Hide Read Receipts), chúng kiểm tra `[ZLModPrivacyContext activeThreadId]` — có thể chặn tạm flush cho các thread khác trong lúc user đang mở thread ẩn seen.
- **Error handling:** Thiếu selector → bỏ qua an toàn; `ZLModPrivacy.m:407-418` báo cáo trạng thái riêng cho `SeenPrivacy`, `TypingPrivacy`, và tổng `Privacy`.
- **Current limitations:** Chỉ chặn gửi lên server, không giữ trạng thái unread của server (cần dùng kết hợp Local Mark Unread). Xác minh trên iPhone thật: `UNKNOWN — NEEDS VERIFICATION`.
- **Current bugs:**
  1. Quét toàn bộ ~19.645 app classes **3 lần liên tiếp** lúc boot (`ZLModPrivacy.m:139, 153, 167`) thay vì gộp 1 vòng lặp.
  2. `sendSeenServer` / `forceSendSeenServer` dùng `activeThreadId` có thể gây side-effect chặn flush seen cho cuộc trò chuyện khác khi đang đứng trong một cuộc trò chuyện bật `hideSeen`.
- **Status:** `IMPLEMENTED`

---

### F12 — Disable Tracking & Analytics (URL Filter)
- **Feature name:** URI Filter (`kZLModBlockTracking`, `kZLModBlockAdRequests`)
- **Purpose:** Chặn yêu cầu HTTP tới máy chủ tracking và quảng cáo của Zalo ngay trong tiến trình, trả về HTTP 204 rỗng.
- **User goal:** Giảm theo dõi hành vi và chặn tải dữ liệu quảng cáo.
- **Entry point:** Toggle `"Disable Tracking & Analytics"` và `"Block Ad Requests"`.
- **UI location:** Dashboard sections Privacy (Global) & Ad Blocking.
- **Frontend implementation:** `ZLModUI.m:936, 977`.
- **Backend implementation:** `Sources/ZLModURIFilter.m:1-96`.
- **API:** `ZLModBlockURLProtocol : NSURLProtocol` đăng ký qua `[NSURLProtocol registerClass:]`.
  - Tracking rules: host `log.api.zaloapp.com`, path prefix `/tracking` hoặc chứa `/tracking-v3`, `/tracking-rt`.
  - Ads rules: host `ads.platform.zalo.me`, path chứa `/zpads/`, `/get/ads`, `/ads_out_stream`, `/ads_boost`, `/v1/ads/`.
- **Database:** `kZLModBlockTracking`, `kZLModBlockAdRequests` trong `ZLModPreferences`.
- **Realtime:** Kiểm tra toggle trực tiếp trong `+canInitWithRequest:`.
- **Dependencies:** `ZLModPreferences`, `Foundation`.
- **Current behavior:** Nếu request khớp rule và toggle tương ứng đang bật, `startLoading` trả ngay `NSHTTPURLResponse` status `204` (`Content-Length: 0`) và kết thúc request không đi ra mạng.
- **Edge cases:** Trả về 204 rỗng có thể khiến parser JSON phía Zalo nhận body rỗng (được kỳ vọng là không crash nhưng chưa verify hết mọi caller).
- **Error handling:** `stopLoading` là no-op.
- **Current limitations / Current bugs:**
  1. **Lỗ hổng bao phủ lớn:** `[NSURLProtocol registerClass:]` trong iOS **CHỈ** chặn `NSURLConnection` và `[NSURLSession sharedSession]`! Mọi `NSURLSession` tạo từ `[NSURLSessionConfiguration defaultSessionConfiguration]` hoặc `ephemeralSessionConfiguration` (chuẩn của hầu hết thư viện mạng iOS hiện đại như AFNetworking/Alamofire/Zalo SDK) và toàn bộ `WKWebView` **BỎ QUA hoàn toàn `ZLModBlockURLProtocol`** trừ khi hook `[NSURLSessionConfiguration protocolClasses]`!
- **Status:** `PARTIAL`

---

### F13 — Disable Firebase Collection
- **Feature name:** Disable Firebase (`kZLModBlockFirebase`)
- **Purpose:** Tắt thu thập dữ liệu của Firebase Analytics, Performance và Crashlytics nếu có trong tiến trình Zalo.
- **User goal:** Ngăn Zalo gửi telemetry qua Firebase SDK.
- **Entry point:** Toggle `"Disable Firebase Collection"` trong Privacy (Global).
- **UI location:** Dashboard section Privacy (Global) (`ZLModUI.m:937`).
- **Frontend implementation:** `ZLModUI.m:937`.
- **Backend implementation:** `Sources/ZLModPrivacy.m:354-386`.
- **API:** Runtime calls tới `FIRAnalytics +setAnalyticsCollectionEnabled:NO`, `FIRPerformance +sharedInstance` → `-setDataCollectionEnabled:NO`, `FIRCrashlytics +crashlytics` → `-setCrashlyticsCollectionEnabled:NO`.
- **Database:** `kZLModBlockFirebase` trong `ZLModPreferences`.
- **Realtime:** Chạy khi boot và khi nhận `ZLModPrefsDidChangeNotification`.
- **Dependencies:** `ZLModPreferences`, `objc/runtime`.
- **Current behavior:** Khi bật toggle ON, gọi các setter tắt thu thập của 3 Firebase class (nếu class tồn tại tại runtime).
- **Edge cases:** `docs/IPA-ANALYSIS.md:84-87` ghi nhận Zalo 26.11.01 không nhúng framework `FirebaseAnalytics` rời nhưng có `FirebaseCore*`/`FirebaseSessions`/`GoogleDataTransport` — cần kiểm chứng runtime các class `FIR*` có phản hồi không (`UNKNOWN — NEEDS VERIFICATION`).
- **Error handling:** Bọc `@try/@catch`, kiểm tra `respondsToSelector:`.
- **Current bugs:**
  1. **`ZLModPrivacy.m:358`:** `if (!blocked) return;` — khi người dùng **TẮT** toggle này (hoặc nhấn Reset All), hàm return sớm và **KHÔNG BAO GIỜ gọi lại `set...CollectionEnabled:YES`** cho tới khi restart app (hoặc thậm chí vĩnh viễn nếu Firebase lưu cờ đó xuống `NSUserDefaults` của chính Firebase!).
- **Status:** `PARTIAL`

---

### F14 — Per-Conversation Long-Press Context Menu
- **Feature name:** Inbox Long-Press Context Menu (`ZLModConversationMenu`)
- **Purpose:** Chèn 4 thao tác nhanh của ZLMod (Ẩn đã xem, Ẩn đang nhập, Đánh dấu chưa đọc, Ghi chú riêng tư) khi nhấn giữ một hội thoại ở danh sách tin nhắn.
- **User goal:** Tùy chỉnh quyền riêng tư và ghi chú trực tiếp trên từng cuộc trò chuyện.
- **Entry point:** Nhấn giữ (long-press) một cuộc trò chuyện trong danh sách chat Zalo.
- **UI location:** Section riêng trong context menu của `InboxContextMenuManager`.
- **Frontend implementation:** `Sources/ZLModConversationMenu.m:1-524`.
- **Backend implementation:** `Sources/ZLModConversationMenu.m:525-636`, `ZLModPolicyStore.m`, `ZLModUtilities.m`.
- **API:**
  - Hook `InboxContextMenuManager -getActionsWithItem:` (`ZLModConversationMenu.m:534`, 1 arg, return `@`)
  - Hook `InboxContextMenuManager -contextMenu:didSelectActionId:forIdentifier:` (`ZLModConversationMenu.m:619`, 3 args, return `v`)
  - Tạo action bằng clone mẫu `ContextMenuViewModel` / `ZAContextMenuAction` với action IDs tùy chỉnh: `9101` (Toggle Hide Seen), `9102` (Toggle Hide Typing), `9103` (Toggle Local Unread), `9104` (Private Note).
- **Database:** Lưu vào `ZLModPolicies.plist` và `ZLModNotes.plist`.
- **Realtime:** Tạo phiên `ZLModMenuSession` dùng 1 lần, TTL 120s (tối đa 32 phiên). Khi chọn action → lưu policy → post `ZLModConversationPolicyDidChangeNotification` → cập nhật chấm xanh + hiện toast.
- **Dependencies:** `ZLModHookEngine`, `ZLModPolicyStore`, `ZLModCryptoStore`, `ZLModUtilities`.
- **Current behavior:** Kiểm tra mảng trả về từ Zalo là dạng phẳng hay dạng sectioned (`NSArray<NSArray *>`), đóng gói 4 action thành 1 section riêng (nếu sectioned) và chèn trước nhóm thao tác nguy hiểm (Xóa/Chọn nhiều).
- **Edge cases:** Nếu `accountScope == nil` (fail-closed) → hiện toast báo chưa xác định tài khoản, không lưu.
- **Error handling:** Tự phát hiện kiểu mảng; kiểm tra TTL session 120s.
- **Current bugs:**
  1. **KHÔNG HOẠT ĐỘNG trên IPA `260401/708` đang commit trong `Decrypted/`!** Kiểm tra nhị phân thực tế cho thấy selector `contextMenu:didSelectActionId:forIdentifier:` và class `ZAContextMenuAction` đều **MISSING** khỏi `Payload/Zalo.app/Zalo` của bản `260401`.
  2. Dù `docs/FEATURES.md:33` và `docs/CHANGELOG.md:10` tuyên bố hook cả `InboxContextMenuProvider contextMenuSectionsForItem:info:`, **mã nguồn thực tế `ZLModConversationMenu.m` CHỈ hook `InboxContextMenuManager`**, KHÔNG có bất kỳ hook nào lên `InboxContextMenuProvider`!
- **Status:** `PARTIAL`

---

### F15 — Local Mark Unread (Blue Dot `#0068FF`)
- **Feature name:** Local Unread Indicator
- **Purpose:** Gắn chấm xanh `#0068FF` cục bộ trên hàng hội thoại ở danh sách chat mà không gửi yêu cầu đánh dấu chưa đọc lên server Zalo.
- **User goal:** Ghi nhớ các tin nhắn cần phản hồi lại sau một cách riêng tư.
- **Entry point:** Menu nhấn giữ hội thoại → `"Đánh dấu chưa đọc (Chấm xanh)"`.
- **UI location:** Chấm tròn xanh `10x10 pt` (`tag=0x5A1D`, màu `#0068FF`) đặt trên `UXInboxMessageCell` và `ChatListItemCell`.
- **Frontend implementation:** `Sources/ZLModConversationMenu.m:640-727`.
- **Backend implementation:** `ZLModPolicyStore.m:300-370`.
- **API:** Hook `UXInboxMessageCell -setObject:` & `-prepareForReuse`, và `ChatListItemCell -setListItem:` & `-prepareForReuse`.
- **Database:** Trường `localUnread` trong `Documents/ZLModPolicies.plist` (theo `accountScope`).
- **Realtime:** Theo dõi toàn bộ cell đang sống bằng `[NSHashTable weakObjectsHashTable]`, tự refresh ngay khi nhận `ZLModConversationPolicyDidChangeNotification` hoặc `ZLModAccountDidChangeNotification`.
- **Dependencies:** `ZLModHookEngine`, `ZLModPolicyStore`.
- **Current behavior:** Khi cell bind item, trích `threadId`, hỏi `isLocalUnreadAnyTypeForThreadId:`, hiện/ẩn chấm xanh góc phải trên của cell. Khi `prepareForReuse`, ẩn chấm xanh.
- **Edge cases:** Khi user mở cuộc trò chuyện đó lên đọc, chấm xanh **KHÔNG tự động tắt** — user phải nhấn giữ tắt thủ công hoặc reset trong `ZLModConversationPoliciesViewController`.
- **Error handling:** Thiếu 1 trong 2 class cell (ví dụ `ChatListItemCell` thiếu trên bản `260401`) → class còn lại (`UXInboxMessageCell`) vẫn hoạt động.
- **Current limitations:** Vị trí chấm xanh tính theo frame cố định, có thể che đè lên badge/timestamp trên một số kích thước màn hình (`UNKNOWN — NEEDS VERIFICATION` trên thiết bị thật).
- **Status:** `IMPLEMENTED`

---

### F16 — Anti-Recall (Ghost Preview + In-Place Unhide/Hide + Photo Modal)
- **Feature name:** Anti-Recall (`kZLModAntiRecall`)
- **Purpose:** Chụp trước nội dung tin nhắn trước khi đối phương thu hồi, mã hóa lưu cục bộ 14 ngày, cho phép bấm **"Hiện"** / **"Ẩn"** ngay trong bong bóng chat hoặc xem lịch sử trong Dashboard.
- **User goal:** Xem lại tin nhắn văn bản hoặc ảnh đã bị người gửi thu hồi.
- **Entry point:**
  1. Bật toggle `"Anti-Recall (Ghost Preview)"` trong Dashboard.
  2. Nhấn giữ bong bóng *"Tin nhắn đã được thu hồi"* → chọn **"Hiện"** (`99001`) hoặc **"Ẩn"** (`99002`).
  3. Mở Dashboard → `"Ghost Preview History"` (`ZLModAntiRecallHistoryViewController`).
- **UI location:** Bong bóng chat Zalo (`MenuButton` + `UILabel`), modal xem ảnh `ZLModPhotoPreviewController`, và `ZLModAntiRecallHistoryViewController`.
- **Frontend implementation:** `Sources/ZLModAntiRecall.m:630-1056, 1215-1365`, `Sources/ZLModUI.m:370-475`.
- **Backend implementation:** `Sources/ZLModAntiRecall.m:1-629, 1058-1214`.
- **API:** 8 hooks trên 4 class Zalo:
  - `ConversationModel -didLoadChats:config:`, `-updateDBWhenRecalledChats:completion:`
  - `ChatDataManager -addChats:byUserId:willAlert:fromSrc:`, `-addChat:byUserId:willAlert:fromSrc:`
  - `ChatEntity -_getRecalledMsgPreviewFromSource:`, `-message`
  - `MenuButton -showContextMenuViewWithMenuItemArray:hasReaction:`, `-menuView:didTapItemType:`
- **Database:** Cache live RAM (`liveByKey` + `liveOrder`, cap 500) + `Documents/ZLModAntiRecall.plist` (mã hóa AES-256-CBC + HMAC-SHA256, TTL 14 ngày, tối đa 400 bản ghi/account).
- **Realtime:** Khi snapshot tin nhắn đến, post `@"ZLModChatEntityArrivedNotification"` (dùng bởi `ZLModBridge`). Khi logout/đổi account → xóa `gUnhiddenMessageKeys` và clear live cache.
- **Dependencies:** `ZLModHookEngine`, `ZLModPreferences`, `ZLModCryptoStore`, `ZLModShowToast`.
- **Current behavior:**
  - Chụp tin nhắn đến vào `liveByKey` (RAM).
  - Khi `updateDBWhenRecalledChats:completion:` chạy: tra cứu nội dung trước khi thu hồi trong `liveByKey` (hoặc ngay trên entity) → mã hóa lưu vào `ZLModAntiRecall.plist`.
  - Khi nhấn giữ tin thu hồi: chèn nút **Hiện** (`99001`, icon `eye`) hoặc **Ẩn** (`99002`, icon `eye.slash`).
  - Khi bấm **Hiện**: đánh dấu key trong `gUnhiddenMessageKeys`, sửa `UILabel.text` trực tiếp trong cell, gọi `set_originTextRecallMsg:` và `[chat reloadCellIfNeed]`; nếu tìm thấy ảnh trên `chat` thì mở `ZLModPhotoPreviewController` (pinch-zoom, Lưu ảnh, Sao chép).
- **Edge cases:** Nếu tin nhắn bị thu hồi khi app đang tắt (chưa từng load vào RAM trước khi thu hồi) → không có bản sao để khôi phục.
- **Error handling:** Giải mã lỗi trả chuỗi thông báo fallback.
- **Current bugs:**
  1. **Lọc sai tin nhắn thật chứa chữ `"thu hồi"` hoặc `"recalled"`:** Các dòng `ZLModAntiRecall.m:549, 701, 709, 719, 967, 1105` kiểm tra chuỗi chứa `"thu hồi"`/`"recalled"` để nhận diện tin đã thu hồi — dẫn tới bất kỳ tin nhắn bình thường nào chứa cụm từ này (VD: *"đừng thu hồi tin nhắn"*) bị bỏ qua khi snapshot hoặc bị nhận nhầm là tin thu hồi!
  2. **Rò rỉ bộ nhớ `liveByKey`:** `cacheLiveSnapshot` (`ZLModAntiRecall.m:261-269`) chèn cả `primaryKey` (`g_<gid>`) và `altKey` (`c_<cid>`) vào `liveByKey`, nhưng `liveOrder` chỉ lưu `primaryKey` → khi vượt 500 phần tử, vòng `while` chỉ xóa `primaryKey`, **không bao giờ xóa `altKey`**, gây phình bộ nhớ không giới hạn theo thời gian chạy!
  3. **Trái tuyên bố "Non-Mutating":** Comment dòng 4 và docs tuyên bố không sửa `ChatEntity`, nhưng dòng 1298 gọi thẳng `set_originTextRecallMsg:` trên `chat` và dòng 1196 hook `-[ChatEntity message]` trả về văn bản giải mã.
  4. **Ảnh thu hồi không được lưu bền vững:** `ZLModExtractPhotoFromChat` chỉ đọc `originalImage`/`hdLocalFilePath`/`localFilePath` trực tiếp từ đối tượng `ChatEntity` tại thời điểm bấm "Hiện", KHÔNG sao lưu bytes ảnh khi snapshot → sau khi Zalo xóa file cache ảnh hoặc restart app, không thể khôi phục ảnh!
  5. **Stale UILabel trên cell reuse:** `ZLModUpdateTextInViewHierarchy` lưu text gốc vào associated object `kZLModOrigRecallTextKey` trên `UILabel` và gọi `[targetLabel sizeToFit]`, nhưng KHÔNG hook `prepareForReuse` của chat cell → khi cuộn danh sách, cell tái sử dụng có thể giữ associated object/text cũ hoặc bị cắt khung layout.
  6. **Dead code:** `ZLModPresentRecalledMessageContent` (`ZLModAntiRecall.m:980-1056`) bị đánh dấu `__attribute__((unused))` và không bao giờ chạy.
  7. **Khóa chết CSaving:** Xem F23.
- **Status:** `PARTIAL`

---

### F17 — Delay Send Undo (5-State Atomic FSM)
- **Feature name:** Delay Send Undo (`kZLModDelaySend`, `kZLModDelaySendSeconds`)
- **Purpose:** Hoãn gửi tin nhắn từ 1 đến 10 giây (mặc định 3s) kèm thanh Undo Banner nổi cho phép bấm **"Hủy gửi"** trước khi Zalo đẩy tin ra mạng.
- **User goal:** Kịp hủy tin nhắn gửi nhầm người hoặc sai nội dung.
- **Entry point:** Toggle `"Delay Send Undo"` + chọn `"Delay Duration"` (`1, 3, 5, 8, 10` giây).
- **UI location:** Thanh banner nổi dưới màn hình (`tag=0x5A1E`, chữ `"Đang chờ gửi (Xs)..."` + nút đỏ `"Hủy gửi"`).
- **Frontend implementation:** `Sources/ZLModUtilities.m:749-815`, `Sources/ZLModUI.m:961-966, 1199-1220`.
- **Backend implementation:** `Sources/ZLModUtilities.m:483-748, 820-848`.
- **API:** Hook `ZAChatSendingManager -sendChat:checkUpload:` (`ZLModUtilities.m:833`, 2 args, return `v`). Dùng associated object `kZLModDelaySendBypassAssocKey` để bypass khi timer nổ.
- **Database:** `kZLModDelaySend`, `kZLModDelaySendSeconds` trong `ZLModPreferences`; hàng đợi pending chỉ tồn tại trong RAM (`items` dict khóa `os_unfair_lock`).
- **Realtime:** `dispatch_source_t` timer trên main queue; tự động hủy toàn bộ tin đang chờ khi `UIApplicationDidEnterBackgroundNotification`, `UIApplicationWillTerminateNotification`, `ZLModAccountDidChangeNotification`, hoặc khi tắt `kZLModDelaySend`.
- **Dependencies:** `ZLModHookEngine`, `ZLModPreferences`, `ZLModShowToast`.
- **Current behavior:** FSM 5 trạng thái (`Pending` → `Cancelled` hoặc `Dispatching` → `Dispatched` / `Failed`) bảo đảm không gửi trùng dù user bấm Hủy đúng thời điểm timer nổ.
- **Edge cases:** Nếu user gửi liên tiếp 2 tin nhắn trong vòng 3 giây, banner của tin #2 **ghi đè và xóa banner của tin #1** (`ZLModUtilities.m:755-756`), nên user mất nút hủy tin #1 (dù tin #1 vẫn đang đếm ngược và sẽ tự gửi!).
- **Error handling:** `@try/@catch` khi gọi `origIMP` → chuyển sang `ZLModDelaySendStateFailed` và log lý do, không có UI thông báo thất bại cho user.
- **Current limitations:** Nhãn banner không đếm ngược live theo từng giây (hiển thị tĩnh `"Đang chờ gửi (3s)..."`). Không có UI báo cho user khi tin đang pending bị auto-cancel do chuyển app sang nền (`app_backgrounded`).
- **Current bugs:**
  1. Gửi nhanh nhiều tin liên tiếp làm mất UI hủy của các tin trước đó (chỉ 1 banner duy nhất theo `tag=0x5A1E`).
  2. Khi gửi bị hủy (`cancelPendingSendWithId:`), Zalo có thể đã vẽ bubble tin nhắn tạm (optimistic UI) ở khung chat trước khi gọi `sendChat:checkUpload:` → bubble gửi nhầm có thể đứng kẹt ở trạng thái đang gửi (`UNKNOWN — NEEDS VERIFICATION` trên thiết bị thật).
- **Status:** `IMPLEMENTED`

---

### F18 — Quick Reply Templates
- **Feature name:** Quick Reply Templates
- **Purpose:** Lưu tối đa 50 mẫu câu trả lời nhanh cục bộ và chèn an toàn vào khung soạn thảo Zalo (tuyệt đối không tự gửi).
- **User goal:** Trả lời nhanh các câu thường dùng mà vẫn kiểm tra lại được trước khi nhấn Gửi.
- **Entry point:** Dashboard → Utilities → `"Quick Reply Templates"` (`ZLModQuickRepliesViewController`).
- **UI location:** `ZLModQuickRepliesViewController` (`ZLModUI.m:479-649`).
- **Frontend implementation:** `ZLModUI.m:479-649` (thêm `+`, chế độ `Edit` xóa/kéo sắp xếp, tap chọn ActionSheet: Chèn / Sửa / Xóa, nút Khôi phục mặc định).
- **Backend implementation:** `Sources/ZLModUtilities.m:275-481`.
- **API:** Chèn text qua `BaseChatTVC -fillChatBarWithText:` (`ZLModUtilities.m:448-456`), fallback tìm `firstResponder` `UITextView`/`UITextField` trong keyWindow; nếu không có khung chat nào mở thì copy vào `UIPasteboard`.
- **Database:** `Documents/ZLModQuickReplies.plist` (binary plist array, KHÔNG mã hóa, KHÔNG phân tách theo `accountScope` — dùng chung mọi tài khoản). Mặc định 3 mẫu tiếng Việt.
- **Realtime:** Không.
- **Dependencies:** `ZLModPolicyStore` (`ZLModPrivacyContext activeChatController`), `ZLModShowToast`.
- **Current behavior:** CRUD đầy đủ, rollback in-memory nếu ghi đĩa thất bại.
- **Edge cases:** Vì màn `ZLModQuickRepliesViewController` đang được mở từ Settings (hoặc modal Shake), nếu mở từ Settings thì `activeChatController` là `nil` → tap "Chèn vào khung chat đang mở" sẽ luôn rơi sang nhánh copy clipboard! Chỉ khi user mở chat → lắc máy mở ZLMod modal → vào Quick Replies → bấm Chèn mới chèn được trực tiếp vào `activeChatController`.
- **Error handling:** Trả `NO` nếu vượt trần 50 mẫu hoặc chuỗi rỗng (nhưng `addTapped:` ở `ZLModUI.m:512` không báo toast lỗi khi đạt giới hạn 50 mẫu!).
- **Current bugs:**
  1. Không có thông báo lỗi khi thêm thất bại (đã đủ 50 mẫu hoặc nhập toàn khoảng trắng).
  2. Không có đường tắt mở Quick Reply ngay từ màn chat (phải đi đường vòng: Lắc máy → Dashboard → Quick Reply Templates → Chạm mẫu → Chèn → Đóng modal).
- **Status:** `IMPLEMENTED`

---

### F19 — Encrypted Private Notes per Conversation
- **Feature name:** Encrypted Private Notes
- **Purpose:** Gắn ghi chú riêng tư đã mã hóa cho từng cuộc trò chuyện (chỉ lưu cục bộ, không gửi lên Zalo).
- **User goal:** Ghi nhớ thông tin cá nhân về liên hệ/nhóm ngay trong app Zalo.
- **Entry point:** (1) Nhấn giữ hội thoại → `"Ghi chú riêng tư"`; (2) Dashboard → Utilities → `"Encrypted Private Notes"` (`ZLModPrivateNotesViewController`).
- **UI location:** `ZLModPrivateNotesViewController` (`ZLModUI.m:653-737`) + `UIAlertController` có 1 `UITextField` (`ZLModUtilities.m:227-273`).
- **Frontend implementation:** `ZLModUI.m:653-737`, `ZLModUtilities.m:227-273`.
- **Backend implementation:** `Sources/ZLModUtilities.m:13-225`.
- **API:** Nội bộ `ZLModCryptoBox`.
- **Database:** `Documents/ZLModNotes.plist` (schema v2, khóa `accountScope:threadId`, trường `cipher` mã hóa AES-256-CBC + HMAC-SHA256 với AAD `"ZLModNote.v2|<scope>|<threadId>"`).
- **Realtime:** Không.
- **Dependencies:** `ZLModCryptoStore`, `ZLModShowToast`.
- **Current behavior:** Lưu, sửa, xóa từng ghi chú hoặc xóa tất cả ghi chú của tài khoản hiện tại; lưu trắng sẽ xóa ghi chú.
- **Edge cases:** Fail-closed nếu `accountScope == nil` hoặc Keychain không sẵn sàng (`setNote:` trả `NO`, nhưng không báo toast lỗi cho user!).
- **Error handling:** Rollback in-memory nếu ghi plist lỗi; lỗi mã hóa trả `NO` im lặng.
- **Current limitations:** Lưu `threadId` dạng plaintext trong plist (dù nội dung `note` đã mã hóa); màn danh sách chỉ hiển thị `threadHash` (VD `h_a1b2c3d4`) thay vì tên cuộc trò chuyện khiến user rất khó nhận ra ghi chú thuộc về ai! Editor dùng `UITextField` 1 dòng, không gõ được nhiều dòng.
- **Status:** `IMPLEMENTED`

---

### F20 — Ad Blocking (UI View Disarming + Network Request Filter)
- **Feature name:** Hide Ads (`kZLModHideAds`) & Block Ad Requests (`kZLModBlockAdRequests`)
- **Purpose:** Ẩn các view quảng cáo đã xác minh trong giao diện Zalo và chặn HTTP requests tải quảng cáo.
- **User goal:** Loại bỏ quảng cáo khỏi Feed/Inbox/OA.
- **Entry point:** Toggle `"Hide Ads"` và `"Block Ad Requests"` trong section Ad Blocking.
- **UI location:** Dashboard section Ad Blocking (`ZLModUI.m:975-978`).
- **Frontend implementation:** `ZLModAds.m:1-77` (hook `didMoveToWindow` & `setHidden:` trên `ZInstantFeedAdsView` và `LocationOAAdsCell`).
- **Backend implementation:** `ZLModURIFilter.m:26-36`.
- **API:** Hook `ZInstantFeedAdsView` & `LocationOAAdsCell` (`-didMoveToWindow`, `-setHidden:`) + `NSURLProtocol` filter.
- **Database:** `kZLModHideAds`, `kZLModBlockAdRequests` trong `ZLModPreferences`.
- **Realtime:** Đọc toggle tại thời điểm view hiển thị hoặc gọi `setHidden:`.
- **Dependencies:** `ZLModHookEngine`, `ZLModPreferences`, `ZLModURIFilter`.
- **Current behavior:** Khi bật `Hide Ads`, ép `hidden = YES`, `alpha = 0.0`, `userInteractionEnabled = NO`.
- **Edge cases:** Tắt `Hide Ads` không tự khôi phục `alpha = 1.0` / `userInteractionEnabled = YES` cho các view đã bị ẩn trong bộ nhớ cho tới khi cell được tạo lại.
- **Error handling:** Bỏ qua nếu class không tồn tại.
- **Current limitations:** Ẩn view mà không ép chiều cao cell về `0` có thể để lại khoảng trắng trên feed/inbox (`UNKNOWN — NEEDS VERIFICATION` trên thiết bị thật). Phần chặn request chịu chung hạn chế bypass `NSURLSessionConfiguration` của `ZLModURIFilter`. URL `/ads_out_stream` không có trong bản `260401`.
- **Status:** `PARTIAL`

---

### F21 — Feature Restoration (Profile Music, Google Drive Backup, More Tab)
- **Feature name:** Restore Profile Music / Google Drive Backup / More Tab
- **Purpose:** Kích hoạt lại các tính năng client-side bị Zalo ẩn qua feature flag.
- **User goal:** Dùng lại nhạc trang cá nhân, mục sao lưu Google Drive, và tab More.
- **Entry point:** 3 toggle trong section Feature Restoration (`ZLModUI.m:980-984`).
- **UI location:** Dashboard section Feature Restoration.
- **Frontend implementation:** `ZLModUI.m:980-984`.
- **Backend implementation:** `Sources/ZLModFeatures.m:1-193`.
- **API:**
  - Profile Music: ép trả `YES` cho 4 getters (`enableProfileMusic`, `enableProfileMusicRBT`, `enableShareProfileMusic`, `newFlagEnableProfileMusic`) trên class khớp `ZLModClassLooksProfileMusic`, hook `setEnableProfileMusicLocal:`, và mirror 4 external keys (`kProfileMusicSetting`, `profile_music`, `features@profile_music`, `enable_rbt`).
  - Google Drive: bridge 2 chiều `_basicBackupGDriveSectionZInstantData` ↔ `__basicBackupGDriveSectionZInstantData` + mirror external key `restore_gdrive_photo_csc`.
  - More Tab: mirror external key `enable_tabmore`.
- **Database:** 3 toggle trong `ZLModPreferences` + ghi đè/khôi phục 6 external keys trong `standardUserDefaults` & App Group.
- **Realtime:** Observe `ZLModPrefsDidChangeNotification` để áp dụng/khôi phục external keys ngay khi đổi toggle (nhưng màn hình Zalo đã load sẵn thường cần mở lại hoặc restart app).
- **Dependencies:** `ZLModHookEngine`, `ZLModPreferences`.
- **Current behavior:** Áp dụng external keys và runtime getters theo toggle.
- **Edge cases:** Bản `260401/708` trong `Decrypted/` **thiếu cả 2 selector GDrive** (`_basicBackupGDriveSectionZInstantData`, `__basicBackupGDriveSectionZInstantData`) và thiếu key `features@profile_music`.
- **Error handling:** Thiếu selector → log count = 0.
- **Current limitations:** Không kiểm soát được phía server Zalo nếu server từ chối API nhạc/GDrive (`UNKNOWN — NEEDS VERIFICATION`).
- **Current bugs:**
  1. Leftover upstream function name `ZyForceBoolGetter` tại `ZLModFeatures.m:20, 74`.
  2. Quét toàn bộ ~19.645 app classes **6 lần** lúc boot (4 getters + 1 localSetter + 1 GDrive bridge)!
- **Status:** `PARTIAL`

---

### F22 — C-Bridge: CPairing (WebSocket Connection, Health Ping & LAN Discovery)
- **Feature name:** C-Bridge CPairing (`kZLModBridgeServerURL`, `kZLModBridgeToken`)
- **Purpose:** Kết nối WebSocket tới Local Server trong mạng LAN, đo độ trễ ping/pong (heartbeat 20s), và kiểm tra sức khỏe server qua HTTP.
- **User goal:** Ghép nối iPhone với Local Server (`zalo-meet-bot`) để dùng CSaving và CDeploy.
- **Entry point:** Dashboard → `"C-Bridge & Local Server"` (`ZLModBridgeViewController`).
- **UI location:** Section 0 ("Trạng thái kết nối (CPairing)") & Section 1 ("Máy chủ cục bộ") trong `ZLModBridgeViewController` (`ZLModUI.m:87-122, 183-227`).
- **Frontend implementation:** `ZLModUI.m:17-260`.
- **Backend implementation:** `Sources/ZLModBridge.m:80-259, 465-498, 566-610` (phía server nằm ngoài repo này: `UNKNOWN — NEEDS VERIFICATION`).
- **API:**
  - `WS/WSS <scheme>://<host>[:port]/cbridge/ws?token=<tok>&account=<scope>&userId=<rawUid>`
  - `GET <serverUrl>/api/cbridge/health` với header `Authorization: Bearer <token>`
- **Database:** `kZLModBridgeServerURL`, `kZLModBridgeToken` trong `ZLModPreferences` (plaintext `NSUserDefaults`!).
- **Realtime:** `NSURLSessionWebSocketTask`, heartbeat `dispatch_source_t` 20s gửi `{"action":"ping","timestamp":...}`, tự reconnect sau 5s.
- **Dependencies:** `ZLModPreferences`, `ZLModCryptoStore`, `ZLModHookEngine`.
- **Current bugs (NGHIÊM TRỌNG):**
  1. **BROKEN HTTP Healthcheck (`ZLModBridge.m:472`):** `[serverUrl stringByAppendingPathComponent:@"/api/cbridge/health"]` biến `"http://192.168.1.15:3000"` thành **`"http:/192.168.1.15:3000/api/cbridge/health"`** (mất 1 dấu `/`) → nút *"Kiểm tra kết nối ngay (Ping Server)"* **LUÔN LỖI** với mọi URL chuẩn `http://` hoặc `https://`!
  2. **TÍNH NĂNG QUẢNG CÁO KHÔNG TỒN TẠI:** Footer UI (`ZLModUI.m:63`) và `release.yml:23` hứa hẹn *"CPairing sẽ tự động phát hiện khi điện thoại và máy chủ cục bộ cùng trong một mạng Wi-Fi/LAN"*, nhưng **KHÔNG HỀ CÓ** code mDNS/Bonjour/UDP discovery nào — user bắt buộc nhập IP:Port bằng tay.
  3. **Stale WebSocket Race Condition + 3x Reconnect:** Lưu Server URL/Token kích hoạt `reconnect` 3 lần liên tiếp (`ZLModUI.m:203-206, 221-224`); task cũ bị cancel gọi callback lỗi ghi đè trạng thái của task mới về `Disconnected` (`ZLModBridge.m:163-172`).
  4. **Query-string encoding bug & secret exposure:** Token gửi trên URL query string bằng `URLQueryAllowedCharacterSet` (không escape `&`, `=`, `+`).
  5. **Latency UI không tự cập nhật:** Khi nhận `pong`, `updateStatus:Connected` thấy `_status == Connected` nên không bắn `ZLModBridgeStatusDidChangeNotification` (`ZLModBridge.m:150, 247`).
  6. `handleAppDidEnterBackground` là hàm rỗng (`ZLModBridge.m:572-574`) — iOS đóng socket ngầm gây lỗi khi quay lại app.
- **Status:** `BROKEN`

---

### F23 — C-Bridge: CSaving (Message Forwarding to Local SQLite)
- **Feature name:** CSaving (`kZLModBridgeSaving`)
- **Purpose:** Chuyển tiếp tin nhắn mới đến qua WebSocket về Local Server để lưu vào SQLite cục bộ.
- **User goal:** Sao lưu lịch sử chat lên máy chủ cá nhân không làm phình bộ nhớ iPhone.
- **Entry point:** Toggle `"Bật CSaving (Lưu tin nhắn)"` (có ở cả Dashboard chính và `ZLModBridgeViewController`).
- **UI location:** `ZLModUI.m:150-167, 994-996`.
- **Frontend implementation:** Switch + bộ đếm `"Tin nhắn đã chuyển tiếp: X tin"` (reset về 0 mỗi lần restart app).
- **Backend implementation:** `Sources/ZLModBridge.m:358-461` nhận từ `Sources/ZLModAntiRecall.m:624`.
- **API:** WebSocket frame `{"action":"csaving","accountScope":"...","messages":[...]}`.
- **Database:** Hàng đợi RAM `pendingMessages` (dự định tối đa 50 tin); SQLite nằm ở Local Server bên ngoài (`UNKNOWN — NEEDS VERIFICATION`).
- **Realtime:** Nhận `ZLModChatEntityArrivedNotification` đồng bộ ngay từ hook của `ZLModAntiRecall` → đẩy vào hàng đợi → gọi `flushPendingMessages` nếu đang `Connected`.
- **Dependencies:** `ZLModAntiRecall` (phụ thuộc ẩn!), `ZLModPreferences`, `ZLModCryptoStore`, `ZLModHookEngine`.
- **Current bugs (NGHIÊM TRỌNG):**
  1. **CHẾT HOÀN TOÀN KHI TẮT ANTI-RECALL:** `ZLModChatEntityArrivedNotification` CHỈ được phát bên trong `ZLModSnapshotChatEntity` (`ZLModAntiRecall.m:624`), mà tất cả 3 điểm gọi đều bị khóa bởi `if ([[ZLModPreferences shared] boolForKey:kZLModAntiRecall])` (`ZLModAntiRecall.m:1068, 1136, 1151`)! User bật CSaving mà tắt Anti-Recall → **0 tin nhắn được lưu!**
  2. **Không có Deduplication cục bộ:** Trái với tên test `test_csaving_bounded_buffer_and_deduplication`, client không hề lọc trùng `identityKey` trong `pendingMessages` hay lịch sử vừa gửi — cùng một tin nhắn xuất hiện qua `addChat:` và `didLoadChats:` sẽ bị gửi lặp nhiều lần.
  3. **Phá trần bộ đệm & đảo thứ tự khi gửi lỗi:** `ZLModBridge.m:457` re-enqueue bằng `[pendingMessages addObjectsFromArray:batch]` không kiểm tra giới hạn 50 và nối tin cũ vào sau tin mới!
  4. **Thiếu selector fallback & sai loại tin nhắn:** Chỉ đọc `globalId`/`clientId`/`senderName`/`senderId`/`createTime`/`isOwner` (bỏ qua fallback `globalMsgId`/`cliMsgId`/`displayname`/`fuid`/`time` như `ZLModAntiRecall` làm); phân loại Photo/Sticker/Voice/File chỉ bằng substring `[Hình ảnh]`/... và **không hề hỗ trợ `Undo`** như `release.yml:24` tuyên bố.
  5. **Data race:** `flushPendingMessages` đọc `self.status` và tăng `self.savedMessagesCount` không có lock giữa thread gọi hook của Zalo và main queue.
- **Status:** `BROKEN`

---

### F24 — C-Bridge: CDeploy (Two-Way Settings Sync)
- **Feature name:** CDeploy (`kZLModBridgeLastSync`)
- **Purpose:** Cho phép đẩy cấu hình ZLMod từ iPhone lên Local Server (`cdeploy_upload`) và nhận cấu hình đẩy từ Local Server xuống (`cdeploy_push`) có hộp thoại xác nhận của người dùng (`cdeploy_ack`).
- **User goal:** Quản lý và đồng bộ cấu hình ZLMod từ giao diện web/Local Server.
- **Entry point:** Nút `"Tải toàn bộ cài đặt lên Máy chủ ngay"` trong `ZLModBridgeViewController`; hoặc tự động hiện `UIAlertController` khi server gửi `action: "cdeploy_push"`.
- **UI location:** Section 3 ("CDeploy") trong `ZLModBridgeViewController` + Modal Alert toàn ứng dụng.
- **Frontend implementation:** `ZLModUI.m:136-149, 251-257`, `ZLModBridge.m:263-287`.
- **Backend implementation:** `ZLModBridge.m:289-356` (server side: `UNKNOWN — NEEDS VERIFICATION`).
- **API:** WS outbound `cdeploy_upload` (17 keys), WS inbound `cdeploy_push`, WS outbound `cdeploy_ack` (`accepted`/`rejected`).
- **Database:** `ZLModPreferences` (`kZLModBridgeLastSync`).
- **Realtime:** Nhận qua `handleIncomingTextMessage:` trên WebSocket.
- **Dependencies:** `ZLModPreferences`, `ZLModCryptoStore`, `ZLModHookEngine` (`ZLModTopPresenterViewController`), `ZLModShowToast`.
- **Current bugs:**
  1. **LỖ HỔNG BẢO MẬT — Arbitrary Preference Write (`ZLModBridge.m:289-303`):** `applyRemoteSettings:` lặp qua MỌI key server gửi xuống mà **không kiểm tra allowlist** — server có thể ghi đè `kZLModBridgeServerURL`, `kZLModBridgeToken`, `kZLModBridgeWebhook`, hoặc chèn key rác/nội bộ `zlmod.internal.prev.*` vào `NSUserDefaults`!
  2. **Upload không cập nhật `lastSync` và không chờ ACK:** `uploadCurrentSettingsWithCompletion:` không cập nhật `kZLModBridgeLastSync` và báo "thành công" ngay khi gửi frame đi mà không biết server đã lưu chưa.
  3. **Alert push bị rơi im lặng:** Nếu `ZLModTopPresenterViewController()` đang bận hiện alert khác hoặc `nil`, popup xác nhận không hiện và client không gửi `cdeploy_ack`.
- **Status:** `PARTIAL`

---

### F25 — C-Bridge: Discord Webhook Relay
- **Feature name:** Discord Webhook Relay (`kZLModBridgeWebhook`)
- **Purpose:** Tài liệu mô tả là chuyển tiếp cảnh báo và thông báo khẩn cấp tới Discord Webhook.
- **User goal:** Nhận cảnh báo (VD: tin nhắn thu hồi / sự kiện quan trọng) trên Discord.
- **Entry point:** `ZLModBridgeViewController` Section 2 ("Discord Webhook Relay").
- **UI location:** 2 dòng: nhập `"Webhook URL"` và nút `"Gửi thông báo kiểm tra tới Discord"`.
- **Frontend implementation:** `ZLModUI.m:122-135, 228-250`.
- **Backend implementation:** `ZLModBridge.m:500-536` (`testWebhookWithCompletion:`).
- **API:** `POST <webhookUrl>` với JSON `{"content": "🔔 **[ZLMod C-Bridge]** Kiểm tra kết nối Webhook thành công từ iPhone!\nTài khoản: `<accountScope>`"}`.
- **Database:** `kZLModBridgeWebhook` lưu **plaintext** trong `NSUserDefaults` (và App Group!).
- **Realtime:** **KHÔNG CÓ.**
- **Dependencies:** `ZLModPreferences`, `ZLModCryptoStore`.
- **Current behavior:** Chỉ gửi được 1 tin nhắn test thủ công khi user bấm nút kiểm tra.
- **Current bugs:**
  1. **Tính năng chưa hoàn thiện (Test-only stub):** Không có bất kỳ hàm `sendWebhookAlert:` hay trigger thực tế nào (khi thu hồi tin, mất kết nối, nhận tin nhắn...) trong toàn bộ repo.
  2. **Không validate domain Discord:** Cho phép POST `accountScope` tới bất kỳ URL `http://` hoặc `https://` nào user dán vào.
- **Status:** `PARTIAL`

---

### F26 — In-App Redacted Runtime Log Viewer
- **Feature name:** Runtime Logs (Redacted)
- **Purpose:** Ghi và xem tối đa 200 dòng log runtime đã che thông tin nhạy cảm, hỗ trợ sao chép và xóa log.
- **User goal:** Chẩn đoán lỗi hook/tương thích trực tiếp trên iPhone không cần nối máy tính xem syslog.
- **Entry point:** Dashboard → Diagnostics & Maintenance → `"Runtime Log Viewer"`.
- **UI location:** `ZLModLogViewerController` (`ZLModUI.m:785-854`).
- **Frontend implementation:** `ZLModUI.m:785-854` (monospaced 11.5pt, header là đường dẫn file log, nút `Xóa` & `Sao chép`).
- **Backend implementation:** `Sources/ZLModCore.m:13-233`.
- **API:** `ZLMOD_LOG(...)` macro → `NSLog` + `ZLModFileLog` (ring buffer 200 dòng + file rotation 512 KB giữ lại 256 KB đuôi).
- **Database:** `<Documents>/ZLMod.log` (fallback `tmp`) và `<AppGroup>/ZLMod.log`.
- **Realtime:** Không (phải vào lại màn hình để thấy log mới, không có pull-to-refresh).
- **Dependencies:** `Foundation`, `UIKit`.
- **Current behavior:** Redact regex: query params `(token|auth|session|cookie|password|secret|key|access_token)=...`, `Bearer ...`, và chuỗi số dài ≥ 10 chữ số (SĐT/UID).
- **Current limitations:** Không redact Discord Webhook URL path (`https://discord.com/api/webhooks/<id>/<token>`) nếu có log ra URL đó (mặc dù hiện tại không log webhook URL). Không có nút Refresh trên màn xem log.
- **Status:** `IMPLEMENTED`

---

### F27 — Offline Packaging, Mach-O Injection & Preflight Forensics Pipeline
- **Feature name:** IPA Repackager, Pure-Python Mach-O Injector & Preflight Auditor
- **Purpose:** Tiêm `libZLMod.dylib` vào IPA Zalo đã decrypt, đổi Bundle ID / Display Name, lọc bỏ App Extensions (`--no-appex` hoặc extension còn mã hóa), xuất IPA unsigned sẵn sàng sideload, và kiểm tra forensics.
- **User goal:** Tạo file `.ipa` cài được qua Sideloadly / xtool / AltStore / TrollStore không cần jailbreak.
- **Entry point:** `Packaging/package_ipa.py`, `Packaging/macho_injector.py`, `Packaging/ipa_preflight.py`, `.github/workflows/build.yml`, `.github/workflows/release.yml`.
- **UI location:** CLI + GitHub Actions Workflow Dispatch UI.
- **Frontend implementation:** Không.
- **Backend implementation:** `Packaging/*.py` (~1.121 dòng Python 3).
- **API:** CLI args (`--input`, `--output`, `--bundle-id`, `--display-name`, `--dylib`, `--no-appex`, `--allow-custom-bundle-id`, `--require-unencrypted-main`, `--require-compatible`, `--require-installable`, `--json-output`).
- **Database:** Đọc `Resources/compatibility.json`.
- **Realtime:** Không.
- **Dependencies:** Python 3 stdlib (`zipfile`, `plistlib`, `struct`, `hashlib`, `shutil`, `subprocess`), optional macOS `codesign`.
- **Current bugs (ĐÃ XÁC MINH THỰC TẾ):**
  1. **Mach-O 64-bit Alignment Violation (`Packaging/macho_injector.py:158-159`):** `inject_rpath_slice` tính `cmdsize = 12 + align8(len(rpath_bytes))` → luôn chia 8 dư 4 (`44` bytes cho `@executable_path/Frameworks\0`), làm lệch chuẩn căn lề 8-byte của toàn bộ load commands phía sau (`LC_LOAD_DYLIB`, `LC_CODE_SIGNATURE`) trên ARM64!
  2. **Preflight Installability False Positive (`Packaging/ipa_preflight.py:281-297`):** Khi `has_codesign == True` và `has_provision == False` (chính xác trạng thái của file IPA trong `Decrypted/`!), `evaluate_installability` gắn sai `state = "PROVISIONED_AND_SIGNED"` và `summary = "IPA contains matching provisioning profile and code resources."` trong khi `directly_installable = False`!
  3. **CI `build.yml:133-138` bỏ quên file IPA khi publish pre-release:** Bước trước đã build ra `build/*.ipa` và upload artifact, nhưng `action-gh-release` trong `build.yml` không liệt kê `build/*.ipa` (chỉ `release.yml` có).
- **Status:** `PARTIAL`

---

### F28 — Unused / Excluded Features (Có bằng chứng trong source)
- **Dead code trong source (`UNUSED`):**
  - `ZLModPresentRecalledMessageContent` (`Sources/ZLModAntiRecall.m:980-1056`): modal `UIAlertController` xem nội dung tin thu hồi cũ từ Build 8, nay bị thay thế bởi In-Place Unhide/Hide và đánh dấu `__attribute__((unused))`.
  - `ZLModCandidateAccountScopesForMigration` (`Sources/ZLModCryptoStore.m:119-123`): khai báo trong `ZLMod.h:119` cho mục đích migration nhưng chỉ trả về `@[scope]` và không được bất kỳ module nào gọi.
- **Explicitly Excluded / Non-Goals (`docs/FEATURES.md:71-78`, `docs/project/ZLMOD_SOURCE_REVIEW.md:20-26`, `Scripts/report.sh:77-79`):**
  - Original Photo Default, ZCloud Premium Unlock, Video Transcode Bypass, Upload Limit / Server TTL Override, Fake Group Admin/Owner, Chat-Head Overlay, Editable `rules.json` hooks.

---

## Phase 10 — Authentication, Identity & Permissions Audit

ZLMod **không quản lý login/logout/session của Zalo**, nhưng có 2 vùng xác thực & phân quyền cần tách bạch rõ:

### 1. Zalo Account Identity (Trong tiến trình iOS)
- **Login / Logout / Session:** Hoàn toàn do host app Zalo xử lý. ZLMod chỉ quan sát:
  - `AppDelegate -didLogout` (`ZLModCore.m:279`)
  - `AppDelegate -didLogin` (`ZLModCore.m:288`)
  - Notification `kNotifyDidLogoutAnimation` (`ZLModCore.m:295`)
- **User Identity Resolution (`ZLModCryptoStore.m:48-117`):**
  - Đọc `userId` từ 4 singleton host theo thứ tự: `ZAApplicationContext +sharedContext` (`currentUserId`/`userId`/`ownerId`) → `ChatDataManager +sharedChatDataManager` (`userId`/`ownerId`/`currentUserId`) → `ChatSendSeenDataManager +shared` → `FTSDatabaseManager +sharedInstance`.
  - Chuyển thành `accountScope = "acc_" + SHA256(rawUserId)[0..15]`.
  - **Fail-closed enforcement:** Nếu không trích được `rawUserId` hợp lệ → `accountScope = nil` → `ZLModConversationPolicyStore`, `ZLModAntiRecallStore`, và `ZLModPrivateNotesStore` từ chối đọc/ghi.
- **Ranh giới bảo mật (Client-side only):**
  - Trên `ZLModPolicyStore.m:430`, cross-account check kiểm tra `[compoundKey hasPrefix:prefix]` ở client.
  - Keychain master key (`master_key_v2`) là **dùng chung toàn thiết bị cho mọi tài khoản Zalo trên máy đó**, chỉ phân tách logic bằng metadata AAD (`accountScope`) khi mã hóa/giải mã.

### 2. C-Bridge Authentication (Client ↔ Local Server)
- **Token:** Một static shared secret (`kZLModBridgeToken`), không có cơ chế OAuth, không có refresh token, không có expiry, không có role/permission.
- **Lưu trữ:** Plaintext trong `NSUserDefaults` (`vn.com.vng.zingalo.zlmod` + App Group `group.zsettings.vn.com.vng.zingalo`) — **KHÔNG dùng Keychain**.
- **Truyền tải:**
  - WebSocket: gửi trong **URL query string** `?token=<token>&account=<scope>&userId=<rawUid>` (`ZLModBridge.m:125`), thường qua HTTP/WS không mã hóa (`ws://192.168.1.x:3000`) trong LAN.
  - HTTP Healthcheck: header `Authorization: Bearer <token>` (`ZLModBridge.m:483`).
- **Frontend validation vs Backend enforcement:**
  - Client **không kiểm tra** chữ ký/nguồn tin cậy của gói `cdeploy_push` và không giới hạn allowlist key trong `applyRemoteSettings:` (`ZLModBridge.m:289-303`) — hoàn toàn tin tưởng bất kỳ server nào phản hồi WebSocket.
  - Backend enforcement của Local Server (`zalo-meet-bot`): **`UNKNOWN — NEEDS VERIFICATION`** (không có mã nguồn server trong repository này).

### 3. iOS System Permissions
- **Photo Library Add Permission:** `ZLModPhotoPreviewController -savePhoto:` gọi `UIImageWriteToSavedPhotosAlbum` (`ZLModAntiRecall.m:907`) — dựa vào `NSPhotoLibraryAddUsageDescription` có sẵn trong `Info.plist` của Zalo.
- **Local Network Permission (iOS 14+):** `ZLModBridgeManager` kết nối `http://192.168.x.x` / `ws://192.168.x.x` — dựa vào quyền Local Network của iOS; nếu user từ chối quyền Local Network, kết nối LAN sẽ thất bại với lỗi socket mà không có màn hình hướng dẫn mở lại quyền trong iOS Settings.
- **App Group / Keychain Entitlements:** Khi re-sign sideload bằng tài khoản Apple ID miễn phí, entitlements gốc của VNG (`CVB6BX97VM`, `group.zsettings.vn.com.vng.zingalo`, Push/VoIP/iCloud) bị công cụ ký gỡ bỏ hoặc thay thế; App Group mirror tự suy biến sang `nil`, còn Keychain dùng default application-identifier access group mới của người ký.


---

## Post-Rebuild Resolution Update (ZLMod 4.0 / Build 11 — 2026-11-26)

All previously `BROKEN`, `PARTIAL`, and `UNUSED` features identified in this specification have been resolved in code across MODULE 01–MODULE 12 (see `FINAL_FIX_REPORT.md`):

- **F-01 / F-02 (Compatibility & Boot)**: Unified `ZLModEvaluateHostCompatibility`, removed loose `"zalo"`/`"zing"` substring bypass, enforced 3-class runtime anchor quorum, two-phase thread-safe boot, `Resources/version.json` single source of truth.
- **F-03 (Settings Entry & Shake)**: Per-VC associated state, zero `memcpy`/`CFRetain`, zero-index-shift `navigationItem` fallback, undo-safe Shake Gesture with `kZLModDisableShakeToOpen` toggle.
- **F-04 / F-05 (Appearance — Theme & Blur Tab Bar)**: Unified `ZLModAppearanceCoordinator` sharing a single baseline; strict `#RRGGBB` validation returning `NO` on invalid hex; honest `UIBlurEffectStyleSystemUltraThinMaterial` labeling.
- **F-06..F-10 (Privacy, URIFilter, Ads, ConversationMenu)**: LIFO `ZLModPrivacyContext` stack; reversible Firebase opt-out & live reversible `Hide Ads`; `NSURLSessionConfiguration` coverage with Bridge/Discord/WS exemptions; `InboxContextMenuManager` + `InboxContextMenuProvider` deduped; schema v3 encrypted conversation display titles.
- **F-11 (Anti-Recall)**: Decoupled onto `ZLModMessageTapBus`, leak-free `liveByKey` atomic `primaryKey`+`altKey` eviction, encrypted disk persistence for recalled photos (`ZLModRecallPhotos`, 20 MB quota, 14-day TTL), non-mutating (zero `set_originTextRecallMsg:`), exact placeholder recall detection, cell reuse cleanup (`prepareForReuse`), pinch-to-zoom photo preview.
- **F-12..F-14 (Utilities)**: Multi-line `UITextView` Private Note editor + v3 encrypted titles; account-scoped Quick Replies + 1-tap `BaseChatTVC` picker; multi-item keyboard-aware 5-state Delay Send Undo FSM.
- **F-15..F-19 (C-Bridge & Discord Relay)**: Keychain-only `ZLModSecretStore` + legacy migration & purge; 4-state WebSocket FSM (`Disconnected/Connecting/Connected/Closing`) with `connectionEpoch`, `2s..30s` backoff, `20s` heartbeat / `10s` pong timeout, `invalidateAndCancel` teardown; CPairing `NSURLComponents` fix + Bonjour LAN auto-discovery + Bearer header; decoupled CSaving with local 500-key dedup & chronological failed-batch prepend; allowlisted CDeploy + pending push queue + guaranteed `cdeploy_ack`; **real automatic Discord Webhook relay** (incoming & recalled, domain validation, dedup, rate limit `1.5s` / HTTP 429 `Retry-After`, max 2 retries, redacted logs).
- **F-20 (Packaging & Preflight)**: 8-byte Mach-O alignment fixed for `LC_RPATH` + enforced in `validate_ipa`; 5-state `evaluate_installability` preflight; 118 verified anchors in `Scripts/anchors.txt`.
- **Remaining Verification Boundary**: Local Windows verification (`72` automated tests: `71 passed, 1 skipped`, `project_gate.py`, real IPA preflight, Objective-C static syntax/linker/header checks) passed cleanly. Native `clang` (`iphoneos` arm64) build, `Scripts/gates.sh`, and physical iPhone runtime E2E testing require macOS CI (`macos-26`) and an iOS device.
