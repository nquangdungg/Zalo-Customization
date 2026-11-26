# SCREEN_SPEC.md — Kiểm toán Màn hình (Phase 3), Component (Phase 4) & UX (Phase 15)

> **Lưu ý kiểm chứng trực quan:** Toàn bộ UI của ZLMod là **native iOS UIKit (`UIViewController`, `UITableViewController`, `UIAlertController`, `UIView`)** chạy bên trong ứng dụng Zalo iOS trên thiết bị iPhone/iPad thật (arm64). Vì không có trình giả lập iOS / iPhone vật lý hay screenshot UI thực tế trong workspace này, toàn bộ đặc tả dưới đây được reverse-engineer trực tiếp từ source code UIKit (`Sources/ZLModUI.m`, `ZLModSettings.m`, `ZLModAntiRecall.m`, `ZLModConversationMenu.m`, `ZLModUtilities.m`, `ZLModGlass.m`, `ZLModTheme.m`), còn hiển thị pixel thực tế trên máy thật là **`UNKNOWN — NEEDS VERIFICATION`**.

---

## PHẦN A — PHASE 3: SCREEN-BY-SCREEN AUDIT

Hệ thống có **9 `UIViewController` tự xây dựng** và **5 bề mặt UI tiêm trực tiếp (In-Place Host Overlays/Modals)** bên trong ứng dụng Zalo.

### S01 — `ZLModSettingsViewController` (Main Dashboard)
- **Screen:** ZLMod Customize (Main Dashboard) — `Sources/ZLModUI.m:858-1247`
- **Route:** Push lên `UINavigationController` từ `SettingUI40TableViewController`, HOẶC present modal `UIModalPresentationFormSheet` (`UINavigationController` wrapper + nút `Done`) khi kích hoạt Shake Gesture (`ZLModSettingsViewController +pushFrom:`).
- **Purpose:** Trung tâm bật/tắt 14 công tắc tính năng và điều hướng vào 7 màn hình quản lý / chẩn đoán + 3 action sheets/dialogs.
- **Entry points:** Hàng `"ZLMod Customize"` trong Cài đặt Zalo; cử chỉ lắc máy toàn cục (`UIWindow -motionEnded:withEvent:`).
- **Exit points:** Back button (nếu push), nút `Done` / vuốt modal (nếu modal), hoặc push tới S02–S08.
- **Components:** `UITableView` (`UITableViewStyleInsetGrouped`, `rowHeight = AutomaticDimension`), 10 sections, 3 loại cell (`ZLModSwitchCell` với `UISwitch`, `ZLModActionCell` có `DisclosureIndicator`, `ZLModInfoCell` chỉ đọc), 3 modal dialogs (`presentThemePresetPickerFromIndexPath:`, `presentThemeTintEditor`, `presentDelayDurationPickerFromIndexPath:`, `presentResetAllConfirmation`).
- **Data source:** `ZLModPreferences`, `ZLModThemeManager`, `ZLModConversationPolicyStore`, `ZLModAntiRecallStore`, `ZLModDelaySendManager`, `ZLModQuickReplyStore`, `ZLModPrivateNotesStore`, `ZLModBridgeManager`, `ZLModAllModuleStatuses()`, `ZLModReadRecentLogs(200)`, `ZLModCurrentAccountScope()`, `ZLModCompatibility`, `ZLModGlassMaterialDescription()`.
- **API:** Chỉ gọi local managers/stores; không gọi mạng trực tiếp.
- **State:** `@property NSArray<NSDictionary *> *model`, `@property NSMutableDictionary<NSString *, UISwitch *> *switches`.
- **User actions:** Bật/tắt 14 switches; chạm Theme Preset / Custom Tint / Delay Duration / Reset All; điều hướng vào 7 màn con.
- **Loading:** Không có (đồng bộ trên main thread; lưu ý `buildModel` giải mã toàn bộ `ZLModPrivateNotesStore` để đếm `notesCount` tại dòng 959!).
- **Empty:** Không áp dụng (luôn có 10 sections cố định).
- **Error:** Không có error banner; thông tin lỗi hiển thị qua `Active Account Scope = "unidentified (fail-closed)"`, `Compatibility`, và số module `X/Y active`.
- **Responsive:** Dùng `UITableViewStyleInsetGrouped` + popover anchor `sourceView`/`sourceRect` cho iPad ActionSheet (`ZLModUI.m:1168-1172, 1214-1218`).
- **Permissions:** Không yêu cầu quyền hệ thống trực tiếp.
- **Dependencies:** Tất cả các module trong `Sources/`.

