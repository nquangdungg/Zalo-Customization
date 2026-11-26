# FINAL FIX REPORT — ZLMod 4.0 (Build 11 — Modular Architecture Rebuild)

**Repository:** `D:\Documents\GitHub\Zalo-Customization`  
**Target:** `libZLMod.dylib` (iOS 15.1+, `arm64`, Zalo `261002/261002802` & `261101/261101802` + verified 3-class runtime anchor quorum)  
**Version Source of Truth:** `Resources/version.json` → `4.0`, `Build 11` (`build-11`)  
**Completion Date:** 2026-11-26  
**Execution Environment:** Windows (`Python 3.14.6`, no `clang` / `xcodebuild` / `iphoneos` SDK / physical iPhone attached)

---

## 1. Tổng quan tiến độ tái kiến trúc (MODULE 01 → MODULE 12)

Toàn bộ 12 module theo `docs/audit/REBUILD_PLAN.md` đã được triển khai tuần tự, giữ sạch đồ thị phụ thuộc (không dependency ngược, không vòng lặp, không giữ trạng thái `BROKEN` / `PARTIAL` / `UNUSED` theo đặc tả):

| Module | Phạm vi chính | Tệp triển khai | Trạng thái |
|---|---|---|---|
| **MODULE 01** | Version SoT, Constants, Compatibility hợp nhất, Two-Phase Boot & Log Redaction | `Resources/version.json`, `Scripts/generate_version.py`, `Sources/ZLModVersionData.h`, `Sources/ZLModConstants.h`, `Sources/ZLMod.h`, `Sources/ZLModCompatibility.m`, `Sources/ZLModCore.m` | ✅ Hoàn tất (code + static/contract tests) |
| **MODULE 02** | Single-pass Selector Index, Main-thread UIKit helpers & `ZLModChatEntityAdapter` | `Sources/ZLModHookEngine.m`, `Sources/ZLModChatEntityAdapter.m` | ✅ Hoàn tất (code + static/contract tests) |
| **MODULE 03** | `ZLModSecretStore` (Keychain-only), `ZLModStorageHealth`, Async Disk Queue & Batch/Allowlist Preferences | `Sources/ZLModCryptoStore.m`, `Sources/ZLModPreferences.m` | ✅ Hoàn tất (code + static/contract tests) |
| **MODULE 04** | Shared Overlay UI (`ZLModOverlayUI`) & Safe Settings Entry (per-VC state, zero `memcpy`/`CFRetain`) | `Sources/ZLModOverlayUI.m`, `Sources/ZLModSettings.m` | ✅ Hoàn tất (code + static/contract tests) |
| **MODULE 05** | LIFO `ZLModPrivacyContext`, Policy Store v3 (tên hội thoại mã hóa) & Conversation Menu deduped | `Sources/ZLModPolicyStore.m`, `Sources/ZLModConversationMenu.m` | ✅ Hoàn tất (code + static/contract tests) |
| **MODULE 06** | Privacy (Firebase khôi phục live), URIFilter (`NSURLSessionConfiguration` + miễn trừ Bridge/Discord/WS) & Reversible Ads | `Sources/ZLModPrivacy.m`, `Sources/ZLModURIFilter.m`, `Sources/ZLModAds.m` | ✅ Hoàn tất (code + static/contract tests) |
| **MODULE 07** | Decoupled `ZLModMessageTapBus` & Anti-Recall (ảnh mã hóa trên đĩa, không leak `altKey`, dọn cell reuse) | `Sources/ZLModMessageTap.m`, `Sources/ZLModAntiRecall.m` | ✅ Hoàn tất (code + static/contract tests) |
| **MODULE 08** | Multi-line Private Notes v3, Account-scoped Quick Replies + nút chọn nhanh trong chat, Multi-item Delay Send FSM | `Sources/ZLModUtilities.m` | ✅ Hoàn tất (code + static/contract tests) |
| **MODULE 09** | Unified `ZLModAppearanceCoordinator` (Theme + Blur Tab Bar chung 1 baseline) & Single-pass `ZLModFeatures` | `Sources/ZLModTheme.m`, `Sources/ZLModGlass.m`, `Sources/ZLModFeatures.m` | ✅ Hoàn tất (code + static/contract tests) |
| **MODULE 10** | C-Bridge 4-state WebSocket FSM, `connectionEpoch`, Backoff, Pong Timeout, Bonjour LAN, Ordered CSaving, Allowlisted CDeploy & Automatic Discord Relay | `Sources/ZLModBridge.h`, `Sources/ZLModBridge.m` | ✅ Hoàn tất (code + static/logic/contract tests) |
| **MODULE 11** | Settings Dashboard `S01` & 7 màn hình quản lý/chẩn đoán `S02`–`S08` (Storage Health Banner, Spinner, Pull-to-refresh) | `Sources/ZLModUI.m` | ✅ Hoàn tất (code + static/contract tests) |
| **MODULE 12** | Mach-O 8-byte alignment, 5-state IPA Preflight, 118 verified Anchors, Makefile, CI Workflows & 72-test Suite | `Packaging/*`, `Makefile`, `Scripts/*`, `.github/workflows/*`, `Tests/*` | ✅ Hoàn tất (Python & real IPA verified) |

