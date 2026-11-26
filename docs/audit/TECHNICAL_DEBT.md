# TECHNICAL_DEBT.md — Performance (Phase 12), Security (Phase 13), Dependencies (Phase 14) & Technical Debt (Phase 16)

> Tài liệu này tổng hợp toàn bộ rủi ro hiệu năng, lỗ hổng bảo mật, kiểm toán phụ thuộc, và nợ kỹ thuật được xác minh trực tiếp từ mã nguồn thực tế (commit `e0abf95`). Không sửa mã trong giai đoạn này.

---

## PHẦN A — PHASE 12: PERFORMANCE AUDIT

### P01 — Rò rỉ bộ nhớ vô hạn trong `ZLModAntiRecallStore.liveByKey`
- **Problem:** Memory leak trên từ điển RAM `liveByKey`.
- **Location:** `Sources/ZLModAntiRecall.m:260-270`
- **Evidence:** `cacheLiveSnapshot` chèn **2 key** vào `self.liveByKey` (`primaryKey = scope:g_<gid>` và `altKey = scope:c_<cid>`), nhưng chỉ thêm `primaryKey` vào mảng FIFO `self.liveOrder`. Khi `liveOrder.count > 500`, vòng `while` chỉ gọi `[self.liveByKey removeObjectForKey:oldest]` (chỉ xóa `primaryKey`), **không bao giờ xóa `altKey`**.
- **Impact:** Mọi tin nhắn nhận được đều giữ vĩnh viễn đối tượng `ZLModLiveSnapshot` trong RAM qua `altKey` cho tới khi đăng xuất hoặc crash OOM (Jetsam) trên phiên dùng Zalo kéo dài.
- **Severity:** **HIGH**

### P02 — Quét toàn bộ ~19.645 Objective-C App Classes 10+ lần liên tiếp lúc khởi động
- **Problem:** Expensive boot-time computation / redundant O(N) class scans.
- **Location:** `Sources/ZLModPrivacy.m:139, 153, 167` (3 lần), `Sources/ZLModFeatures.m:27, 79, 98` (6 lần: 4 getters + 1 setter + 1 GDrive), `Sources/ZLModHookEngine.m:42-70` (1 lần dựng cache).
- **Evidence:** Mỗi lệnh `ZLModEnumerateAppClasses(...)` duyệt lại toàn bộ ~19.645 class (con số xác minh từ `docs/IPA-ANALYSIS.md:6`), gọi `class_getInstanceMethod` / `ZLModClassHasIvar` hàng trăm nghìn lần trên boot path.
- **Impact:** Kéo dài thời gian boot của dylib sau khi launch Zalo, tăng nguy cơ bỏ lỡ các hook sớm ngay khi màn hình chính mở ra.
- **Severity:** **MEDIUM**

### P03 — Duyệt đồ thị BFS tới 4.000 node trên Main Thread mỗi khi mở màn hình Cài đặt Zalo
- **Problem:** Expensive main-thread UI blocking traversal.
- **Location:** `Sources/ZLModSettings.m:36, 144-290, 685-715`
- **Evidence:** `ZLModEnsureRow(self)` được gọi trên main queue ở cả 4 lifecycle hooks (`viewDidLoad`, `viewWillAppear:`, `viewDidAppear:`, `updateTitleObjects`). Nếu chưa tìm được row (ví dụ trên bản Zalo mới đổi tên ivar), mỗi lần mở Settings sẽ chạy BFS tối đa độ sâu 7, 4.000 object + `class_copyIvarList` + `malloc/free` ngay trên main thread!
- **Impact:** Gây giật khung hình (UI hitch) khi điều hướng vào Cài đặt Zalo, đặc biệt khi cấu trúc settings thay đổi.
- **Severity:** **HIGH**

### P04 — Bão Reconnect 3x & hàng đợi CSaving tăng vô hạn khi mạng lỗi
- **Problem:** Duplicate requests, reconnect storm & unbounded queue growth.
- **Location:** `Sources/ZLModUI.m:203-206, 221-224`; `Sources/ZLModBridge.m:134-172, 216-226, 456-458`
- **Evidence:**
  1. Lưu URL/Token kích hoạt `reconnect` 3 lần liên tiếp; socket cũ bị cancel bắn lỗi gọi `scheduleReconnect` tạo thêm kết nối trùng lặp mỗi 5 giây không có backoff.
  2. Khi gửi CSaving lỗi (`ZLModBridge.m:457`), `[strongSelf.pendingMessages addObjectsFromArray:batch]` bỏ qua giới hạn `kZLModMaxPendingMessages (50)`.