---

### S02 — `ZLModBridgeViewController` (C-Bridge & Local Server)
- **Screen:** C-Bridge & Local Server — `Sources/ZLModUI.m:17-260`
- **Route:** Push từ S01 (`action == @"bridge_settings"`).
- **Purpose:** Cấu hình Local Server URL, Bridge Token, Discord Webhook URL; kiểm tra ping CPairing, test Webhook, tải cài đặt lên server (CDeploy), bật/tắt CSaving và xem số tin đã chuyển tiếp.
- **Entry points:** S01 → Section `"C-Bridge & Local Server"` → row `"C-Bridge & Local Server"`.
- **Exit points:** Navigation Back → S01.
- **Components:** `UITableViewController` (`InsetGrouped`, 5 sections × 2 rows = 10 rows), 1 `UISwitch` (CSaving), 3 `UIAlertControllerStyleAlert` (nhập Server URL, Token, Webhook URL).
- **Data source:** `ZLModPreferences`, `ZLModBridgeManager`.
- **API:** `testPairingWithCompletion:` (`GET /api/cbridge/health` — **đang lỗi URL**), `testWebhookWithCompletion:` (`POST <webhook>`), `uploadCurrentSettingsWithCompletion:` (`WS cdeploy_upload`), `[mgr reconnect]` (`WS /cbridge/ws`).
- **State:** Không có local property; đọc trực tiếp từ `ZLModPreferences` & `ZLModBridgeManager` mỗi lần `reloadData`; lắng nghe `ZLModBridgeStatusDidChangeNotification`.
- **User actions:** Ping Server, sửa Server URL, sửa Token, sửa Webhook URL, gửi test Discord, tải cài đặt lên server, bật/tắt CSaving.
- **Loading:** Chỉ hiển thị toast văn bản (`"Đang kiểm tra kết nối tới Server..."`, `"Đang gửi thông báo thử nghiệm..."`, `"Đang tải cài đặt lên máy chủ..."`); **KHÔNG có `UIActivityIndicatorView` và KHÔNG khóa nút chống bấm đúp**.
- **Empty:** Chưa nhập URL → `"Chưa nhập (http://...)"`; chưa nhập Token → `"Để trống nếu không dùng"`; chưa đồng bộ → `"Chưa đồng bộ"`.
- **Error:** Hiện toast lỗi trả về từ completion handler.
- **Responsive:** Chuẩn `UITableViewController`; alert không phụ thuộc iPad popover.
- **Permissions:** Phụ thuộc iOS Local Network permission (LAN) khi kết nối `192.168.x.x`.
- **Dependencies:** `ZLModBridgeManager`, `ZLModPreferences`, `ZLModShowToast`.

---