---

## 2. Danh sách các lỗi & Technical Debt đã khắc phục

### Bảo mật & Rò rỉ bí mật (Critical / High)
1. **Plaintext Bridge Token & Discord Webhook trong `NSUserDefaults` / App Group** → Định tuyến hoàn toàn qua `ZLModSecretStore` (`iOS Keychain`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) kèm di chuyển một lần (`migrateLegacySecretsToKeychainIfNeeded`) và xóa sạch mọi bản sao plaintext cũ khỏi `own`/`group`/`standard`.
2. **Bridge Token rò rỉ trong WebSocket query URL (`?token=...`)** → Loại bỏ hoàn toàn khỏi query string; gửi token qua HTTP header `Authorization: Bearer <token>` trên `NSMutableURLRequest` và RFC 3986 percent-encode cho `account`/`userId`.
3. **Discord Webhook URL không được che giấu trong `ZLModRedactText`** → Bổ sung `discordWebhookRegex`, `genericWebhookRegex`, `bearerRegex`, và mở rộng `querySecretRegex`.
4. **CDeploy ghi tùy ý mọi key vào `NSUserDefaults`** → Bắt buộc đi qua `[[ZLModPreferences shared] applyRemoteSettingsBatch:settings allowedKeys:[ZLModPreferences remoteDeployAllowedKeys]]` (cấm tuyệt đối `serverUrl`, `token`, `webhook`, `lastSync`, `zlmod.internal.*`).
5. **Discord Webhook chấp nhận mọi URL bất kỳ (SSRF risk)** → Kiểm tra nghiêm ngặt `+[ZLModBridgeManager isValidDiscordWebhookURLString:]` (chỉ `https://`, host trong `{discord.com, discordapp.com, ptb.discord.com, canary.discord.com}`, path `/api/.../webhooks/<id>/<token>`).
6. **Compatibility bypass lỏng theo chuỗi `"zalo"`/`"zing"`** → Xóa hoàn toàn; thay bằng một bộ đánh giá duy nhất `ZLModEvaluateHostCompatibility` yêu cầu exact target hoặc hội đủ 3 runtime anchor cốt lõi (`ZaloTabBarViewController`, `ChatDataManager`, `SettingUI40TableViewController`/`BasicSettingTableViewController`).