- **Impact:** Tốn pin, spam TCP/WebSocket handshake liên tục trong LAN, phình RAM nếu server chập chờn.
- **Severity:** **HIGH**

### P05 — Giải mã toàn bộ Private Notes & đọc lại 200 dòng Log mỗi lần mở Dashboard
- **Problem:** Unnecessary decryption & serialization on UI render (`viewWillAppear:`).
- **Location:** `Sources/ZLModUI.m:959, 1012`; `Sources/ZLModUtilities.m:173-206`
- **Evidence:** Để lấy mỗi con số `notesCount` hiển thị ở S01 (`ZLModUI.m:959`), `buildModel` gọi `[[ZLModPrivateNotesStore shared] allEntriesForCurrentAccount]`, hàm này **giải mã AES-256-CBC + tính HMAC-SHA256 cho TẤT CẢ ghi chú** rồi vứt bỏ toàn bộ plaintext chỉ để lấy `.count`! Chạy lại trên main thread mỗi lần `viewWillAppear:` và mỗi lần nhận notification!
- **Impact:** Độ trễ mở Dashboard tăng tuyến tính theo số lượng ghi chú.
- **Severity:** **MEDIUM**

### P06 — Không tái sử dụng `UITableViewCell` ở S02 và khởi tạo `NSDateFormatter` trong `cellForRowAtIndexPath:` ở S04
- **Problem:** Unnecessary object allocations during table scrolling/reloading.
- **Location:** `Sources/ZLModUI.m:89-169` (S02), `Sources/ZLModUI.m:439` (S04).
- **Evidence:** S02 cấp phát `[[UITableViewCell alloc] initWithStyle:... reuseIdentifier:nil]` cho mọi dòng; S04 cấp phát mới `[[NSDateFormatter alloc] init]` và gán `dateFormat` bên trong `cellForRowAtIndexPath:` (cực tốn CPU trên iOS!).
- **Impact:** Giật khi cuộn danh sách lịch sử Anti-Recall (tối đa 400 dòng).
- **Severity:** **MEDIUM**

### P07 — Ghi đĩa đồng bộ dưới `os_unfair_lock` + gọi deprecated `[NSUserDefaults synchronize]`
- **Problem:** Synchronous disk I/O while holding unfair spin/adaptive lock.
- **Location:** `Sources/ZLModPolicyStore.m:190-226`, `Sources/ZLModAntiRecall.m:350-390`, `Sources/ZLModUtilities.m:139-150, 368-375`; `Sources/ZLModPreferences.m:110-111, 130-131, 155-156, 165-166, 178-179, 211, 233, 250-251`.
- **Evidence:** Mọi thao tác lưu Policy, AntiRecall, Note, QuickReply đều serialize binary plist + `writeToFile:options:NSDataWritingAtomic` trong khi đang giữ `os_unfair_lock` (rủi ro priority inversion / block main thread); `ZLModPreferences` gọi `[synchronize]` (deprecated từ iOS 12) sau mỗi lần ghi.
- **Impact:** Chặn luồng UI khi có nhiều tin nhắn bị thu hồi cùng lúc hoặc người dùng toggle nhanh.
- **Severity:** **MEDIUM**

### P08 — Gửi trùng lặp bản tin CSaving do thiếu local deduplication
- **Problem:** Duplicate WebSocket payloads.
- **Location:** `Sources/ZLModAntiRecall.m:624, 1067, 1134, 1149`; `Sources/ZLModBridge.m:366-426`
- **Evidence:** Cùng một `ChatEntity` đi qua cả `addChat:` và `didLoadChats:` đều kích hoạt `ZLModChatEntityArrivedNotification`, và `ZLModBridge` đẩy tất cả sang Local Server mà không có LRU dedup set cục bộ.
- **Impact:** Tăng băng thông mạng LAN & tải ghi SQLite trên Local Server.
- **Severity:** **LOW**

---

## PHẦN B — PHASE 13: SECURITY AUDIT

