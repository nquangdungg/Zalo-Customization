# USER_FLOWS.md — Bản đồ Luồng Người Dùng Thực Tế

> Mọi luồng dưới đây được truy vết trực tiếp từ source code thực tế của ZLMod (`Sources/`, `Packaging/`, `.github/workflows/`). Các luồng không tồn tại (như Login riêng, Search riêng, Upload tệp riêng) không được bịa thêm.

---

## Flow 01 — Đóng gói & Cài đặt IPA (Offline Build & Sideload Flow)

```text
START (Developer / User có file IPA Zalo đã decrypt)
  → ACTION: Commit vào Decrypted/*.ipa hoặc chạy Packaging/package_ipa.py (hoặc kích hoạt GitHub Actions release.yml)
  → STATE CHANGE: Giải nén IPA vào thư mục staging tạm zlmod-package-*
  → API / CLI:
      1. make (biên dịch Sources/*.m → build/libZLMod.dylib + codesign -)
      2. Scripts/gates.sh (7 static gates)
      3. Packaging/package_ipa.py --input ... --output ... --bundle-id ... [--no-appex]
         - Sửa Info.plist (CFBundleIdentifier, CFBundleDisplayName)
         - Remap hoặc xóa PlugIns/*.appex (tự xóa appex có cryptid != 0)
         - Chép build/libZLMod.dylib → Payload/Zalo.app/Frameworks/
         - macho_injector.inject_rpath("@executable_path/Frameworks")
         - macho_injector.inject_load_dylib("@rpath/libZLMod.dylib")
         - Ad-hoc codesign (nếu có binary codesign)
         - Nén ZIP bảo toàn POSIX executable bits (0755 cho Mach-O)
         - Chạy validate_ipa() forensic check
  → RESPONSE: Xuất Zalo-ZLMod-*-noappex-unsigned.ipa & full-unsigned.ipa + SHA-256
  → UI UPDATE: Artifact / GitHub Release sẵn sàng; User dùng Sideloadly / xtool / AltStore / TrollStore ký & cài lên iPhone
  → END
```

- **Loading state:** Output log tuần tự trên CLI / GitHub Actions console.
- **Success state:** `[OK] Forensics validation passed`, xuất 2 file IPA unsigned.
- **Empty state:** Nếu không có `Decrypted/*.ipa` và không truyền `decrypted_ipa_url`, CI vẫn xuất `libZLMod.dylib` + `ZLMod-*.zip` và bỏ qua bước đóng gói IPA (`release.yml:137-141`).
- **Error state:** Dylib sai tên (`!= libZLMod.dylib`), bundle ID không nằm trong `compatibility.json` (khi không có `--allow-custom-bundle-id`), staging dir đã tồn tại, Mach-O padding gap không đủ, hoặc còn Mach-O `cryptid != 0` → raise exception, cleanup `work_dir` + `temp_zip` trong `finally`.
- **Retry / Cancellation:** Chạy lại lệnh CLI hoặc workflow dispatch; Ctrl-C sẽ dọn thư mục tạm trong `finally`.
- **Edge cases:**
  - `macho_injector.py:159` tiêm `LC_RPATH` với `cmdsize` không chia hết cho 8 (bug căn lề 64-bit).
  - Nếu máy người dùng đã cài bản cũ khác provisioning profile cùng bundle ID → iOS báo "Không thể cài đặt app".

---

## Flow 02 — Khởi động ứng dụng Zalo & Nạp ZLMod (App Launch Boot Flow)

```text
START (User chạm icon "Zalo ZLMod" trên iPhone)
  → ACTION: iOS dyld nạp Payload/Zalo.app/Zalo và @rpath/libZLMod.dylib
  → STATE CHANGE:
      1. ZLModEntry() constructor chạy → ZLModScheduleBootAfterLaunch()
      2. UIApplicationDidFinishLaunchingNotification (hoặc 1s/5s timer) → ZLModBootAsync() (background queue)
      3. ZLModBoot() (dispatch_once) kiểm tra [ZLModCompatibility hostSupported]
      4. Cài đặt session lifecycle observers + 11 module installers (mỗi module bọc @try/@catch)
      5. Ghi gModuleStatuses[module] = HOOK_INSTALLED / NOT_INSTALLED
      6. ZLModBridgeInstall() tự gọi [[ZLModBridgeManager shared] start] nếu đã cấu hình kZLModBridgeServerURL
  → API: Hàng loạt objc_runtime class_replaceMethod + [NSURLProtocol registerClass:] + tùy chọn WS connect /cbridge/ws
  → RESPONSE: Tất cả module báo kết quả vào ring-buffer & Documents/ZLMod.log
  → UI UPDATE: Sau khi boot xong, hiện toast 2.4s trên keyWindow:
               "✨ ZLMod Customize đã kích hoạt! Lắc máy hoặc vào Cài đặt để mở menu."
  → END
```

