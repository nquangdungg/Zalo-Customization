# ZLMod — Tùy biến Native cho Zalo iOS (4.0 / Build 11)

Dylib độc lập (clean-room, pure `clang`, không Theos, không Cydia Substrate / ElleKit) dành cho Zalo iOS (`261002/261002802` và `261101/261101802` theo `Resources/compatibility.json`, kèm cơ chế xác minh 3-class runtime anchor quorum; bundle `vn.com.vng.zingalo` hoặc `vn.com.vng.zingalo2`, `arm64`, iOS 15.1+).

Mọi tính năng đều **tắt mặc định (fail-safe OFF)** khi mới cài đặt, dữ liệu nhạy cảm được mã hóa cục bộ và tách biệt theo từng tài khoản (`accountScope`).

---

## 1. Thành phần kiến trúc (4.0 — Build 11, 21 module)

Nguồn chân lý phiên bản duy nhất nằm tại `Resources/version.json` (tự sinh `Sources/ZLModVersionData.h` khi chạy `make`).

| Module | Chức năng & Vai trò |
|---|---|
| `ZLModCore` | Khởi tạo 2 pha (Pha A: hook nền an toàn; Pha B: UIKit trên main thread), cô lập từng module (`@try/@catch`), ring-buffer 200 dòng + file log `ZLMod.log` có redaction (lọc Discord webhook, Bearer token, query secret, số 10+ chữ số), dọn trạng thái khi đăng nhập/đăng xuất. |
| `ZLModCompatibility` | Bộ đánh giá thống nhất `ZLModEvaluateHostCompatibility`: ưu tiên exact target từ `Resources/compatibility.json`, fallback chỉ kích hoạt khi hội đủ 3 runtime anchor cốt lõi (`ZaloTabBarViewController`, `ChatDataManager`, `SettingUI40TableViewController`/`BasicSettingTableViewController`). |
| `ZLModHookEngine` | Chỉ mục selector 1 lượt (`ZLModPrewarmSelectorIndex`), thay thế phương thức có kiểm chứng arity + return encoding, helper UIKit an toàn main thread (`ZLModTopPresenterViewController`, `ZLModIsAnyTextInputActive`). |
| `ZLModChatEntityAdapter` | Chuẩn hóa đối tượng Zalo `ChatEntity` thành `ZLModMessageModel` bất biến: tự động chuẩn hóa timestamp giây/ms, nhận diện tin nhắn thu hồi theo cờ cấu trúc + khớp chính xác câu placeholder (không nhận nhầm chữ `"thu hồi"` trong tin nhắn thường), trích xuất ảnh & tiêu đề hội thoại. |
| `ZLModCryptoStore` | Mã hóa `AES-256-CBC + HMAC-SHA256` (văn bản & nhị phân) dùng khóa 256-bit trong iOS Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), `ZLModSecretStore` lưu bí mật (`Bridge Token`, `Discord Webhook`) hoàn toàn trong Keychain, báo cáo `ZLModStorageHealth`, hàng đợi ghi đĩa bất đồng bộ `zlmod.diskio`. |
| `ZLModPreferences` | Cấu hình bền vững (suite `vn.com.vng.zingalo.zlmod` + mirror App Group `group.zsettings.vn.com.vng.zingalo`), di chuyển & xóa sạch bí mật plaintext cũ sang Keychain, cập nhật gom lô (`performBatchUpdates:`), allowlist chặt chẽ cho CDeploy (`remoteDeployAllowedKeys`). |
| `ZLModOverlayUI` | Tiện ích main-thread (`ZLModRunOnMainThread`) & toast banner xếp hàng có hỗ trợ VoiceOver / Dynamic Type (tách khỏi `ConversationMenu`). |
| `ZLModPolicyStore` | Ngăn xếp LIFO `ZLModPrivacyContext` an toàn khi mở chat lồng nhau + chính sách Seen/Typing/Unread theo tài khoản (schema v3 lưu `titleCipher` tên hội thoại thật). |
| `ZLModURIFilter` | Chặn endpoint tracking & quảng cáo qua `NSURLProtocol`, đồng thời hook `NSURLSessionConfiguration` (`default` & `ephemeral`) và miễn trừ rõ host C-Bridge, Discord & WebSocket `Upgrade`. |
| `ZLModPrivacy` | Ẩn trạng thái đang nhập, kiểm soát đã xem toàn cục & theo từng người, tắt/bật lại được Firebase Analytics/Performance/Crashlytics ngay lập tức. |
| `ZLModConversationMenu` | Menu nhấn giữ hội thoại hỗ trợ cả `InboxContextMenuManager` & `InboxContextMenuProvider` (đóng gói Section chống crash + chống chèn trùng), chấm xanh chưa đọc cục bộ (`tag=0x5A1D`). |
| `ZLModMessageTap` | Event bus `ZLModMessageTapBus` tách hoàn toàn `AntiRecall`, `CSaving` và `DiscordRelay`; khử trùng lặp LRU có giới hạn (1000 khóa, tách riêng `obs`/`recall`). |
| `ZLModAntiRecall` | Chống thu hồi tin nhắn không sửa DB gốc: lưu bản sao chữ & ảnh mã hóa trên đĩa (`ZLModRecallPhotos`, quota 20 MB, TTL 14 ngày), sửa rò rỉ bộ nhớ `liveByKey` (`altKey`), dọn label khi tái sử dụng cell (`prepareForReuse`), nút **Hiện / Ẩn** trực tiếp trong ô chat & trình xem ảnh hỗ trợ pinch-to-zoom. |
| `ZLModUtilities` | Ghi chú riêng tư mã hóa hỗ trợ nhiều dòng (`UITextView`) + tên hội thoại thật; Quick Reply theo từng tài khoản + nút chèn nhanh `⚡` trên thanh chat (không bao giờ tự gửi); Delay Send Undo FSM 5 trạng thái hỗ trợ đa tin nhắn, đếm ngược trực tiếp & tránh bàn phím. |
| `ZLModTheme` | Điều phối giao diện hợp nhất `ZLModAppearanceCoordinator` (1 baseline duy nhất cho Theme & Blur Tab Bar), các preset màu và kiểm tra nghiêm ngặt mã `#RRGGBB`. |
| `ZLModGlass` | Chất liệu mờ `UIBlurEffectStyleSystemUltraThinMaterial` cho Tab Bar phối hợp qua `ZLModAppearanceCoordinator` (không tham chiếu `UIGlassEffect` do Zalo dùng `UIDesignRequiresCompatibility=YES`). |
| `ZLModAds` | Ẩn thành phần quảng cáo feed/OA và theo dõi bằng `NSHashTable` yếu để khôi phục hiển thị ngay khi tắt công tắc. |
| `ZLModFeatures` | Khôi phục Profile Music, Google Drive Backup bridge và More Tab bằng chỉ mục selector 1 lượt. |
| `ZLModSettings` | Chèn mục `ZLMod Customize` theo từng VC độc lập (không `memcpy`/`CFRetain`), nút dự phòng trên thanh điều hướng không lệch chỉ số bảng, cử chỉ lắc an toàn với iOS Undo Typing & có công tắc tắt. |
| `ZLModBridge` | Máy khách C-Bridge: WebSocket FSM 4 trạng thái có `connectionEpoch` chống stale task, exponential backoff (`2s..30s`), heartbeat `20s` + pong timeout `10s`, quét máy chủ LAN qua Bonjour/mDNS, gửi token qua header `Authorization: Bearer`, CSaving độc lập giữ đúng thứ tự khi gửi lại, CDeploy allowlist + guaranteed `cdeploy_ack`, và **Discord Webhook Relay tự động** cho tin nhắn đến & tin bị thu hồi. |
| `ZLModUI` | Bảng điều khiển trung tâm (`S01`) + 7 màn hình quản lý & chẩn đoán (`S02`–`S08`), banner cảnh báo `ZLModStorageHealth`, spinner tải, pull-to-refresh và hỗ trợ Dynamic Type / VoiceOver. |

