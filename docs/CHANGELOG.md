# ZLMod — Lịch sử cập nhật (Changelog)

Toàn bộ quá trình phát triển và các mốc phát hành của dự án ZLMod cho Zalo iOS.

---

## [4.0 / Build 11] — 2026-11-26
### Tái kiến trúc toàn diện theo Module (MODULE 01 – MODULE 12)
- **Foundation & Compatibility (`ZLModCore`, `ZLModCompatibility`, `ZLModConstants.h`, `Resources/version.json`):**
  - Hợp nhất nguồn chân lý phiên bản (`Resources/version.json` → `Scripts/generate_version.py` → `Sources/ZLModVersionData.h`).
  - Khởi tạo 2 pha an toàn luồng (Pha A: hook nền; Pha B: UIKit trên main thread); loại bỏ phụ thuộc ngược `ZLModCore -> ZLModConversationMenu` bằng `ZLModOverlayUI.m`.
  - Hợp nhất logic tương thích `ZLModEvaluateHostCompatibility`, gỡ bỏ kiểm tra chuỗi lỏng `"zalo"`/`"zing"`, thay bằng cơ chế xác minh 3-class runtime anchor quorum.
  - Mở rộng `ZLModRedactText()` che giấu URL Discord Webhook, Bearer token và query secrets.
- **Bảo mật Keychain & Storage Health (`ZLModCryptoStore`, `ZLModPreferences`):**
  - Tạo `ZLModSecretStore` lưu `kZLModBridgeToken` và `kZLModBridgeWebhook` hoàn toàn trong iOS Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), tự động di chuyển và xóa sạch plaintext cũ khỏi `NSUserDefaults` / App Group.
  - Thêm `ZLModCurrentStorageHealth` phân biệt `Ready`, `AccountUnidentified`, `KeychainUnavailable(OSStatus)`; bổ sung hàng đợi ghi đĩa bất đồng bộ `zlmod.diskio`; loại bỏ hoàn toàn `[NSUserDefaults synchronize]`.
  - Bổ sung `performBatchUpdates:` và allowlist `remoteDeployAllowedKeys` cho CDeploy.
- **Event Bus tách biệt & Anti-Recall hoàn chỉnh (`ZLModChatEntityAdapter`, `ZLModMessageTap`, `ZLModAntiRecall`):**
  - Tách hoàn toàn `CSaving` và `DiscordRelay` khỏi `AntiRecall` thông qua `ZLModChatEntityAdapter` → `ZLModMessageTapBus`.
  - Lưu ảnh thu hồi đã mã hóa trên đĩa (`ZLModRecallPhotos/*.enc`, quota 20 MB, TTL 14 ngày) để không mất ảnh sau khi khởi động lại app.
  - Sửa rò rỉ bộ nhớ `liveByKey` (dọn cả `primaryKey` lẫn `altKey`), sửa lỗi nhận diện nhầm chữ `"thu hồi"`, loại bỏ `set_originTextRecallMsg:` và dead code, dọn label khi cell tái sử dụng (`prepareForReuse`), nâng cấp trình xem ảnh hỗ trợ pinch-to-zoom.
- **C-Bridge Realtime & Discord Relay tự động (`ZLModBridge`):**
  - Nâng cấp WebSocket lên FSM 4 trạng thái (`Disconnected/Connecting/Connected/Closing`) với `connectionEpoch` chống stale task, exponential backoff (`2s..30s`), heartbeat `20s` + pong timeout `10s`, đóng sạch khi vào nền, `invalidateAndCancel` khi dừng.
  - Sửa lỗi URL `testPairingWithCompletion:` bằng `NSURLComponents`, thêm quét máy chủ LAN tự động qua Bonjour (`NSNetServiceBrowser`), chuyển token từ query string sang header `Authorization: Bearer`.
  - Bảo toàn thứ tự tin nhắn CSaving khi gửi lại (chèn lô lỗi trước tin mới, cap 50); CDeploy dùng allowlist chặt, xếp hàng khi presenter bận và luôn trả `cdeploy_ack`.
  - Triển khai **Discord Webhook Relay tự động** cho tin nhắn đến và tin bị thu hồi với kiểm tra tên miền chính thức, chống trùng lặp, rate limit (`1.5s` / HTTP 429 `Retry-After`) và tối đa 2 lần thử lại.