### Kiến trúc, Coupling & Crash Safety (Critical / High)
7. **`CSaving` phụ thuộc ngầm vào `kZLModAntiRecall`** → Tách hoàn toàn qua `ZLModChatEntityAdapter` → `ZLModMessageTapBus`; hoạt động độc lập ngay khi bất kỳ tính năng nào trong `{AntiRecall, CSaving, DiscordRelay}` bật.
8. **Phụ thuộc ngược `ZLModCore -> ZLModConversationMenu` (cho `ZLModShowToast`)** → Tách `ZLModOverlayUI.m` làm tầng UI dùng chung độc lập.
9. **Clone object bằng `memcpy` / `CFRetain` dễ hỏng bộ nhớ ARC trong `ZLModSettings.m`** → Thay bằng sao chép thuộc tính an toàn + `ZLModSettingsVCState` theo từng VC + nút dự phòng trên `navigationItem.rightBarButtonItems` (không làm lệch chỉ số `indexPath.row`).
10. **Lỗi `LC_RPATH` không căn chỉnh 8-byte trong `Packaging/macho_injector.py`** → Sửa `cmdsize = align8(12 + len(rpath_bytes))` + thêm `verify_macho_alignment()` kiểm tra mọi load command `cmdsize % 8 == 0` và `sizeofcmds % 8 == 0` sau tiêm và trong `Packaging/package_ipa.py`.
11. **Lỗi `ipa_preflight.py` báo sai `PROVISIONED_AND_SIGNED` khi thiếu `embedded.mobileprovision`** → Bổ sung đủ 5 trạng thái (`UNSIGNED_ARCHIVE`, `PARTIAL_SIGNATURE_MISSING_PROVISION`, `PARTIAL_PROVISION_MISSING_CODESIGN`, `STALE_SIGNATURE_MISMATCH`, `PROVISIONED_AND_SIGNED`) — đã xác minh trực tiếp trên `Decrypted/vn.com.vng.zingalo_260401_decrypted_by_TTJB.ipa`.
12. **CPairing health check hỏng URL do `stringByAppendingPathComponent:@"/api/cbridge/health"` (`http://` → `http:/`)** → Thay bằng `ZLModBuildBridgeEndpointURL` dùng `NSURLComponents`.

### Realtime, Dữ liệu & Trải nghiệm người dùng (High / Medium)
13. **WebSocket stale-task race, không có backoff, không phát hiện half-open socket, rò rỉ `NSURLSession` retain cycle** → FSM 4 trạng thái + `connectionEpoch` + backoff `2s..30s` + heartbeat `20s` / pong timeout `10s` + đóng sạch khi nền + `invalidateAndCancel` khi dừng.
14. **CSaving đảo ngược thứ tự tin nhắn khi gửi lại lô lỗi** → Chèn lô lỗi **trước** tin mới đến trong lúc chờ gửi (`failed_batch + newer_pending`), cắt phần cũ vượt quá 50.
15. **CDeploy im lặng bỏ qua nếu presenter đang bận / không cập nhật `lastSyncDateString` khi upload** → Xếp hàng thử lại 3 lần, luôn trả `cdeploy_ack` (kể cả `presenter_unavailable`), cập nhật `lastSyncDateString` cho cả push & upload.
16. **Anti-Recall: leak `liveByKey` (`altKey`), mất ảnh thu hồi sau khi khởi động lại, nhận diện nhầm chữ `"thu hồi"`, mutate `set_originTextRecallMsg:`, dead code, thiếu dọn `prepareForReuse`** → Đã sửa toàn bộ: eviction nguyên tử `primaryKey`+`altKey`, mã hóa & lưu ảnh ra đĩa (`ZLModRecallPhotos/*.enc`, quota 20 MB, TTL 14 ngày), khớp chính xác câu placeholder qua `ZLModChatEntityAdapter`, bỏ hoàn toàn `set_originTextRecallMsg:` & `ZLModPresentRecalledMessageContent`, dọn associated label khi `prepareForReuse`.
17. **Xung đột baseline giữa `ZLModTheme` và `ZLModGlass` + nhập sai `#HEX` âm thầm xóa cấu hình** → Hợp nhất vào `ZLModAppearanceCoordinator`; `applyCustomTintHex:` trả `BOOL` (`NO` khi sai định dạng) và `S01` hiện toast báo lỗi.
18. **`Hide Ads` và `Disable Firebase` không khôi phục được khi tắt công tắc; `ZLModURIFilter` bị `NSURLSession` vượt mặt** → Theo dõi ad views bằng `NSHashTable` yếu để hoàn nguyên live; khôi phục cờ Firebase khi tắt; hook `NSURLSessionConfiguration` (`default`/`ephemeral`) có miễn trừ C-Bridge/Discord/WebSocket.
19. **Lỗi ẩn như danh sách trống khi Keychain hỏng hoặc chưa xác định tài khoản** → Bổ sung `ZLModStorageHealth` + banner cảnh báo rõ ràng trên `S01`, `S03`, `S04`, `S06`.
20. **Ghi đĩa đồng bộ chặn main thread & `[NSUserDefaults synchronize]` lỗi thời** → Chuyển sang hàng đợi tuần tự `zlmod.diskio` (`ZLModWritePropertyListAsync`, `ZLModWriteDataAsync`, `ZLModFlushDiskIOQueueSync`) và bỏ toàn bộ `synchronize`.
21. **UI `S01`–`S08` phát trùng thông báo, gọi trùng `[mgr reconnect]`, thiếu cell reuse / spinner / xác nhận reset / pull-to-refresh** → Đã sửa toàn bộ trong `Sources/ZLModUI.m`; bỏ hoàn toàn `ZyForceBoolGetter` cũ; đồng bộ phiên bản duy nhất từ `Resources/version.json`.