- **Loading state:** Không có spinner (chạy ngầm sau launch).
- **Success state:** Toast xanh/tối hiện ở đáy màn hình, 11 module ghi log `success`.
- **Empty state:** Khi lần đầu cài đặt, toàn bộ 16 feature toggle đều `OFF` (`NO`), theme `@""`, C-Bridge `Disconnected`.
- **Error state:**
  - Nếu `hostSupported == NO` → ghi log `compatibility: unsupported ...`, dừng hoàn toàn, không hiện toast.
  - Nếu 1 module ném `NSException` → bắt lỗi cục bộ, đặt `NOT_INSTALLED`, các module sau tiếp tục cài.
- **Retry / Cancellation:** Không có retry tự động sau khi `dispatch_once` hoàn tất; cần mở lại app (kill & relaunch).
- **Edge cases:** Nếu user đang mở sẵn màn Cài đặt Zalo trước khi hook xong, `ZLModSettings.m:762-782` chạy 1 lần quét view controller hierarchy để tiêm dòng Settings ngay.

---

## Flow 03 — Mở Bảng Điều Khiển ZLMod Customize (Settings Navigation Flow)

### Nhánh A: Qua Cài đặt gốc của Zalo
```text
START (User ở tab Cá nhân → chạm icon Cài đặt của Zalo)
  → ACTION: SettingUI40TableViewController load/appear → ZLModEnsureRow() chạy
  → STATE CHANGE: BFS tìm _accountAndSecurityObject → clone cell model (hoặc bật gFallbackActive) → chèn row "ZLMod Customize"
  → UI UPDATE: Hàng "ZLMod Customize" xuất hiện ngay cạnh "Tài khoản và bảo mật" (hoặc row 0 section 0)
  → ACTION: User chạm hàng "ZLMod Customize"
  → STATE CHANGE: tableView:didSelectRowAtIndexPath: bị chặn bởi ZLModHandleSelection()
  → UI UPDATE: Push ZLModSettingsViewController lên UINavigationController của Zalo
  → END
```

### Nhánh B: Qua Cử chỉ Lắc máy (Universal Shake Gesture)
```text
START (User đang ở bất kỳ màn hình nào trong Zalo)
  → ACTION: Lắc thiết bị iPhone
  → STATE CHANGE: [UIWindow motionEnded:UIEventSubtypeMotionShake withEvent:] gọi orig rồi gọi ZLModPresentSettingsUniversal()
  → UI UPDATE: Present modal FormSheet UINavigationController(rootViewController: ZLModSettingsViewController) kèm nút "Done"
  → END
```

- **Loading state:** Đồng bộ tức thì (tạo model table tại `viewDidLoad`/`viewWillAppear:`).
- **Success state:** Hiển thị đầy đủ 10 section cài đặt.
- **Empty state:** Không áp dụng (luôn có 10 section).
- **Error state:** Nếu `SettingUI40TableViewController` không có trên phiên bản Zalo mới → nhánh A không xuất hiện, user dùng nhánh B (Shake). Nếu đang mở sẵn `ZLModSettingsViewController` rồi lắc tiếp → bỏ qua không mở chồng (`ZLModSettings.m:632-636`).
- **Cancellation:** Nhấn Back (nhánh A) hoặc nút `Done` / vuốt xuống (nhánh B).
- **Edge cases:** Lắc máy khi đang có bàn phím + text có thể mở chồng hộp thoại "Hoàn tác nhập" của iOS.

---

## Flow 04 — Bật/Tắt Toggle Tính Năng & Đổi Theme / Liquid Glass