### S03 — `ZLModConversationPoliciesViewController` (Per-Conversation Policies)
- **Screen:** Per-Conversation Policies — `Sources/ZLModUI.m:264-368`
- **Route:** Push từ S01 (`action == @"conv_policies"`).
- **Purpose:** Liệt kê các cuộc trò chuyện đang có chính sách tùy chỉnh (Ẩn đã xem, Ẩn đang nhập, Chấm xanh chưa đọc) của tài khoản hiện tại và cho phép khôi phục mặc định từng hội thoại hoặc xóa tất cả.
- **Entry points:** S01 → `"Per-Conversation Policies"`.
- **Exit points:** Back → S01.
- **Components:** `UITableViewController` (1 section), nút `Xóa tất cả` ở rightBarButtonItem, `UIAlertController` xác nhận reset tất cả, `ActionSheet` khôi phục mặc định từng dòng (có iPad popover anchor).
- **Data source:** `[[ZLModConversationPolicyStore shared] summaryEntriesForCurrentAccount]`.
- **API:** Local `ZLModConversationPolicyStore`.
- **State:** `@property NSArray<NSDictionary *> *entries`.
- **User actions:** Chạm dòng → ActionSheet `"Khôi phục mặc định"`; chạm `"Xóa tất cả"` → Alert `"Đặt lại"`.
- **Loading:** Đồng bộ.
- **Empty:** 1 dòng không chọn được: `"Chưa có hội thoại nào được tùy chỉnh riêng"` + footer hướng dẫn nhấn giữ cuộc trò chuyện.
- **Error:** Nếu `accountScope == nil` → bị chuyển thành empty state (không phân biệt được "chưa có cấu hình" với "fail-closed chưa nhận diện tài khoản"!).
- **Responsive:** Popover supported.
- **Permissions:** Không.
- **Dependencies:** `ZLModConversationPolicyStore`, `ZLModShowToast`.

---

### S04 — `ZLModAntiRecallHistoryViewController` (Ghost Preview History)
- **Screen:** Ghost Preview History — `Sources/ZLModUI.m:372-475`
- **Route:** Push từ S01 (`action == @"antirecall_history"`).
- **Purpose:** Xem danh sách metadata các tin nhắn thu hồi đã được lưu cục bộ (còn trong hạn 14 ngày), chạm để giải mã on-demand & sao chép, hoặc xóa toàn bộ lịch sử tài khoản hiện tại.
- **Entry points:** S01 → `"Ghost Preview History"`.
- **Exit points:** Back → S01.
- **Components:** `UITableViewController` (1 section), nút `Xóa lịch sử`, `UIAlertController` hiển thị nội dung giải mã + nút `"Sao chép"`, `UIAlertController` xác nhận xóa sạch.
- **Data source:** `[[ZLModAntiRecallStore shared] entriesForCurrentAccount]` & `revealTextForEntryKey:`.
- **API:** Local `ZLModAntiRecallStore` + `ZLModCryptoBox`.
- **State:** `@property NSArray<NSDictionary *> *entries`.
- **User actions:** Chạm dòng để giải mã & xem; bấm `"Sao chép"`; bấm `"Xóa lịch sử"`.
- **Loading:** Đồng bộ.
- **Empty:** `"Chưa có bản sao tin nhắn thu hồi nào"`.
- **Error:** Nếu giải mã thất bại → hiển thị `"Không thể giải mã bản ghi này (khóa hoặc ngữ cảnh không khớp)."` (và nút `"Sao chép"` vẫn copy nguyên câu thông báo lỗi này!).
- **Responsive:** Chuẩn `UITableViewController`.
- **Permissions:** Không.
- **Dependencies:** `ZLModAntiRecallStore`, `ZLModShowToast`.

---

### S05 — `ZLModQuickRepliesViewController` (Quick Reply Templates)
- **Screen:** Quick Reply Templates — `Sources/ZLModUI.m:479-649`
- **Route:** Push từ S01 (`action == @"quick_replies"`).
- **Purpose:** Thêm, sửa, xóa, kéo sắp xếp thứ tự, khôi phục mẫu mặc định (3 câu) và chèn mẫu câu vào khung chat đang mở (hoặc clipboard).
- **Entry points:** S01 → `"Quick Reply Templates"`.
- **Exit points:** Back → S01.
- **Components:** `UITableViewController` (2 sections: Mẫu câu + Tác vụ), rightBarButtonItems `[+, Edit]`, ActionSheet 4 nút (Chèn / Chỉnh sửa / Xóa / Đóng), 2 `UIAlertController` nhập/sửa text.
- **Data source:** `ZLModQuickReplyStore` (`Documents/ZLModQuickReplies.plist`).
- **API:** `insertTemplateIntoComposer:` → `BaseChatTVC -fillChatBarWithText:` / `firstResponder` / `UIPasteboard`.
- **State:** `@property NSArray<NSString *> *templates`.
- **User actions:** Thêm (`+`), kích hoạt Edit mode (vuốt xóa, kéo thả reorder), chạm dòng mở ActionSheet, chạm `"Khôi phục mẫu câu mặc định"` (không có hộp thoại xác nhận!).
- **Loading:** Đồng bộ.
- **Empty:** `"Chưa có mẫu câu nào (Nhấn + để thêm)"`.
- **Error:** Không có phản hồi lỗi khi thêm thất bại (rỗng hoặc đạt tối đa 50 mẫu).
- **Responsive:** Popover supported cho ActionSheet.
- **Permissions:** Không.
- **Dependencies:** `ZLModQuickReplyStore`, `ZLModShowToast`.