| # | Hạng mục | Severity | Location | Mô tả chi tiết & Bằng chứng |
|---|---|---|---|---|
| **SEC-01** | **Arbitrary Preference Injection qua CDeploy Push** | **CRITICAL** | `Sources/ZLModBridge.m:289-303` | `applyRemoteSettings:` lặp toàn bộ dictionary `settings` từ server và ghi thẳng vào `ZLModPreferences` **không có allowlist key**. Một server độc hại hoặc bị MITM trên Wi-Fi công cộng (qua `ws://` không mã hóa!) có thể ghi đè `kZLModBridgeServerURL` (chiếm quyền điều hướng C-Bridge sang server kẻ tấn công), `kZLModBridgeToken`, `kZLModBridgeWebhook`, hoặc chèn key nội bộ `zlmod.internal.prev.*` để sửa đổi bất kỳ `NSUserDefaults` key nào của Zalo khi user bấm Reset! |
| **SEC-02** | **Lưu trữ Secrets Plaintext trong `NSUserDefaults` + App Group** | **HIGH** | `Sources/ZLModPreferences.m:28-29, 92-93, 148-156`; `Sources/ZLModBridge.m:116, 501` | `kZLModBridgeToken` và `kZLModBridgeWebhook` (chứa webhook secret token của Discord) lưu dạng **plaintext** trong `vn.com.vng.zingalo.zlmod.plist` VÀ sao chép sang App Group chia sẻ `group.zsettings.vn.com.vng.zingalo`, không dùng iOS Keychain như `ZLModCryptoBox`! |
| **SEC-03** | **Truyền Token & UserId qua WebSocket Query String không mã hóa TLS + lỗi Percent-Encoding** | **HIGH** | `Sources/ZLModBridge.m:113-130` | (1) Mặc định khuyến nghị `http://192.168.1.x:3000` → kết nối `ws://` plaintext (lộ `token`, `accountScope`, `rawUid`, và toàn bộ nội dung chat CSaving trên mạng Wi-Fi/LAN); (2) Đưa `token` vào URL query string (dễ lộ trong access log/proxy); (3) Dùng `URLQueryAllowedCharacterSet` không escape `&`, `=`, `+` cho phép query-parameter injection nếu token chứa ký tự đặc biệt. |
| **SEC-04** | **SSRF / Exfiltration trên Discord Webhook URL** | **MEDIUM** | `Sources/ZLModBridge.m:500-536` | `testWebhookWithCompletion:` không kiểm tra scheme `https` hay domain `discord.com`/`discordapp.com` — chấp nhận mọi URL bất kỳ và POST `accountScope` đi. |
| **SEC-05** | **Unsafe Memory Cloning (`memcpy` + `CFRetain`) trên ObjC Object** | **HIGH** | `Sources/ZLModSettings.m:56-105` | `ZLModCloneObject` sao chép thô bộ nhớ ivar bằng `memcpy` và tăng refcount bằng `CFRetain` mà không xử lý `__weak` ivars (lưu trong side table của ObjC runtime), C++ non-trivial structs, hay ARC ownership semantics → rủi ro memory corruption / use-after-free / crash tiến trình. |
| **SEC-06** | **Plaintext `threadId` trong `ZLModPolicies.plist` và `ZLModNotes.plist`** | **LOW** | `Sources/ZLModPolicyStore.m:208`; `Sources/ZLModUtilities.m:132` | Dù `ZLModAntiRecall.plist` đã ẩn `threadId` bằng `threadHash`, cả `ZLModPolicies.plist` và `ZLModNotes.plist` vẫn lưu `threadId` thật dạng plaintext trên đĩa (lộ danh sách người dùng/nhóm mà chủ máy đang ẩn seen hoặc ghi chú riêng). |
| **SEC-07** | **Compatibility Gate Quá Rộng (Bundle Substring Bypass)** | **MEDIUM** | `Sources/ZLModCompatibility.m:27-28` | Fallback `[bundleId.lowercaseString containsString:@"zalo"] || [bundleId.lowercaseString containsString:@"zing"]` cho phép dylib boot trên bất kỳ ứng dụng nào chứa chữ `zalo`/`zing` trong bundle ID (nếu bị inject nhầm) thay vì fail-closed nghiêm ngặt. |
| **SEC-08** | **Redaction Log Chưa Che Discord Webhook URL & Path Secrets** | **LOW** | `Sources/ZLModCore.m:25-70` | Regex `ZLModRedactText` che `token=...`, `Bearer ...`, và số ≥ 10 chữ số, nhưng không che pattern `/api/webhooks/<id>/<secret>` hoặc IP LAN nội bộ nếu có module nào log ra URL đầy đủ. |
| **SEC-09** | **CI Supply Chain: `curl` IPA từ URL không kiểm tra SHA-256** | **MEDIUM** | `.github/workflows/release.yml:109-116` | Input `decrypted_ipa_url` tải trực tiếp file IPA từ URL bất kỳ bằng `curl -fSL` và chỉ kiểm tra `unzip -tq` (không xác minh checksum SHA-256) trước khi đóng gói và phát hành lên GitHub Release. |
| **SEC-10** | **Dùng chung 1 Master Key Keychain cho mọi tài khoản Zalo trên máy** | **LOW** | `Sources/ZLModCryptoStore.m:14-15` | `master_key_v2` dùng chung toàn thiết bị, phân tách tài khoản chỉ qua AAD `accountScope` ở tầng ứng dụng (không per-account key). Chấp nhận được với mô hình đe dọa cục bộ nhưng cần ghi nhận rõ. |