- **Tiện ích, Giao diện & Mạng (`ZLModUtilities`, `ZLModTheme`, `ZLModGlass`, `ZLModAds`, `ZLModPrivacy`, `ZLModURIFilter`, `ZLModSettings`, `ZLModUI`):**
  - Ghi chú nhiều dòng (`UITextView`) + tên hội thoại thật mã hóa (schema v3); Quick Reply theo tài khoản + nút chèn nhanh trong chat; Delay Send đa tin nhắn tránh bàn phím.
  - Hợp nhất Theme & Blur Tab Bar qua `ZLModAppearanceCoordinator`; kiểm tra chặt `#RRGGBB`; khôi phục live khi tắt `Hide Ads` và `Disable Firebase`; mở rộng `ZLModURIFilter` sang `NSURLSessionConfiguration` (miễn trừ C-Bridge/Discord/WS).
  - Loại bỏ `memcpy`/`CFRetain` trong `ZLModSettings.m`, bảo vệ Undo Typing trước cử chỉ lắc máy, cập nhật toàn bộ 8 màn hình `ZLModUI.m` (banner `ZLModStorageHealth`, spinner, pull-to-refresh, loại bỏ gọi `reconnect` & thông báo trùng lặp).
- **Mach-O Packaging, Anchors, CI & Tests:**
  - Sửa lỗi căn chỉnh 8-byte của `LC_RPATH` trong `Packaging/macho_injector.py` và bổ sung `verify_macho_alignment`.
  - Sửa `Packaging/ipa_preflight.py` nhận diện chính xác 5 trạng thái chữ ký (phát hiện `PARTIAL_SIGNATURE_MISSING_PROVISION` trên IPA mẫu thực tế).
  - Mở rộng `Scripts/anchors.txt` lên 118 anchor đã xác minh trực tiếp trên Mach-O, nâng tổng số automated test lên 72 test (71 passed, 1 skipped).

---

## [Build 10] — 2026-11-12
### Tích hợp C-Bridge ban đầu
- Thêm `ZLModBridge.h` / `ZLModBridge.m` và màn hình `ZLModBridgeViewController` (CPairing, CSaving, CDeploy, kiểm tra Discord Webhook).

---

## [Build 9] — 2026-11-10
### Đột phá tính năng & Sửa lỗi toàn diện
- Sửa lỗi crash khi nhấn giữ hội thoại ở màn hình chính bằng Sectioned Array (`NSArray<NSArray<ZAContextMenuAction *> *>`).
- Thêm nút **Hiện / Ẩn** tin nhắn thu hồi trực tiếp tại ô chat (In-Place Toggle) và modal xem ảnh thu hồi.

---

## [Build 8] — 2026-11-10
- Khắc phục treo Tab Bar (`0x8BADF00D`) bằng `UIBlurEffectStyleSystemUltraThinMaterial`.
- Thêm nút "Hiện" vào menu ngữ cảnh bong bóng chat.

---

## [Build 7] — 2026-11-10
- Chụp snapshot tin nhắn tại `ConversationModel -didLoadChats:config:` trước khi thu hồi.

---

## [Build 5 – 6] — 2026-11-09
- Hoàn thiện Phase 2/3: Per-Conversation Policies, Chấm xanh cục bộ, Delay Send Undo FSM, Quick Replies, Private Notes mã hóa AES-256-CBC + HMAC-SHA256, chặn quảng cáo và ring-buffer log.

---

## [Build 1 – 4] — 2026-11-08
- Thiết lập kiến trúc Clean-room độc lập (không Theos, không Substrate/ElleKit), `ZLModHookEngine`, bảng anchor ban đầu và `Packaging/package_ipa.py`.