---

### S06 — `ZLModPrivateNotesViewController` (Encrypted Private Notes)
- **Screen:** Encrypted Private Notes — `Sources/ZLModUI.m:653-737`
- **Route:** Push từ S01 (`action == @"private_notes"`).
- **Purpose:** Xem danh sách ghi chú đã giải mã của tài khoản hiện tại, chạm để sửa/xóa từng ghi chú, hoặc xóa tất cả.
- **Entry points:** S01 → `"Encrypted Private Notes"`.
- **Exit points:** Back → S01.
- **Components:** `UITableViewController` (1 section), nút `Xóa tất cả`, dùng chung `ZLModPresentPrivateNoteEditor(...)` (`UIAlertController`).
- **Data source:** `[[ZLModPrivateNotesStore shared] allEntriesForCurrentAccount]`.
- **API:** Local `ZLModPrivateNotesStore` + `ZLModCryptoBox`.
- **State:** `@property NSArray<NSDictionary<NSString *, NSString *> *> *entries`.
- **User actions:** Chạm dòng sửa/xóa ghi chú; chạm `"Xóa tất cả"`.
- **Loading:** Đồng bộ (giải mã toàn bộ ghi chú của account mỗi lần `reloadNotes`).
- **Empty:** `"Chưa có ghi chú riêng tư nào"`.
- **Error:** Fail-closed hoặc lỗi giải mã bị âm thầm bỏ qua (`if (note.length == 0) continue;`, `ZLModUtilities.m:198`) và hiển thị như empty state!
- **Responsive:** Chuẩn `UITableViewController`.
- **Permissions:** Không.
- **Dependencies:** `ZLModPrivateNotesStore`, `ZLModPresentPrivateNoteEditor`, `ZLModShowToast`.

---

### S07 — `ZLModModuleStatusViewController` (Module Hook Status)
- **Screen:** Module Hook Status — `Sources/ZLModUI.m:741-781`
- **Route:** Push từ S01 (`action == @"module_status"`).
- **Purpose:** Hiển thị trạng thái `HOOK_INSTALLED` / `NOT_INSTALLED` và chuỗi chi tiết của từng module (13 keys: `URIFilter`, `Privacy`, `SeenPrivacy`, `TypingPrivacy`, `Ads`, `Features`, `Settings`, `Glass`, `ConversationMenu`, `AntiRecall`, `Utilities`, `Theme`, `Bridge`).
- **Entry points:** S01 → `"Module Hook Status"`.
- **Exit points:** Back → S01.
- **Components:** `UITableViewController` (1 section, cell read-only `Subtitle`).
- **Data source:** `ZLModAllModuleStatuses()` (`ZLModCore.m`).
- **API / State / Loading / Empty / Error:** Read-only snapshot chụp 1 lần ở `viewDidLoad` (không tự refresh nếu status đổi sau đó).

---

### S08 — `ZLModLogViewerController` (Runtime Logs — Redacted)
- **Screen:** Runtime Logs (Redacted) — `Sources/ZLModUI.m:785-854`
- **Route:** Push từ S01 (`action == @"log_viewer"`).
- **Purpose:** Xem tối đa 200 dòng log mới nhất đã redact, sao chép toàn bộ log hoặc xóa bộ đệm & file log.
- **Entry points:** S01 → `"Runtime Log Viewer"`.
- **Exit points:** Back → S01.
- **Components:** `UITableViewController` (`Plain`), header là `ZLModPrimaryLogPath()`, rightBarButtonItems `[Xóa, Sao chép]`, font monospaced `11.5pt`, `numberOfLines = 0`.
- **Data source:** `ZLModReadRecentLogs(200)`.
- **User actions:** Sao chép log vào `UIPasteboard`, Xóa log.
- **Empty:** 1 dòng `"Log trống"`.
- **Missing controls:** Không có nút Refresh / pull-to-refresh và không có thanh lọc/tìm kiếm log.