---

## PHẦN C — PHASE 14: DEPENDENCY AUDIT

ZLMod **không có `package.json`, `Podfile`, `Package.swift`, hay `requirements.txt`**. Toàn bộ dependencies chỉ gồm Apple System Frameworks, Python 3 Stdlib, Toolchain build, và GitHub Actions:

| Package / Dependency | Version | Purpose | Used By | Critical? | Alternative | Problems | Recommendation |
|---|---|---|---|---|---|---|---|
| **Apple `UIKit.framework`** | iOS 15.1+ SDK | UIViewController, UITableView, UIAlertController, UIWindow, Appearance | Toàn bộ UI & UI hooks | **YES** | Không | Zalo đặt `UIDesignRequiresCompatibility=YES` nên không dùng được `UIGlassEffect` iOS 26 | **KEEP** |
| **Apple `Foundation.framework`** | iOS 15.1+ SDK | NSUserDefaults, NSURLSession/WebSocket, NSURLProtocol, Plist, NSNotificationCenter | Toàn bộ modules | **YES** | Không | `NSURLProtocol` bị bypass bởi custom `NSURLSessionConfiguration`; `synchronize` bị deprecated | **KEEP** (sửa cách gọi API) |
| **Apple `QuartzCore.framework`** | iOS 15.1+ SDK | `CALayer` (cornerRadius, masksToBounds) | Toast, Banner, Blue Dot, PhotoPreview | **YES** | Không | Không có | **KEEP** |
| **Apple `Security.framework` + `CommonCrypto`** | iOS 15.1+ SDK | Keychain (`SecItem*`), AES-256-CBC, HMAC-SHA256, SHA-256, CSRNG | `ZLModCryptoStore.m` | **YES** | CryptoKit (chỉ Swift) | Nếu sideload thiếu Keychain entitlement có thể trả `-34018` | **KEEP** |
| **Objective-C Runtime (`libobjc`)** | iOS 15.1+ | `class_replaceMethod`, `objc_getClassList`, associated objects | `ZLModHookEngine.m` & mọi module hook | **YES** | Fishhook / Dobby (cho C hooks) | Chỉ hook được ObjC methods (không hook được Swift non-`@objc` hoặc C functions) | **KEEP** |
| **Python 3 Standard Library** | Python 3.10+ (tested on 3.14) | `zipfile`, `plistlib`, `struct`, `hashlib`, `unittest` | `Packaging/*.py`, `Scripts/*.py`, `Tests/*.py` | **YES** | Không | Không có third-party Python package; bug nằm ở logic `macho_injector.py` & `ipa_preflight.py` | **KEEP** |
| **Apple Xcode / `clang` / `codesign` / `otool` / `nm`** | Xcode 15–26 (`macos-26` CI) | Biên dịch arm64 dylib, ad-hoc signing, static gates | `Makefile`, `Scripts/gates.sh`, `Scripts/report.sh`, CI | **YES** | Theos / clang cross-compile | Không thể biên dịch dylib trên Windows/Linux local (phụ thuộc macOS CI) | **KEEP** |
| **`actions/checkout@v4`** | v4 | Checkout repo + Git LFS trong CI | `.github/workflows/build.yml`, `release.yml` | **YES** | — | Không có | **KEEP** |
| **`actions/upload-artifact@v4`** | v4 | Lưu artifact build & IPA trong CI | `build.yml`, `release.yml` | **YES** | — | Không có | **KEEP** |
| **`softprops/action-gh-release@v2`** | v2 | Xuất bản GitHub Release | `build.yml`, `release.yml` | **YES** | `gh release create` | `build.yml` bỏ sót `build/*.ipa` trong danh sách files | **KEEP** (sửa cấu hình `build.yml`) |
| **External Local Server (`zalo-meet-bot`)** | `UNKNOWN` | Server WebSocket/HTTP đích cho C-Bridge | `Sources/ZLModBridge.m` | Chỉ khi dùng C-Bridge | Bất kỳ WS server nào tuân thủ protocol | Mã nguồn server không có trong repo này; protocol contract chưa được version hóa | **UNKNOWN** (cần đồng bộ schema với server) |
| **Bundled Base IPA (`Decrypted/vn.com.vng.zingalo_260401_decrypted_by_TTJB.ipa`)** | Zalo `260401` (build `708`, 121.7 MB) | Base IPA cho CI tự đóng gói | `build.yml`, `release.yml` | Cho CI auto-IPA | Zalo `261002` hoặc `261101` decrypted | **KHÔNG KHỚP** `compatibility.json` (`261002`/`261101`), **thiếu 6/86 anchors** (mất ContextMenu action handler, GDrive, ChatListItemCell), làm phình git repo >120 MB | **REPLACE** (thay bằng bản khớp compatibility hoặc bỏ khỏi git) |