```text
START (User ở màn ZLModSettingsViewController)
  → ACTION: Bật/tắt UISwitch (hoặc chọn Theme Preset / nhập Custom Accent Tint #HEX)
  → STATE CHANGE:
      1. [[ZLModPreferences shared] setBool/setString:forKey:] ghi vào own + group NSUserDefaults + synchronize
      2. Post ZLModPrefsDidChangeNotification(object: key)
      3. Module lắng nghe phản ứng:
         - Glass: áp/gỡ UIBlurEffect trên UITabBarAppearance
         - Theme: lưu baseline lần đầu → áp overrideUserInterfaceStyle/tintColor/bar appearances → post ZLModThemeDidChangeNotification
         - Features: writeExternalValue / restoreExternalValue trên Zalo NSUserDefaults
         - Privacy/Firebase: nếu bật BlockFirebase → gọi setAnalyticsCollectionEnabled:NO...
         - DelaySend: nếu tắt → cancelAllPendingSendsWithReason:@"feature_disabled"
         - Ads / URIFilter / AntiRecall / Privacy Seen & Typing: đọc động lúc runtime
  → API: Local NSUserDefaults + UIKit appearance APIs
  → RESPONSE: Đồng bộ tức thì trong tiến trình
  → UI UPDATE: Bảng cài đặt reload giá trị mới; với Glass/Theme thấy hiệu ứng ngay; với ProfileMusic/GDrive/MoreTab/Ads view đã vẽ sẵn cần đóng/mở lại màn hình hoặc khởi động lại Zalo
  → END
```

- **Loading / Error / Empty states:** Không có loading; nhập mã màu Hex sai ở Custom Accent Tint bị im lặng xóa về `"Mặc định"` không có thông báo lỗi; tắt `Disable Firebase Collection` không bật lại Firebase trong phiên chạy hiện tại.
- **Edge cases:** Bật Theme rồi bật Glass rồi reset từng cái có thể phục hồi nhầm baseline appearance của nhau.

---

## Flow 05 — Tùy chỉnh Quyền Riêng Tư, Chấm Xanh Chưa Đọc & Ghi Chú Theo Từng Hội Thoại

```text
START (User ở màn danh sách cuộc trò chuyện Zalo)
  → ACTION: Nhấn giữ (long-press) một hội thoại
  → STATE CHANGE:
      1. InboxContextMenuManager -getActionsWithItem: chạy
      2. Trích threadId + convType ("user"/"group") + displayTitle
      3. Tạo ZLModMenuSession (TTL 120s), đọc trạng thái hiện tại từ ZLModConversationPolicyStore & ZLModPrivateNotesStore
      4. Chèn section 4 action (9101 Ẩn đã xem, 9102 Ẩn đang nhập, 9103 Chấm xanh chưa đọc, 9104 Ghi chú riêng tư)
  → UI UPDATE: Context menu Zalo hiện thêm nhóm thao tác ZLMod
  → ACTION: User chọn 1 trong 4 nút
  → STATE CHANGE:
      - 9101 / 9102 / 9103:
          contextMenu:didSelectActionId:forIdentifier: tiêu thụ session
          → cập nhật ZLModConversationPolicyStore (ghi atomic Documents/ZLModPolicies.plist)
          → post ZLModConversationPolicyDidChangeNotification
          → refresh tất cả UXInboxMessageCell & ChatListItemCell đang hiển thị (bật/tắt chấm xanh tag=0x5A1D)
      - 9104 (Ghi chú riêng tư):
          → mở UIAlertController có UITextField chứa ghi chú đã giải mã hiện tại
          → User nhập text & bấm "Lưu" (hoặc "Xóa ghi chú" / "Hủy")
          → ZLModPrivateNotesStore mã hóa AES-256-CBC + HMAC-SHA256 → ghi atomic Documents/ZLModNotes.plist
  → UI UPDATE: Chấm xanh bật/tắt tức thì (nút 9103) + Toast xác nhận (nút 9101/9102/9103)
  → END
```