---

### S09 — `ZLModPhotoPreviewController` (Recalled Photo Fullscreen Viewer)
- **Screen:** Ảnh đã thu hồi — `Sources/ZLModAntiRecall.m:801-954`
- **Route:** Present fullscreen modal (`UIModalPresentationFullScreen`) bọc trong `UINavigationController` từ `MenuButton -menuView:didTapItemType:` khi user bấm `"Hiện"` (`99001`) trên tin nhắn ảnh bị thu hồi.
- **Purpose:** Xem ảnh đã thu hồi với zoom 1x–4x, double-tap zoom 2.5x, lưu vào thư viện Ảnh hoặc sao chép ảnh vào clipboard.
- **Entry points:** Nhấn giữ bong bóng ảnh đã thu hồi → `"Hiện"`.
- **Exit points:** Nút `Đóng` ở thanh điều hướng trên trái.
- **Components:** `UIScrollView` (zoom 1.0–4.0) chứa `UIImageView` (`ScaleAspectFit`), double-tap gesture, dark navigation bar + 2 nút phải (`Lưu ảnh`, `Sao chép`).
- **Data source:** `UIImage *photo` trích từ `ZLModExtractPhotoFromChat(chat)` (từ live `ChatEntity` properties).
- **Permissions:** `UIImageWriteToSavedPhotosAlbum` cần quyền truy cập Photos (Add) của Zalo.
- **Error:** Callback `image:didFinishSavingWithError:contextInfo:` hiện toast `"Lỗi lưu ảnh: ..."` nếu bị từ chối quyền hoặc lỗi ghi đĩa.

---

### S10–S14 — 5 Bề mặt UI Tiêm Trực Tiếp vào Host Zalo (In-Place UI Surfaces)

| ID | Bề mặt UI | Host View / Controller | File:Line | Chức năng |
|---|---|---|---|---|
| **S10** | Row `"ZLMod Customize"` | `SettingUI40TableViewController` (và 4 fallback VC) | `ZLModSettings.m:400-758` | Mở S01 từ màn Cài đặt Zalo |
| **S11** | 4 Action trong Long-Press Menu + Chấm xanh `#0068FF` (`tag=0x5A1D`) | `InboxContextMenuManager`, `UXInboxMessageCell`, `ChatListItemCell` | `ZLModConversationMenu.m:525-727` | Bật/tắt Ẩn đã xem, Ẩn đang nhập, Chấm xanh chưa đọc, mở Private Note editor |
| **S12** | Nút `"Hiện"` (`99001`) / `"Ẩn"` (`99002`) + In-Place `UILabel` | `MenuButton` trong bong bóng chat (`BaseChatTVC`) | `ZLModAntiRecall.m:735-799, 1218-1365` | Hiện/Ẩn trực tiếp văn bản thu hồi trong cell |
| **S13** | Delay Send Undo Banner (`tag=0x5A1E`) | `ZLModActiveKeyWindow()` overlay | `ZLModUtilities.m:749-815` | Hiển thị `"Đang chờ gửi (Xs)..."` + nút đỏ `"Hủy gửi"` ở đáy màn hình |
| **S14** | Global Toast Pill (`ZLModShowToast`) | `ZLModActiveKeyWindow()` overlay | `ZLModConversationMenu.m:14-64` | Hiện thông báo dạng viên thuốc nổi phía trên đáy màn hình (2.4s) |

---

## PHẦN B — PHASE 4: COMPONENT AUDIT