---

## 3. Tính năng hoàn thiện từ `PARTIAL` / `BROKEN` sang hoàn chỉnh

- **Discord Webhook Relay tự động**: Đăng ký trực tiếp lên `ZLModMessageTapBus`, tự động gửi tin nhắn đến & tin bị thu hồi (kèm nội dung gốc khôi phục từ `ZLModAntiRecallStore`) tới Discord với kiểm tra tên miền chính thức, dedup 500 khóa, rate limit `1.5s`, xử lý HTTP `429 Retry-After` và retry tối đa 2 lần.
- **CPairing LAN Auto-Discovery (Bonjour/mDNS)**: Quét tự động `_zlmod-cbridge._tcp.` và `_http._tcp.` (lọc tên `zlmod`/`cbridge`/`zalo-meet`) qua `NSNetServiceBrowser`, phân giải địa chỉ IPv4/host:port và tích hợp trực tiếp vào `S02`.
- **Anti-Recall Photo Persistence & Zoomable Viewer**: Lưu ảnh thu hồi mã hóa AES-256-CBC+HMAC-SHA256 trên đĩa (tồn tại qua các lần khởi động lại app, quota 20 MB, TTL 14 ngày) và hỗ trợ phóng to pinch-to-zoom từ cả chat lẫn màn hình lịch sử `S04`.
- **Ghi chú riêng tư nhiều dòng & tên hội thoại thật**: Trình soạn thảo `UITextView` (`ZLModPrivateNoteEditorViewController`) + schema v3 lưu `titleCipher` mã hóa cho cả Notes (`S06`) và Conversation Policies (`S03`).
- **Quick Reply theo tài khoản & nút chèn nhanh trong chat**: Lưu v2 theo `accountScope` (di chuyển v1) + nút `⚡` trên thanh điều hướng `BaseChatTVC` mở `ZLModPresentQuickReplyPicker`.
- **Delay Send đa tin nhắn & tránh bàn phím**: Hàng đợi đa mục với bộ đếm ngược trực tiếp 0.25s, hỗ trợ `Hủy 1` / `Hủy hết`, tự điều chỉnh vị trí theo `UIKeyboardWillChangeFrameNotification`.

---

## 4. Kết quả kiểm thử đã chạy (Thực thi trực tiếp trên Windows)