- **Loading state:** Đồng bộ cục bộ (I/O đĩa nhỏ dưới `os_unfair_lock`).
- **Success state:** Toast hiển thị trạng thái mới; chấm xanh xuất hiện/biến mất ngay.
- **Empty state:** Trong `ZLModConversationPoliciesViewController` hiện `"Chưa có hội thoại nào được tùy chỉnh riêng"`; trong `ZLModPrivateNotesViewController` hiện `"Chưa có ghi chú riêng tư nào"`.
- **Error state:**
  - Nếu `accountScope == nil` (chưa nhận diện được tài khoản Zalo) → fail-closed, toast báo lỗi không lưu được.
  - Nếu session quá 120s mới bấm → session hết hạn, bỏ qua im lặng.
  - Nếu ghi chú lưu thất bại (`setNote:` trả `NO`, VD Keychain lỗi) → không có toast báo lỗi!
- **Cancellation:** Chạm ra ngoài menu hoặc bấm `"Hủy"` trên alert Ghi chú.
- **Edge cases:** Trên bản IPA `260401/708`, selector `contextMenu:didSelectActionId:forIdentifier:` không tồn tại nên flow chọn nút bị gãy hoàn toàn.

---

## Flow 06 — Chống Thu Hồi Tin Nhắn (Anti-Recall Capture & In-Place Unhide/Hide + Photo Modal)

### Giai đoạn A: Thu thập ngầm (Background Capture)
```text
START (kZLModAntiRecall == YES, tin nhắn đến hoặc load cuộc trò chuyện)
  → ACTION: Zalo gọi ConversationModel -didLoadChats:config: hoặc ChatDataManager -addChats:/addChat:
  → STATE CHANGE:
      1. ZLModSnapshotChatEntity() trích globalId, clientId, threadId, senderId, senderName, message, timestamp
      2. Lưu vào liveByKey (RAM, max 500) nếu không rỗng & không chứa "thu hồi"
      3. Post @"ZLModChatEntityArrivedNotification" (cho ZLModBridge CSaving)
  → ACTION (Khi đối phương thu hồi): Zalo gọi ConversationModel -updateDBWhenRecalledChats:completion:
  → STATE CHANGE:
      1. Tra liveByKey theo globalId / clientId (fallback text trên entity nếu chưa bị thay)
      2. Mã hóa AES-256-CBC + HMAC-SHA256 với AAD (accountScope|gid|cid|threadId|ts)
      3. Lưu atomic vào Documents/ZLModAntiRecall.plist (TTL 14 ngày, max 400 bản ghi/account)
      4. Gọi tiếp origIMP để Zalo cập nhật DB gốc bình thường
  → END
```

### Giai đoạn B: Người dùng bấm "Hiện" / "Ẩn" trực tiếp tại bong bóng chat
```text
START (User thấy ô "Tin nhắn đã được thu hồi" trong đoạn chat)
  → ACTION: Nhấn giữ vào bong bóng tin nhắn thu hồi
  → STATE CHANGE: MenuButton -showContextMenuViewWithMenuItemArray:hasReaction: kiểm tra isRecalled && có bản sao (hoặc ảnh)
  → UI UPDATE: Chèn nút "Hiện" (ID 99001, icon eye) nếu chưa hiện, hoặc "Ẩn" (ID 99002, icon eye.slash) nếu đang hiện
  → ACTION: User chạm "Hiện" (99001)
  → STATE CHANGE:
      1. MenuButton -menuView:didTapItemType: chặn itemType == 99001
      2. Giải mã nội dung từ ZLModAntiRecallStore (fallback live snapshot / _originTextRecallMsg)
      3. Thêm key (accountScope|threadId|gid|cid) vào gUnhiddenMessageKeys
      4. Gọi ZLModUpdateTextInViewHierarchy() lưu text gốc vào associated object & ghi đè UILabel.text + sizeToFit
      5. Gọi chat set_originTextRecallMsg: và [chat reloadCellIfNeed]
      6. Nếu ZLModExtractPhotoFromChat(chat) có ảnh → present modal ZLModPhotoPreviewController
  → UI UPDATE: Bong bóng chat đổi thành nội dung gốc (kèm ảnh fullscreen nếu là ảnh); Toast xác nhận
  → ACTION (Ẩn lại): Nhấn giữ → chọn "Ẩn" (99002) → xóa khỏi gUnhiddenMessageKeys → khôi phục UILabel gốc → reloadCellIfNeed
  → END
```