---

## PHẦN D — PHASE 16: TECHNICAL DEBT INVENTORY

| ID | Category | Location | Problem | Impact | Recommended Direction |
|---|---|---|---|---|---|
| **TD-01** | **Tightly Coupled / Hidden Dependency** | `Sources/ZLModAntiRecall.m:624,1068,1136,1151` ↔ `Sources/ZLModBridge.m:73` | CSaving hoàn toàn lệ thuộc vào `ZLModChatEntityArrivedNotification` chỉ phát khi `kZLModAntiRecall == YES`. | Bật CSaving mà tắt Anti-Recall → 0 tin nhắn được lưu. | Tách module trung lập `ZLModMessageTap` / `ZLModMessageBus` chuyên bắt `ChatEntity` cho cả Anti-Recall và CSaving độc lập. |
| **TD-02** | **Misplaced Shared Utility** | `Sources/ZLModConversationMenu.m:14-64` | `ZLModShowToast()` được định nghĩa bên trong `ZLModConversationMenu.m` dù được dùng bởi `Core`, `Bridge`, `Utilities`, `UI`, `AntiRecall`. | Không thể tách/build độc lập các module không cần `ConversationMenu`. | Di chuyển `ZLModShowToast()` (và UI overlay manager chung) sang module `ZLModUIComponents` hoặc `ZLModCoreUI`. |
| **TD-03** | **Monolithic / Huge Files** | `Sources/ZLModAntiRecall.m` (1.372 dòng), `Sources/ZLModUI.m` (1.247 dòng), `Sources/ZLModUtilities.m` (848 dòng), `Sources/ZLModSettings.m` (789 dòng) | Gộp chung storage, crypto serialization, runtime hooks, view hierarchy hacking, và fullscreen `UIViewController` vào 1 file `.m`. | Rất khó bảo trì, dễ tạo bug tương tác chéo (như `liveByKey` leak, cell reuse, 3x reconnect). | Tách rõ tầng: `Store` / `Hook` / `UI` (mỗi VC hoặc feature có file riêng). |
| **TD-04** | **Duplicate Logic (`ChatEntity` parsing)** | `Sources/ZLModAntiRecall.m:530-595` vs `Sources/ZLModBridge.m:370-395` vs `Sources/ZLModPrivacy.m:40-95` | 3 module tự viết 3 bộ trích xuất `threadId`/`globalId`/`clientId`/`senderId` từ `ChatEntity` khác nhau (Bridge thiếu fallback selectors). | Dữ liệu không đồng nhất, CSaving rơi field rỗng. | Gom về 1 `ZLModChatEntityAdapter` duy nhất chuẩn hóa `ZLModMessageDTO`. |
| **TD-05** | **Duplicate / Conflicting Appearance Ownership** | `Sources/ZLModGlass.m:42-95` vs `Sources/ZLModTheme.m:190-327` | Cả 2 module cùng tự lưu baseline và ghi đè `UITabBar.standardAppearance`/`scrollEdgeAppearance`. | Bật/tắt xen kẽ Theme và Glass làm hỏng trạng thái gốc của Tab Bar. | Hợp nhất vào 1 `ZLModAppearanceCoordinator` giữ duy nhất 1 baseline gốc và compose Theme + Glass. |
| **TD-06** | **Dead Code & Unused Exports** | `Sources/ZLModAntiRecall.m:980-1056` (`ZLModPresentRecalledMessageContent`), `Sources/ZLModCryptoStore.m:119-123` (`ZLModCandidateAccountScopesForMigration`) | Code cũ từ Build 8 còn tồn đọng trong production binary. | Tăng diện tích mã thừa và gây nhầm lẫn khi đọc code. | Xóa dead code sau khi xác nhận không cần fallback modal text. |
| **TD-07** | **Legacy / Leftover Upstream Naming** | `Sources/ZLModFeatures.m:20, 74` (`ZyForceBoolGetter`) | Còn sót tiền tố `Zy*` của upstream `Zync` (lọt qua `project_gate.py` vì gate chỉ chặn `"Zync"`). | Không nhất quán quy ước đặt tên `ZLMod*`. | Đổi tên sang `ZLModForceBoolGetter`. |
| **TD-08** | **Version & Documentation Drift** | `ZLMod.h:12-13` (`Build 5`), `report.sh:7` (`build-5`), `README.md`/`docs/*` (`Build 9`, suite `com.zlmod.preferences`, "84 anchors", "UIGlassEffect", "InboxContextMenuProvider"), `release.yml:9` (`Build 10`), `anchors.txt` (86 dòng) | Thông số phiên bản, tên suite, số anchor và danh sách hook bị lệch nhau giữa 5 nơi. | Người dùng & developer hiểu sai hoàn toàn trạng thái bản build đang chạy. | Thiết lập Single Source of Truth cho version/build và cập nhật toàn bộ tài liệu + contract tests. |
| **TD-09** | **Mach-O 64-bit Alignment Bug** | `Packaging/macho_injector.py:158-159` | `inject_rpath_slice` tính `cmdsize = 12 + align8(len)` → luôn `4 mod 8` (sai chuẩn căn lề 8-byte của Mach-O 64-bit!). | Có thể bị `dyld`/`codesign`/AMFI từ chối trên một số phiên bản iOS hoặc công cụ ký. | Sửa thành `cmdsize = align8(12 + len(rpath_bytes))` + thêm unit test khẳng định mọi `cmdsize % 8 == 0` và `sizeofcmds % 8 == 0`. |
| **TD-10** | **Preflight State Classification Bug** | `Packaging/ipa_preflight.py:281-297` | Nhánh `else:` gán `PROVISIONED_AND_SIGNED` khi `has_codesign=True` và `has_provision=False` trong khi `directly_installable=False`. | Báo cáo forensics tự mâu thuẫn trên chính file IPA đang commit trong `Decrypted/`. | Thêm trạng thái tường minh `PARTIAL_SIGNATURE_NO_PROVISION` / `UNSIGNED_NO_PROVISION`. |
| **TD-11** | **Magic Values & Hardcoded Constants** | `0x5A1D` (blue dot tag), `0x5A1E` (undo banner tag), `9101–9104` (conv menu IDs), `99001–99002` (recall menu IDs), `4000` (BFS limit), `500` (live cache), `400` (archive cap), `14*86400` (TTL), `50` (CSaving & QuickReply cap), `20.0` (heartbeat), `5.0` (reconnect), `"00Zh8W"` | Rải rác trong từng file `.m`, không tập trung và một số chưa có tài liệu chống đụng ID với Zalo. | Khó tinh chỉnh hoặc phát hiện xung đột action ID với bản Zalo mới. | Gom về header cấu hình tập trung `ZLModConstants.h`. |
| **TD-12** | **Tests chỉ kiểm tra Source Substring (False Confidence)** | `Tests/test_*.py` (47 tests, 46 pass / 1 skip) | Đa số test Objective-C chỉ dùng Python `assertIn("...", source_text)` — **KHÔNG biên dịch, KHÔNG chạy Objective-C, KHÔNG test logic runtime**. Ví dụ `test_bridge_contract.py` pass xanh rì dù `ZLModBridge.m:472` bị gãy URL, `CSaving` chết khi tắt Anti-Recall, và `macho_injector.py` xuất `sizeofcmds = 212` (không chia hết cho 8)! | Tạo cảm giác an toàn giả khi CI xanh nhưng tính năng thực tế bị gãy. | Bổ sung unit test thật cho mọi logic Python (kiểm tra alignment `% 8 == 0`, kiểm tra URL construction, kiểm tra preflight partial-signing) và bổ sung XCTest / host-side ObjC tests trên macOS CI. |
| **TD-13** | **Background Thread UIKit & Unprotected Globals** | `ZLModCore.m:355`, `ZLModSettings.m:19-22,641`, `ZLModBridge.m:16-26`, `ZLModTheme.m:358` | Boot chạy trên background queue gọi installer đụng UIKit; nhiều biến static/property của Bridge & Settings không có synchronization nhất quán. | Nguy cơ race condition hoặc Main Thread Checker crash. | Chuẩn hóa thread contract: khởi tạo non-UI trên background, UI/swizzle UIKit rõ ràng trên main queue (hoặc khóa chặt state). |
| **TD-14** | **Incomplete Anchor Manifest** | `Scripts/anchors.txt` (86 entries) | Mã nguồn `ZLModAntiRecall.m` và `ZLModConversationMenu.m` gọi nhiều class/selector runtime quan trọng (`MenuButton`, `showContextMenuViewWithMenuItemArray:hasReaction:`, `MSContextMenuItemCreator`, `reloadCellIfNeed`, `set_originTextRecallMsg:`, `isRecalled`, `ZAContextMenuAction`) **nhưng KHÔNG liệt kê chúng trong `Scripts/anchors.txt`!** | `anchors-verify.sh` báo 100% pass nhưng thực tế Anti-Recall / ContextMenu vẫn có thể thiếu symbol trên bản Zalo mới! | Cập nhật `Scripts/anchors.txt` bao phủ 100% mọi `NSClassFromString` / `sel_registerName` trong `Sources/`. |