| Lệnh / Bộ kiểm thử | Phạm vi bao phủ | Kết quả thực tế |
|---|---|---|
| `py -3.14 -m unittest discover -s Tests -p "test_*.py" -v` | **72 automated tests** bao phủ toàn bộ 25 nhóm yêu cầu (Compatibility, Version SoT, Secret Keychain, Storage Health, Preferences Batch, Account Switch, Normalization, Dedup, CSaving Ordering, Anti-Recall, Recalled Photo Disk, Delay Send FSM, Quick Replies, Private Notes, WebSocket FSM, Reconnect Race/Backoff, Pong Timeout, CDeploy Allowlist/ACK, Discord Relay, UI State Propagation, Anchors, Mach-O 8-Byte Alignment, 5-State Preflight, E2E Repackaging, ObjC Static Delimiters/Imports/Symbols/Redaction) | **71 PASSED, 0 FAILED, 1 SKIPPED** (`test_clone_tracks_upstream_repository` skip do không có remote `upstream` cục bộ; exit code `0`, `0.990s`) |
| `py -3.14 Scripts/project_gate.py .` | Kiểm tra sạch danh tính sản phẩm (không còn `Zync`, `ZYNC`, `zync`, `ZyForce`) | **PASSED (0 violations, exit code `0`)** |
| `py -3.14 Packaging/ipa_preflight.py Decrypted/vn.com.vng.zingalo_260401_decrypted_by_TTJB.ipa --require-unencrypted-main` | Kiểm tra tiền bay trên IPA thật (`121.7 MB`, 35 Mach-O binaries, `cryptid=0`) | **PASSED (exit code `0`)** — phát hiện chính xác `PARTIAL_SIGNATURE_MISSING_PROVISION` (`CodeResources=True, MobileProvision=False`) |
| Xác minh bảng anchor trực tiếp trên `Payload/Zalo.app/Zalo` (`169.8 MB`, `19,704` ObjC classes, `235,422` selectors) | Đối chiếu toàn bộ class/selector thêm mới vào `Scripts/anchors.txt` | **PASSED** — toàn bộ 34 anchor thêm mới đều tồn tại thật trong `__objc_classname` / `__objc_methname` |
| Static Objective-C Linker Symbol & C/POSIX Header Audit | Kiểm tra 39 hàm C công khai, 25+ `extern` constants, 12+ `@interface`/`@implementation`, cân bằng `()[]{}`, và đủ header `<Security/Security.h>`, `<string.h>`, `<stdlib.h>`, `<stdarg.h>` | **PASSED (0 missing defs, 0 duplicate defs, 0 missing headers, 0 security hygiene issues)** |

---

## 5. Kiểm thử CHƯA THỂ chạy & Blocker môi trường thực tế

Theo nguyên tắc trung thực kỹ thuật, các kiểm thử sau **chưa thể thực thi trên máy Windows hiện tại** và bắt buộc phải chạy trên macOS CI (`macos-26`) / thiết bị iPhone thật:

1. **Biên dịch Native Objective-C (`make` → `build/libZLMod.dylib` với `xcrun --sdk iphoneos clang -arch arm64`)**:
   - *Lý do:* Môi trường hiện tại là Windows, không có Xcode / iPhoneOS SDK / `clang` Darwin arm64.
   - *Biện pháp giảm thiểu đã làm:* Đã viết kiểm tra tĩnh tự động cân bằng ngoặc, local `#import`, định nghĩa 1-1 cho toàn bộ 39 hàm C & `extern` constants & `@interface`/`@implementation`, và kiểm tra hệ thống header C/POSIX (`<Security/Security.h>`, `<string.h>`, `<stdlib.h>`, `<stdarg.h>` — đã phát hiện và vá 9 thiếu sót header trước khi đẩy lên macOS CI!).
2. **Artifact Verification Gates (`bash Scripts/gates.sh build/libZLMod.dylib`)**:
   - *Lý do:* Yêu cầu `libZLMod.dylib` đã biên dịch cùng công cụ macOS (`otool`, `nm`, `codesign`, `file`).