### Giai đoạn C: Xem qua Lịch sử Ghost Preview (Dashboard)
```text
START (Dashboard → Ghost Preview History)
  → ACTION: ZLModAntiRecallHistoryViewController đọc metadata các bản ghi còn hạn (< 14 ngày) của account hiện tại
  → UI UPDATE: Danh sách "Hội thoại h_xxx • Người gửi h_yyy — Lưu lúc yyyy-MM-dd HH:mm:ss"
  → ACTION: User chạm vào 1 dòng
  → STATE CHANGE: Gọi revealTextForEntryKey: giải mã AES+HMAC theo demand
  → UI UPDATE: UIAlertController hiển thị nội dung gốc + nút "Sao chép" / "Đóng"
  → END
```

- **Loading / Empty / Error states:**
  - Empty: `"Chưa có bản sao tin nhắn thu hồi nào"`.
  - Error: Không giải mã được (sai khóa/ngữ cảnh) → hiện `"Không thể giải mã bản ghi này (khóa hoặc ngữ cảnh không khớp)."`.
  - Trong `ZLModPhotoPreviewController`: có nút `Đóng`, `Lưu ảnh` (`UIImageWriteToSavedPhotosAlbum` + toast kết quả), `Sao chép` (`UIPasteboard.image`).
- **Edge cases:** Tin thu hồi trước khi app mở sẽ không có trong `liveByKey`; tin nhắn thật chứa chữ `"thu hồi"` bị bỏ lọt không lưu; ảnh thu hồi mất sau khi restart app.

---

## Flow 07 — Hoãn Gửi Tin Nhắn & Hủy Gửi (Delay Send Undo Flow)

```text
START (kZLModDelaySend == YES, user đang ở màn chat Zalo)
  → ACTION: User bấm Gửi tin nhắn
  → STATE CHANGE:
      1. ZAChatSendingManager -sendChat:checkUpload: bị hook chặn
      2. Tạo ZLModPendingSendItem (sendId = UUID, state = Pending, delay = 1..10s)
      3. Khởi tạo dispatch_source_t timer 1 lần trên main queue
  → UI UPDATE: Hiện thanh Undo Banner (tag=0x5A1E) ở đáy màn hình: "Đang chờ gửi (Xs)... [Hủy gửi]"
  → BRANCH 1 (User bấm "Hủy gửi" trước khi hết giờ):
      - Atomically chuyển state Pending → Cancelled dưới os_unfair_lock
      - Hủy timer, xóa item, gỡ banner, hiện toast "Đã hủy gửi tin nhắn"
      - KHÔNG gọi origIMP → tin không gửi lên mạng
  → BRANCH 2 (Hết giờ đếm ngược):
      - Atomically chuyển state Pending → Dispatching
      - Gỡ banner, gắn associated object kZLModDelaySendBypassAssocKey = @YES
      - Gọi origIMP (ZAChatSendingManager gửi tin thật)
      - Chuyển state → Dispatched (hoặc Failed nếu throw exception) & xóa item
  → BRANCH 3 (App vào background / terminate / đổi account / user tắt kZLModDelaySend):
      - Tự động hủy toàn bộ Pending items & gỡ banner (không gửi nhầm ngầm)
  → END
```

- **Loading / Error / Retry / Cancellation:** Không có retry khi `Failed`; hủy rõ ràng bằng nút đỏ `"Hủy gửi"`; không có toast khi auto-cancel do background.
- **Edge cases:** Gửi 2 tin liên tiếp trong cửa sổ delay → banner tin 2 xóa mất banner tin 1 nên không còn nút hủy tin 1!

---

## Flow 08 — Mẫu Câu Trả Lời Nhanh (Quick Reply Templates Flow)