| Loại | Component | File:Line | Purpose | Props / Inputs | State | Dependencies | Consumers | Side Effects | Problems | Reusable? | Duplicate? |
|---|---|---|---|---|---|---|---|---|---|---|---|
| **Notification** | `ZLModShowToast` | `ZLModConversationMenu.m:14-64` | Hiện pill toast 2.4s trên keyWindow | `NSString *message` | Tag view cố định trên `UIWindow` | `ZLModActiveKeyWindow()` | `Core`, `Bridge`, `Utilities`, `UI`, `AntiRecall`, `ConversationMenu` | Thêm/xóa subview trực tiếp vào `UIWindow` | **Đặt sai module** (nằm trong `ZLModConversationMenu.m` dù toàn bộ app gọi!); toast mới xóa đột ngột toast cũ; không hỗ trợ Safe Area khi bàn phím đang mở | Có (dùng chung toàn app) | Không |
| **Messaging / Overlay** | Delay Send Undo Banner | `ZLModUtilities.m:749-815` | Thanh đếm ngược + nút đỏ `"Hủy gửi"` | `sendId`, `duration` | `kZLModUndoBannerTag (0x5A1E)` + assoc `sendId` | `ZLModActiveKeyWindow()`, `ZLModDelaySendManager` | `ZLModDelaySendManager` | Gắn subview vào `UIWindow`, hủy gửi khi chạm | Chỉ hỗ trợ **1 banner** (tin gửi sau xóa mất nút hủy của tin trước); text không đếm ngược live; có thể bị bàn phím che khuất (`bottomY` không tính keyboard frame!) | Không | Không |
| **Modal / Form** | `ZLModPresentPrivateNoteEditor` | `ZLModUtilities.m:227-273` | Dialog tạo/sửa/xóa Private Note | `presenter`, `threadId`, `displayTitle`, `completion` | Text hiện tại trong `ZLModPrivateNotesStore` | `ZLModPrivateNotesStore`, `ZLModSafeIdHash` | `ZLModConversationMenu.m`, `ZLModUI.m` (S06) | Ghi/xóa file `ZLModNotes.plist` | Dùng `UIAlertController` + `UITextField` 1 dòng (không hỗ trợ multi-line); không báo lỗi khi `setNote:` trả `NO` | Có | Không |
| **Media** | `ZLModPhotoPreviewController` | `ZLModAntiRecall.m:801-954` | Xem ảnh thu hồi pinch-zoom + lưu/copy | `UIImage *photo`, `NSString *senderName` | Zoom scale của `UIScrollView` | `ZLModShowToast`, `UIImageWriteToSavedPhotosAlbum` | `ZLModAntiRecall.m:1311-1324` | Ghi ảnh vào Photos / Pasteboard | Không hỗ trợ pinch trên nhiều ảnh; dùng `self.view.bounds` chưa xử lý xoay màn hình (`viewWillLayoutSubviews` có update frame nhưng không reset zoom) | Có | Không |
| **Data Display** | Unread Blue Dot (`tag=0x5A1D`) | `ZLModConversationMenu.m:465-520` | Chấm xanh `#0068FF` đánh dấu chưa đọc cục bộ | `BOOL marked` | `UIView` tag `0x5A1D` trên cell | `ZLModConversationPolicyStore` | `UXInboxMessageCell`, `ChatListItemCell` | Thêm subview vào `contentView` của host cell | Frame cố định có thể lệch/đè badge của Zalo; `ChatListItemCell` không tồn tại trên bản `260401` | Có (2 cell class) | Không |
| **Settings / Layout** | Cloned Settings Cell & Fallback Cell | `ZLModSettings.m:56-105, 420-520` | Hàng `"ZLMod Customize"` trong Settings Zalo | Host cell model `_accountAndSecurityObject` | Static `gOurRow`, `gFallbackActive`, `gSectionSnapshot` | `ZLModSettingsViewController` | `SettingUI40TableViewController` | `memcpy` + `CFRetain` ivars; mutate mảng section của Zalo | Nguy cơ ARC/weak ivar corruption; fallback lệch row index delegate khác | Không | Có (2 cơ chế song song: clone model & fallback `UITableViewCell`) |
| **Layout / Navigation** | Tab Bar Glass & Theme Chrome Applier | `ZLModGlass.m:42-95`, `ZLModTheme.m:172-327` | Chỉnh `UITabBarAppearance` / `UINavigationBarAppearance` / `UIWindow` | `kZLModGlassTabBar`, `kZLModThemePreset`, `kZLModThemeTintHex` | Static `gSavedStandard`/`gSavedScrollEdge` (Glass) vs Associated Objects (Theme) | `UIKit` | `ZaloTabBarViewController`, tất cả `UIWindow` | Đột biến appearance của app host | **DUPLICATE / XUNG ĐỘT CHỨC NĂNG:** Cả hai cùng lưu và ghi đè `UITabBar.standardAppearance` & `scrollEdgeAppearance` không phối hợp! | Không | **CÓ** (Glass & Theme trùng quyền quản lý `UITabBarAppearance`) |
| **Settings / Form** | `ZLModBridgeViewController` cells | `ZLModUI.m:83-170` | Hiển thị & nhập cấu hình C-Bridge | `ZLModPreferences`, `ZLModBridgeManager` | Không reuse cell | `ZLModBridgeManager` | S02 | Cấp phát `UITableViewCell` mới mỗi lần render; post duplicate notification | Không dùng `dequeueReusableCellWithIdentifier:`; kích hoạt 3x reconnect khi lưu URL/Token | Không | **CÓ** (`CSaving` toggle xuất hiện trùng ở cả S01 dòng 994 và S02 dòng 153!) |
| **Modal / Messaging** | `ZLModPresentRecalledMessageContent` | `ZLModAntiRecall.m:980-1056` | Alert xem text thu hồi (kiểu cũ Build 8) | `id chat`, `id presenter` | Không | `ZLModAntiRecallStore` | **Không ai gọi (`__attribute__((unused))`)** | Không | **DEAD CODE** dư thừa từ Build 8 | Không | **CÓ** (trùng chức năng với In-Place Unhide & S04) |