3. **Đóng gói IPA thật kèm `libZLMod.dylib` biên dịch (`Packaging/package_ipa.py`)**:
   - *Lý do:* Pipeline `package_ipa.py` đã được kiểm thử E2E trên Mach-O tổng hợp (Full & No-Appex, xác minh căn chỉnh 8-byte), nhưng chưa đóng gói với file `libZLMod.dylib` thật vì chưa biên dịch trên macOS.
4. **Kiểm thử Runtime thực tế trên iPhone (Zalo `26.10.02` / `26.11.01`)**:
   - *Lý do:* Không có thiết bị iOS / Xcode runtime gắn kèm. Cần kiểm tra thực tế trên iPhone sau khi chạy workflow GitHub Actions `.github/workflows/build.yml` hoặc `.github/workflows/release.yml`:
     - Cài đặt qua Sideloadly / AltStore / TrollStore không bị `dyld` từ chối alignment.
     - Bật/tắt toàn bộ công tắc trên `S01`–`S08`, kiểm tra `ZLModStorageHealth`, Keychain migration, Anti-Recall (văn bản + ảnh sau khi kill/relaunch app), Delay Send khi bàn phím mở, Quick Reply `⚡` trong chat, CPairing Bonjour LAN, CSaving khi Anti-Recall OFF, CDeploy push/upload, và Discord Webhook Relay tự động.

---

## 6. Danh sách tệp tạo mới & chỉnh sửa

### Tệp tạo mới (10 tệp)
- `Resources/version.json`
- `Scripts/generate_version.py`
- `Sources/ZLModVersionData.h`
- `Sources/ZLModConstants.h`
- `Sources/ZLModChatEntityAdapter.m`
- `Sources/ZLModOverlayUI.m`
- `Sources/ZLModMessageTap.m`
- `Tests/test_rebuild_contracts.py`
- `Tests/test_realtime_bridge_logic.py`
- `Tests/test_security_and_anchors.py`
- `FINAL_FIX_REPORT.md` (tệp báo cáo này)

### Tệp chỉnh sửa (29 tệp)
- **Objective-C Headers & Sources (17 tệp):** `Sources/ZLMod.h`, `Sources/ZLModBridge.h`, `Sources/ZLModCompatibility.m`, `Sources/ZLModCore.m`, `Sources/ZLModHookEngine.m`, `Sources/ZLModCryptoStore.m`, `Sources/ZLModPreferences.m`, `Sources/ZLModSettings.m`, `Sources/ZLModPolicyStore.m`, `Sources/ZLModConversationMenu.m`, `Sources/ZLModPrivacy.m`, `Sources/ZLModURIFilter.m`, `Sources/ZLModAds.m`, `Sources/ZLModAntiRecall.m`, `Sources/ZLModUtilities.m`, `Sources/ZLModTheme.m`, `Sources/ZLModGlass.m`, `Sources/ZLModFeatures.m`, `Sources/ZLModBridge.m`, `Sources/ZLModUI.m`
- **Packaging, Build, Scripts & CI (9 tệp):** `Packaging/macho_injector.py`, `Packaging/ipa_preflight.py`, `Packaging/package_ipa.py`, `Makefile`, `Scripts/anchors.txt`, `Scripts/report.sh`, `Scripts/project_gate.py`, `.github/workflows/build.yml`, `.github/workflows/release.yml`
- **Tài liệu đồng bộ (7 tệp):** `README.md`, `docs/ARCHITECTURE.md`, `docs/FEATURES.md`, `docs/CHANGELOG.md`, `docs/audit/FEATURE_SPEC.md`, `docs/audit/TECHNICAL_DEBT.md`, `docs/audit/REBUILD_PLAN.md`

*(Không chạm tới tệp untracked `docs.zip` của người dùng.)*

---

## 7. Kết quả Build & Packaging