```text
START (Dashboard → Quick Reply Templates)
  → ACTION 1 (+): Nhập nội dung mẫu trong UIAlertController → addQuickReply: → lưu ZLModQuickReplies.plist → reload
  → ACTION 2 (Edit): Vuốt xóa hoặc kéo thả đổi thứ tự → remove/moveQuickReply → lưu plist
  → ACTION 3 (Chạm 1 mẫu): Hiện ActionSheet (Chèn vào khung chat đang mở / Chỉnh sửa / Xóa / Đóng)
      - Chọn "Chèn vào khung chat đang mở":
          1. Thử gọi BaseChatTVC -fillChatBarWithText: trên [ZLModPrivacyContext activeChatController]
          2. Fallback tìm firstResponder UITextView/UITextField đang editable để nối text + báo delegate
          3. Fallback cuối: copy vào UIPasteboard + toast "Không có khung chat đang mở — đã sao chép vào bộ nhớ tạm"
  → ACTION 4 (Chạm "Khôi phục mẫu câu mặc định"): Gọi resetDefaults() → 3 mẫu mặc định tiếng Việt + toast
  → END
```

- **Empty state:** `"Chưa có mẫu câu nào (Nhấn + để thêm)"`.
- **Error state:** Nhập rỗng hoặc vượt 50 mẫu → lặng lẽ không thêm, không báo lỗi.
- **Edge cases:** Mở từ Zalo Settings (không phải Shake từ màn chat) → luôn rơi về copy clipboard vì `activeChatController == nil`.

---

## Flow 09 — C-Bridge: Cấu hình Server, Ping (CPairing), Đồng bộ (CDeploy), CSaving & Discord Webhook

### 9A. Cấu hình Local Server & Ping (CPairing)
```text
START (Dashboard → C-Bridge & Local Server)
  → ACTION: Chạm "Địa chỉ Server URL" hoặc "Bridge Token" → nhập trong UIAlertController → bấm "Lưu"
  → STATE CHANGE:
      1. [prefs setString:val forKey:...] → post notif #1 → ZLModBridgeManager reconnect #1
      2. [NSNotificationCenter postNotificationName:...] (BUG trùng lặp!) → reconnect #2
      3. [mgr reconnect] (BUG trùng lặp!) → reconnect #3
      4. Tạo NSURLSessionWebSocketTask tới ws(s)://<host>[:port]/cbridge/ws?token=...&account=...&userId=...
      5. Update status → Connecting → (khi mở hoặc nhận action:"connected") → Connected + bật heartbeat 20s + flush pendingMessages
  → ACTION: Chạm "Kiểm tra kết nối ngay (Ping Server)"
  → API: GET <serverUrl>/api/cbridge/health (HIỆN BỊ BUG: stringByAppendingPathComponent biến http:// → http:/!)
  → RESPONSE: Luôn lỗi URL không hợp lệ / không kết nối được trên URL chuẩn http(s)://
  → UI UPDATE: Toast lỗi "Lỗi kết nối: ..."
  → END
```

### 9B. CDeploy (Tải cài đặt lên & Nhận cấu hình từ Server)
```text
[Upload]
START → User chạm "Tải toàn bộ cài đặt lên Máy chủ ngay"
  → STATE CHANGE: Đọc 17 keys từ ZLModPreferences → build JSON {action:"cdeploy_upload", accountScope, settings, timestamp}
  → API: Gửi text frame qua WebSocket (nếu status == Connected)
  → RESPONSE: Callback hoàn tất gửi frame (không chờ server ACK; KHÔNG cập nhật kZLModBridgeLastSync)
  → UI UPDATE: Toast "Đã tải cài đặt lên máy chủ thành công!" hoặc "Không thể gửi dữ liệu lên máy chủ."

[Server Push]
START (Server gửi WS frame {action:"cdeploy_push", settings:{...}})
  → STATE CHANGE: Dispatch lên main queue → tìm ZLModTopPresenterViewController()
  → UI UPDATE: Hiện UIAlertController "C-Deploy: Đồng bộ từ máy chủ" với 2 nút [Từ chối] / [Chấp nhận]
  → BRANCH Chấp nhận:
      - applyRemoteSettings: ghi MỌI key trong settings (KHÔNG allowlist!) vào ZLModPreferences
      - Cập nhật kZLModBridgeLastSync ("HH:mm:ss dd/MM")
      - Post ZLModPrefsDidChangeNotification(object:@"*")
      - Gửi WS {action:"cdeploy_ack", status:"accepted", timestamp}
      - Toast "Đã đồng bộ cài đặt từ máy chủ thành công!"
  → BRANCH Từ chối:
      - Gửi WS {action:"cdeploy_ack", status:"rejected"}
  → END
```