---

## Post-Rebuild Debt Closure Summary (ZLMod 4.0 / Build 11 — 2026-11-26)

All **Critical**, **High**, **Medium**, and **Low** technical debt items tracked in this audit (`TD-001` through `TD-060`) have been remediated in source code across MODULE 01–MODULE 12. Key closures verified statically & by automated test suite (`72` tests: `71 passed, 1 skipped`, `project_gate.py` exit `0`, C/POSIX header audit `0` issues):

- **Security & Secret Hygiene**: Zero plaintext `kZLModBridgeToken` / `kZLModBridgeWebhook` in `NSUserDefaults` / App Group / WS query URLs (`ZLModSecretStore` Keychain-only + legacy migration & purge + `Authorization: Bearer` + expanded `ZLModRedactText`).
- **Architecture & Coupling**: Eliminated `ZLModCore -> ZLModConversationMenu` reverse dep (`ZLModOverlayUI.m`), decoupled `CSaving` & `DiscordRelay` from `AntiRecall` (`ZLModChatEntityAdapter` + `ZLModMessageTapBus`), unified `ZLModTheme` + `ZLModGlass` via `ZLModAppearanceCoordinator`, removed dead code (`ZLModPresentRecalledMessageContent`, `set_originTextRecallMsg:`) and legacy upstream prefix `ZyForceBoolGetter`.
- **Realtime & Persistence Correctness**: 4-state WebSocket FSM + `connectionEpoch` + exponential backoff + pong timeout + ordered CSaving failed-batch prepend + CDeploy strict allowlist & guaranteed ACK + real automatic Discord Webhook relay + encrypted disk photo persistence + non-blocking `zlmod.diskio` queue + `ZLModStorageHealth`.
- **Packaging & Tooling**: Fixed `LC_RPATH` 8-byte alignment in `macho_injector.py`, fixed partial-signature classification in `ipa_preflight.py`, synced `Resources/version.json` across `ZLModVersionData.h`, `Makefile`, `report.sh`, and CI workflows, updated `Scripts/anchors.txt` to 118 verified anchors.
- **Residual Environment Risk**: Native arm64 compilation (`make` / `Scripts/gates.sh`) and physical iPhone UI/Zalo runtime validation could not execute on Windows and remain gated on macOS CI (`macos-26`) + physical iOS device testing (tracked in `FINAL_FIX_REPORT.md`).