- **Python Packaging Pipeline (`macho_injector.py`, `package_ipa.py`, `ipa_preflight.py`)**: ✅ PASS toàn bộ test E2E Full & No-Appex, xác minh căn chỉnh 8-byte trên 9 độ dài `LC_RPATH` khác nhau (`len % 8 == 0..7`) + kiểm tra tiền bay trên IPA thật `121.7 MB`.
- **Native macOS Build (`make` → `build/libZLMod.dylib`)**: ⚠️ **CHƯA CHẠY CỤC BỘ (BLOCKED BY WINDOWS ENVIRONMENT)** — sẵn sàng kích hoạt trên GitHub Actions `macos-26` (`.github/workflows/build.yml` / `.github/workflows/release.yml`).

---

## 8. Kết quả xác minh Bảo mật (Security Verification)

| Hạng mục kiểm tra | Trạng thái | Bằng chứng |
|---|---|---|
| `kZLModBridgeToken` & `kZLModBridgeWebhook` chỉ lưu trong iOS Keychain | ✅ PASS | `ZLModSecretStore` (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) + `migrateLegacySecretsToKeychainIfNeeded` xóa sạch plaintext khỏi `own`/`group`/`standard` (`test_03_secret_persistence_keychain_only`) |
| Không có `token=` trong WebSocket URL query | ✅ PASS | Gửi qua header `Authorization: Bearer <token>` (`test_03_secret_persistence_keychain_only`) |
| `ZLModRedactText` lọc Discord Webhook URL, Bearer token, query secret & số 10+ chữ số | ✅ PASS | Kiểm tra regex trong `Sources/ZLModCore.m` (`test_25_objc_static_syntax_imports_installers_and_redaction`) |
| CDeploy chặn ghi đè `serverUrl`, `token`, `webhook`, `zlmod.internal.*` | ✅ PASS | `remoteDeployAllowedKeys` allowlist chặt (`test_18_cpairing_url_bonjour_cdeploy_allowlist_and_ack`) |
| Discord Webhook chỉ chấp nhận HTTPS domain chính thức của Discord | ✅ PASS | `isValidDiscordWebhookURLString:` chặn HTTP & domain giả (`test_19_discord_webhook_validation_and_automatic_relay`) |
| Không còn `memcpy`/`CFRetain`, `set_originTextRecallMsg:`, `setMessage:`, `ZX`, `Zync`, `ZyForce` | ✅ PASS | `test_license_boundary.py`, `project_gate.py`, `test_phase2_contracts.py`, `test_rebuild_contracts.py` |

---

## 9. Rủi ro còn tồn tại & Bước tiếp theo khuyến nghị

1. **Biên dịch thực tế trên macOS (`macos-26`)**: Dù đã kiểm tra cân bằng cú pháp, chữ ký hàm/hằng số/lớp và toàn bộ header C/POSIX, trình biên dịch `clang -Wall -Wextra -fobjc-arc -fmodules` với iPhoneOS SDK mới là nguồn xác minh cuối cùng cho kiểu dữ liệu ObjC (đặc biệt các cast `objc_msgSend` và cảnh báo strictARC). Khuyến nghị đẩy nhánh và chạy `.github/workflows/build.yml` ngay sau khi rà soát diff.
2. **Xác minh thực địa trên Zalo `26.10.02` / `26.11.01` thật**: Đặc biệt kiểm tra Bonjour LAN discovery (`NSLocalNetworkUsageDescription` trên iOS 14+ nếu hệ điều hành hỏi quyền mạng cục bộ), hiển thị tên hội thoại thật trên `S03`/`S06`, và layout bong bóng chat sau `prepareForReuse` khi cuộn nhanh danh sách tin nhắn có tin bị thu hồi.
3. **Tệp IPA mẫu trong `Decrypted/`**: File `vn.com.vng.zingalo_260401_decrypted_by_TTJB.ipa` là bản `260401 (708)` (cũ hơn target chính xác `261002`/`261101`), nên tại runtime sẽ vận hành qua nhánh **3-class runtime anchor quorum** (đã xác minh cả 3 class anchor đều có mặt trong binary `260401`). Khi đóng gói phát hành chính thức, nên dùng IPA decrypted đúng phiên bản `26.10.02` hoặc `26.11.01`.
