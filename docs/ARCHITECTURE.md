# ZLMod — Kiến trúc Kỹ thuật (4.0 / Build 11)

## 1. Sơ đồ kiến trúc phân tầng

```text
┌──────────────────────────────────────────────────────────────────────────────────────┐
│ ZLModCore (Two-Phase Boot: Phase A background hooks -> Phase B main-thread UIKit)    │
│   ├─ Version SoT: Resources/version.json -> Sources/ZLModVersionData.h               │
│   ├─ Compat Gate: ZLModCompatibility (exact targets + 3-class anchor quorum)         │
│   ├─ Redacted Logging: ring-buffer (200) + rotating ZLMod.log (512 KB, async I/O)    │
│   └─ Session Observers: AppDelegate -didLogout / -didLogin -> invalidate all caches  │
├──────────────────────────────────────────────────────────────────────────────────────┤
│ Foundation & Runtime Layer                                                           │
│   ├─ ZLModHookEngine        Single-pass selector index + ABI-validated swizzling     │
│   ├─ ZLModChatEntityAdapter Immutable ZLModMessageModel (ms/s, exact recall detect)  │
│   ├─ ZLModCryptoStore       Keychain AES-256-CBC+HMAC-SHA256 + ZLModSecretStore      │
│   │                         + ZLModStorageHealth + async disk queue (zlmod.diskio)   │
│   ├─ ZLModPreferences       Suite + AppGroup + Keychain secret routing + Batch/Allow │
│   └─ ZLModOverlayUI         Decoupled main-thread helpers + queued VoiceOver Toast   │
├──────────────────────────────────────────────────────────────────────────────────────┤
│ Decoupled Event Pipeline                                                             │
│   ChatEntity hooks (ZLModMessageTap)                                                 │
│         │  (active whenever AntiRecall OR CSaving OR DiscordRelay is ON)             │
│         ▼                                                                            │
│   ZLModChatEntityAdapter -> ZLModMessageTapBus (1000-entry LRU dedup: obs / recall)  │
│         ├──> ZLModAntiRecall  (encrypted text + disk photos 20MB/14d, in-place UI)   │
│         ├──> ZLModBridge [CSaving]      (500-key dedup, ordered retry cap 50)        │
│         └──> ZLModBridge [DiscordRelay] (domain-checked, rate-limited 1.5s, 429)     │
├──────────────────────────────────────────────────────────────────────────────────────┤
│ Feature & Presentation Layer                                                         │
│   ├─ ZLModPolicyStore & ZLModConversationMenu (LIFO stack, v3 encrypted titles)      │
│   ├─ ZLModPrivacy & ZLModURIFilter & ZLModAds (NSURLSession cover, reversible live)  │
│   ├─ ZLModUtilities (multi-line notes, account QuickReply + chat picker, DelaySend)  │
│   ├─ ZLModTheme & ZLModGlass (unified ZLModAppearanceCoordinator, single baseline)   │
│   ├─ ZLModFeatures (Profile Music, GDrive bridge, More Tab — single-pass index)      │
│   ├─ ZLModSettings (per-VC state, zero memcpy/CFRetain, nav bar fallback, safe shake)│
│   └─ ZLModUI (S01 Dashboard + S02..S08 child screens, storage banners, spinners)     │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

Một dylib duy nhất (`build/libZLMod.dylib`), liên kết duy nhất với `UIKit`, `Foundation`, `QuartzCore`, `Security`.

---

## 2. Nguyên tắc kỹ thuật & bảo mật cốt lõi

1. **Không rò rỉ bí mật (`ZLModSecretStore`):**
   - `kZLModBridgeToken` và `kZLModBridgeWebhook` được định tuyến độc quyền vào iOS Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), tự động di chuyển và xóa sạch mọi bản sao plaintext cũ từ `NSUserDefaults` / App Group lúc khởi động.
   - WebSocket gửi token qua HTTP header `Authorization: Bearer <token>`, tuyệt đối không đưa vào query string.
   - `ZLModRedactText()` lọc URL Discord webhook (`/api/.../webhooks/<id>/<token>`), đường dẫn `/webhooks/...`, query secrets, Bearer token và chuỗi 10+ chữ số trước khi ghi ring-buffer hoặc `ZLMod.log`.
2. **Minh bạch lỗi lưu trữ (`ZLModStorageHealth`):**
   - Phân biệt rành mạch `ZLModStorageHealthReady`, `ZLModStorageHealthAccountUnidentified` và `ZLModStorageHealthKeychainUnavailable(OSStatus)`.
   - Các màn hình `S01`, `S03`, `S04`, `S06` hiển thị banner cảnh báo thay vì giả dạng danh sách trống khi chưa nhận diện tài khoản hoặc Keychain bị khóa.
3. **WebSocket FSM 4 trạng thái & chống Race Condition (`ZLModBridge`):**
   - `Disconnected -> Connecting -> Connected -> Closing -> Disconnected` được bảo vệ bởi bộ đếm đơn điệu `connectionEpoch`; mọi callback đến trễ từ socket đã hủy bị bỏ qua hoàn toàn.
   - Exponential backoff `2s -> 4s -> 8s -> 16s -> 30s`, reset khi kết nối thành công; Heartbeat `20s` + Pong timeout `10s` phát hiện kết nối treo nửa mở; đóng sạch khi vào nền và `invalidateAndCancel` khi dừng hẳn.
   - Khi gửi lô CSaving thất bại, lô cũ được **chèn trước** các tin nhắn mới phát sinh trong lúc chờ gửi (`failed_batch + newer_pending`, cắt bớt đầu cũ nếu vượt 50) để bảo toàn tuyệt đối thứ tự thời gian.
   - CDeploy chỉ chấp nhận các khóa trong `remoteDeployAllowedKeys` (từ chối tuyệt đối `serverUrl`, `token`, `webhook`, `zlmod.internal.*`), xếp hàng nếu chưa có presenter và luôn trả `cdeploy_ack`.
4. **Hợp nhất giao diện (`ZLModAppearanceCoordinator`):**
   - Chụp đúng một baseline bất biến cho mỗi `UIWindow`, `UINavigationBar`, `UITabBar`.
   - Phối hợp thuần túy `Baseline -> Theme -> TabBarBlur` để bật/tắt Theme và Blur theo bất kỳ thứ tự nào cũng không ghi đè hoặc làm hỏng giao diện gốc của Zalo.
5. **Mach-O 64-bit arm64 Alignment & IPA Preflight:**
   - `Packaging/macho_injector.py` căn chỉnh tổng `cmdsize = align8(12 + len(rpath_bytes))` cho `LC_RPATH` và xác minh mọi load command có `cmdsize % 8 == 0`, `sizeofcmds % 8 == 0`.
   - `Packaging/ipa_preflight.py` nhận diện đủ 5 trạng thái chữ ký (`UNSIGNED_ARCHIVE`, `PARTIAL_SIGNATURE_MISSING_PROVISION`, `PARTIAL_PROVISION_MISSING_CODESIGN`, `STALE_SIGNATURE_MISMATCH`, `PROVISIONED_AND_SIGNED`).

---

## 3. Kiểm chứng & Tự động hóa CI

```text
Kiểm thử cục bộ (Python 3 — chạy được trên Windows/macOS/Linux):
  python3 -m unittest discover -s Tests -p "test_*.py" -v   (72 tests: 71 passed, 1 skipped)
  python3 Scripts/project_gate.py .                         (Exit code 0)
  python3 Packaging/ipa_preflight.py Decrypted/<ipa> --require-unencrypted-main

Biên dịch & Đóng gói CI (GitHub Actions macos-26):
  - Biên dịch: make -> build/libZLMod.dylib (arm64, minos 15.1)
  - Cổng kiểm định: bash Scripts/gates.sh build/libZLMod.dylib
  - Đóng gói & xác minh: Packaging/package_ipa.py (full + noappex) + Packaging/ipa_preflight.py
```