---

## PHẦN C — PHASE 15: UX AUDIT

Tổng hợp các vấn đề UX có bằng chứng trực tiếp trong source code:

1. **Inconsistent Terminology (Thuật ngữ pha trộn Anh–Việt & sai thực tế):**
   - Trong `ZLModSettingsViewController` (`ZLModUI.m:925-1040`): tên section & title toàn tiếng Anh (`"Appearance & Theme"`, `"Per-Conversation Policies"`, `"Ghost Preview History"`, `"Delay Send Undo"`), còn subtitle & child buttons lại tiếng Việt (`"Chấm xanh chưa đọc"`, `"Bản sao cục bộ"`, `"Đang chờ gửi"`).
   - Tiêu đề `"Liquid Glass Tab Bar"` (`ZLModUI.m:926`) gây hiểu nhầm vì thực tế chỉ dùng blur material (`UIBlurEffect`), không phải iOS 26 Liquid Glass.
   - Footer C-Bridge (`ZLModUI.m:63`) nói *"CPairing sẽ tự động phát hiện trong Wi-Fi/LAN"*, nhưng người dùng phải tự gõ IP:Port thủ công.
   - Section `"Discord Webhook Relay"` (`ZLModUI.m:54, 230`) hứa hẹn *"nhận thông báo khẩn cấp"*, nhưng ngoài nút test ra không gửi thông báo nào.
2. **Missing Loading States & Double-Tap Vulnerability:**
   - S02 (`ZLModBridgeViewController`) khi bấm Ping Server, Test Webhook, Upload Settings chỉ bắn 1 toast text và **không có spinner**, không disable row trong lúc request đang chạy (timeout 5–8s) → user dễ bấm nhiều lần liên tiếp.