### 9C. CSaving (Chuyển tiếp tin nhắn)
```text
START (kZLModBridgeSaving == YES VÀ BẮT BUỘC kZLModAntiRecall == YES!)
  → ACTION: Có tin nhắn load/đến trong Zalo → ZLModAntiRecall post ZLModChatEntityArrivedNotification
  → STATE CHANGE: ZLModBridgeManager đóng gói record (identityKey, threadId, msgId, cliMsgId, senderUid, senderName, text, msgType, timestampMs, isSelf) vào pendingMessages (cap 50, drop cũ nhất)
  → API: Nếu WS Connected → xả toàn bộ pendingMessages bằng 1 frame {action:"csaving", accountScope, messages:[...]}
  → RESPONSE:
      - Thành công: savedMessagesCount += batch.count
      - Thất bại: re-enqueue batch vào cuối pendingMessages (BUG: đảo thứ tự + bỏ qua cap 50!)
  → UI UPDATE: Không tự reload cell; khi user mở lại ZLModBridgeViewController thấy số "X tin"
  → END
```

### 9D. Discord Webhook Test
```text
START → Nhập Webhook URL → Chạm "Gửi thông báo kiểm tra tới Discord"
  → API: POST <webhookUrl> (JSON {"content": "🔔 **[ZLMod C-Bridge]** ..."})
  → RESPONSE: HTTP 200 hoặc 204 → thành công; khác → lỗi HTTP status/network
  → UI UPDATE: Toast kết quả (CHƯA CÓ luồng gửi cảnh báo tự động nào ngoài nút test này)
  → END
```

---

## Flow 10 — Đặt lại toàn bộ cài đặt & Đăng xuất / Đổi Tài khoản

### 10A. Reset All ZLMod Settings (`ZLModUI.m:1222-1239`)
```text
START (Dashboard → Diagnostics → "Reset All ZLMod Settings")
  → ACTION: User xác nhận nút đỏ "Đặt lại tất cả" trong UIAlertController
  → STATE CHANGE:
      1. [[ZLModDelaySendManager shared] cancelAllPendingSends]
      2. [[ZLModPreferences shared] resetAllPreferences] (khôi phục 6 external Zalo keys, xóa 21 ZLMod keys, bắn 21+1 notifications)
      3. [[ZLModThemeManager shared] resetTheme] (khôi phục baseline window/nav/tab bars)
      4. [[ZLModConversationPolicyStore shared] resetAllPolicies] (xóa sạch ZLModPolicies.plist của MỌI tài khoản!)
  → UI UPDATE: Reload Dashboard, hiện toast "Đã đặt lại toàn bộ cài đặt ZLMod"
  → END
```
> **Lưu ý hành vi không đồng nhất:** Reset All xóa sạch policies của **tất cả** tài khoản, nhưng **giữ nguyên** `ZLModAntiRecall.plist`, `ZLModNotes.plist`, `ZLModQuickReplies.plist`, và `ZLMod.log`!

### 10B. Đăng xuất / Đổi Tài khoản Zalo (`ZLModCore.m:262-301`)
```text
START (User đăng xuất hoặc đăng nhập tài khoản Zalo khác)
  → ACTION: AppDelegate -didLogout / -didLogin hoặc kNotifyDidLogoutAnimation
  → STATE CHANGE:
      1. ZLModInvalidateCachedAccountScope() + [ZLModPrivacyContext clearActiveContext]
      2. Post ZLModAccountDidChangeNotification trên main queue
      3. Listeners phản ứng:
         - ZLModAntiRecall: xóa live cache RAM + xóa gUnhiddenMessageKeys
         - ZLModDelaySendManager: hủy mọi tin nhắn đang hoãn gửi (reason="account_changed")
         - ZLModConversationMenu: xóa toàn bộ chấm xanh hoặc vẽ lại theo tài khoản mới
         - ZLModBridgeManager: gọi reconnect (gửi accountScope & userId mới lên Local Server)
         - ZLModSettingsViewController: reload bảng nếu đang hiển thị
  → END
```