---

## 2. Đóng gói & Cài đặt IPA

Pipeline Python trong `Packaging/` thực hiện:
- `Packaging/macho_injector.py`: Tiêm `LC_RPATH` (`@executable_path/Frameworks`) và `LC_LOAD_DYLIB` (`@rpath/libZLMod.dylib`) với kiểm tra bắt buộc căn chỉnh **8-byte** cho mọi load command và `sizeofcmds` trên Mach-O 64-bit arm64.
- `Packaging/package_ipa.py`: Đóng gói bản **Full** (giữ extensions, phù hợp TrollStore / Apple Developer trả phí) và bản **No-Appex** (`--no-appex`, chỉ dùng 1 App ID, khuyến nghị cho Sideloadly / AltStore / SideStore / xtool với Apple ID miễn phí).
- `Packaging/ipa_preflight.py`: Kiểm tra tiền bay IPA (cryptid=0, tương thích, căn chỉnh 8-byte, và phân loại đầy đủ 5 trạng thái chữ ký kể cả thiếu `embedded.mobileprovision` hoặc thiếu `_CodeSignature/CodeResources`).

---

## 3. Biên dịch & Kiểm thử

```bash
# 1. Kiểm thử portable trên mọi hệ điều hành (Python 3):
python3 -m unittest discover -s Tests -p "test_*.py" -v
python3 Scripts/project_gate.py .
python3 Packaging/ipa_preflight.py Decrypted/<decrypted.ipa> --require-unencrypted-main

# 2. Biên dịch dylib & kiểm định cổng tĩnh trên macOS (Xcode iphoneos SDK):
make          # Tự chạy Scripts/generate_compatibility.py & Scripts/generate_version.py
make gates    # Xác minh arm64, dependencies sạch, minos 15.1, codesign
```

---

## 4. Ranh giới an toàn kỹ thuật (Clean-Room Boundary)

ZLMod được thiết kế độc lập theo chuẩn clean-room, chỉ liên kết `UIKit`, `Foundation`, `QuartzCore`, `Security`. Các tính năng do máy chủ Zalo quyết định (ZCloud Premium, quyền Admin nhóm, vượt giới hạn dung lượng / TTL máy chủ) cố ý không được triển khai.