3. **Missing / Misleading Error States:**
   - Nhập mã màu `#HEX` sai trong `presentThemeTintEditor` (`ZLModUI.m:1192` → `ZLModTheme.m:152`) → im lặng xóa về `"Mặc định"`, không báo lỗi định dạng.
   - Thêm Quick Reply vượt quá 50 mẫu hoặc để trống (`ZLModUI.m:512`) → đóng alert im lặng, không báo lý do thất bại.
   - Lưu Private Note thất bại do fail-closed / Keychain (`ZLModUtilities.m:253`) → đóng alert im lặng, không báo toast lỗi.
   - Khi `accountScope == nil` (fail-closed), S03 (Policies), S04 (Ghost Preview History) và S06 (Private Notes) đều hiện **Empty State** (*"Chưa có..."*) y hệt như chưa có dữ liệu — người dùng không hề biết thực chất store đang bị khóa fail-closed!
   - Tại S04 (`ZLModUI.m:458-470`), khi giải mã thất bại, nút `"Sao chép"` vẫn sao chép chuỗi thông báo lỗi `"Không thể giải mã bản ghi này..."` vào clipboard.
4. **Opaque Identifiers in Lists (Khó nhận diện hội thoại):**
   - Trong S03 (`ZLModUI.m:331`), S04 (`ZLModUI.m:442`), và S06 (`ZLModUI.m:719`), mỗi hội thoại chỉ hiển thị mã băm ẩn danh kiểu `Cá nhân • h_a1b2c3d4` hoặc `Hội thoại: h_9f0e1d2c` — **KHÔNG hiển thị tên người/nhóm**, khiến user gần như không thể biết dòng nào ứng với người nào khi muốn quản lý policy, xem lịch sử thu hồi hay sửa ghi chú!
5. **Unnecessary Steps & Broken Discoverability:**
   - **Quick Reply Templates (S05):** Không có lối vào từ khung chat; nếu vào từ Cài đặt Zalo → bấm `"Chèn vào khung chat đang mở"` luôn thất bại và chỉ copy vào clipboard. User buộc phải nhớ mẹo lắc máy ngay trong khung chat → mở Dashboard → Quick Replies → chạm mẫu → chọn Chèn → đóng Dashboard!
   - **CSaving (S01/S02):** Có 2 công tắc trùng nhau ở S01 và S02, và **không hề cảnh báo người dùng rằng CSaving yêu cầu bật Anti-Recall mới hoạt động**!
   - **Destructive Action không xác nhận:** Ở S05 (`ZLModUI.m:590-594`), chạm `"Khôi phục mẫu câu mặc định"` **xóa sạch toàn bộ mẫu câu tùy chỉnh của user ngay lập tức mà KHÔNG hỏi xác nhận** (trong khi mọi hành động xóa khác ở S03/S04/S06/S01 đều có Alert xác nhận).
6. **Inconsistent Controls & Live Feedback Gaps:**
   - Delay Send Banner (`ZLModUtilities.m:774`) hiện tĩnh `"Đang chờ gửi (3s)..."`, không đếm ngược `3s → 2s → 1s`, nằm cố định ở `bottomY` (dễ bị bàn phím che khi vừa bấm gửi xong!), và gửi tin thứ 2 sẽ xóa mất nút hủy của tin thứ 1.
   - Private Note Editor dùng `UITextField` 1 dòng thay vì `UITextView` nhiều dòng.
   - Shake Gesture không có công tắc tắt và đụng chuẩn "Shake to Undo Typing" của iOS.
   - `ZLModLogViewerController` (S08) và `ZLModModuleStatusViewController` (S07) không có pull-to-refresh.
7. **Accessibility Problems:**
   - Không có `accessibilityLabel`, `accessibilityHint`, `accessibilityIdentifier` trên các custom views (Undo Banner, Toast, Blue Dot, Photo Preview buttons, Switches).
   - `ZLModLogViewerController` dùng kích thước font cố định `11.5pt` (`ZLModUI.m:840`), Undo Banner dùng `13.5pt` cố định (`ZLModUtilities.m:776,783`), Toast dùng font cố định — **không hỗ trợ Dynamic Type** (`UIFontMetrics` / `preferredFontForTextStyle:`).
   - Chấm xanh chưa đọc `10x10 pt` chỉ truyền đạt thông tin qua màu sắc (`#0068FF`), không có label accessibility cho VoiceOver.
