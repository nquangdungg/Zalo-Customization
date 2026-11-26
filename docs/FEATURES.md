# ZLMod — Danh sách tính năng & Trạng thái triển khai (4.0 / Build 11)

Tài liệu phản ánh trung thực trạng thái mã nguồn sau đợt tái kiến trúc toàn diện **Build 11** (`Resources/version.json`).

---

## 1. Appearance & Theme (`ZLModTheme.m`, `ZLModGlass.m`)

| Tính năng | Trạng thái | Cơ chế thực thi | Anchor / Lớp liên quan |
|---|---|---|---|
| **Blur Tab Bar** | ✅ Hoàn thiện (Build 11) | Áp dụng `UIBlurEffectStyleSystemUltraThinMaterial` thông qua `ZLModAppearanceCoordinator` (Zalo bật `UIDesignRequiresCompatibility=YES` nên không dùng `UIGlassEffect`). Tắt công tắc hoàn nguyên chính xác. | `ZaloTabBarViewController`, `ZLModAppearanceCoordinator` |
| **Theme Presets** (`classic_blue`, `dark_oled`, `pure_black`, `ocean_teal`) | ✅ Hoàn thiện (Build 11) | Phối hợp chung baseline duy nhất với Blur Tab Bar qua `ZLModAppearanceCoordinator`, hoàn nguyên nguyên trạng khi đặt lại. | `UIWindowScene`, `UINavigationBar`, `UITabBar` |
| **Custom Accent Tint (`#RRGGBB`)** | ✅ Hoàn thiện (Build 11) | Kiểm tra chặt chẽ định dạng `#RRGGBB`; trả `NO` và hiện thông báo lỗi nếu nhập sai (không tự ý xóa cấu hình đang dùng). | `ZLModThemeManager`, `kZLModThemeTintHex` |

---

## 2. Quyền riêng tư — Privacy Toàn cục & Từng cuộc trò chuyện (`ZLModPrivacy.m`, `ZLModPolicyStore.m`, `ZLModURIFilter.m`)

| Tính năng | Trạng thái | Cơ chế thực thi | Anchor / Lớp liên quan |
|---|---|---|---|
| **Ẩn trạng thái đang soạn tin (Hide Typing)** | ✅ Hoàn thiện | Hook `ChatDataManager -sendTypingWithType:...` và `ChatSocketCmdHelper +sendStatusTyping:...` (toàn cục & từng người). | `ChatDataManager`, `ChatSocketCmdHelper`, `BaseChatTVC` |
| **Kiểm soát đã xem (Control Seen / Read Receipts)** | ✅ Hoàn thiện | Chặn gửi seen cấp entity/talk item/batch/server, lọc danh sách `sendSeenLastMessageWithThreadIds:withMessageType:`, chặn ACK và FriendRequest seen. | `ChatSendSeenDataManager`, `ChatSocketCmdHelper`, `FriendRequestManager` |
| **Ngăn xếp ngữ cảnh chat (LIFO Active Context)** | ✅ Hoàn thiện (Build 11) | Stack LIFO trên `BaseChatTVC -zaloViewDidAppear:` / `-zaloViewWillDisappear:`, xử lý an toàn khi đẩy chat lồng nhau và tự xóa khi đổi tài khoản. | `BaseChatTVC`, `ZLModPrivacyContext` |
| **Chặn Tracking & Quảng cáo mạng** | ✅ Hoàn thiện (Build 11) | `NSURLProtocol` kết hợp hook `NSURLSessionConfiguration` (`default` & `ephemeral`), miễn trừ host C-Bridge, Discord & WebSocket `Upgrade`. | `ZLModBlockURLProtocol`, `NSURLSessionConfiguration` |
| **Tắt thu thập Firebase (Khôi phục live)** | ✅ Hoàn thiện (Build 11) | Tắt/bật lại được `FIRAnalytics`, `FIRPerformance`, `FIRCrashlytics` ngay khi đổi công tắc mà không cần khởi động lại. | `FIRAnalytics`, `FIRPerformance`, `FIRCrashlytics` |

---

## 3. Menu ngữ cảnh hội thoại & Chấm xanh (`ZLModConversationMenu.m`, `ZLModPolicyStore.m`)

| Tính năng | Trạng thái | Cơ chế thực thi | Anchor / Lớp liên quan |
|---|---|---|---|
| **Menu nhấn giữ hội thoại** | ✅ Hoàn thiện (Build 11) | Hook cả `InboxContextMenuManager` & `InboxContextMenuProvider` kèm chống chèn trùng, tìm template an toàn trong mảng lồng nhau, giới hạn 32 session. | `InboxContextMenuManager`, `InboxContextMenuProvider`, `ContextMenuViewModel` |
| **Chính sách theo từng hội thoại + Tên thật** | ✅ Hoàn thiện (Build 11) | Schema v3 lưu `titleCipher` mã hóa để hiển thị tên hội thoại thật trên màn hình `S03`, tương thích ngược v2. | `ZLModConversationPolicyStore` |
| **Đánh dấu chưa đọc cục bộ (Chấm xanh `#0068FF`)** | ✅ Hoàn thiện | Theo dõi yếu trên `UXInboxMessageCell` & `ChatListItemCell` (`tag=0x5A1D`), có nhãn VoiceOver. | `UXInboxMessageCell`, `ChatListItemCell` |

---

## 4. Event Bus & Chống thu hồi tin nhắn (`ZLModMessageTap.m`, `ZLModChatEntityAdapter.m`, `ZLModAntiRecall.m`)

| Tính năng | Trạng thái | Cơ chế thực thi | Anchor / Lớp liên quan |
|---|---|---|---|
| **Decoupled Message Tap Bus** | ✅ Hoàn thiện (Build 11) | Hook `ConversationModel` & `ChatDataManager`, chạy khi bất kỳ tính năng nào trong `{AntiRecall, CSaving, DiscordRelay}` đang bật; chuẩn hóa qua `ZLModChatEntityAdapter` và khử trùng lặp LRU 1000 khóa. | `ConversationModel`, `ChatDataManager`, `ZLModMessageTapBus` |
| **Anti-Recall văn bản & ảnh mã hóa trên đĩa** | ✅ Hoàn thiện (Build 11) | Lưu văn bản trong `ZLModAntiRecall.plist` và ảnh mã hóa trong `ZLModRecallPhotos/*.enc` (quota 20 MB, TTL 14 ngày, ghi bất đồng bộ) — tồn tại sau khi khởi động lại app; sửa rò rỉ `liveByKey` (`altKey`). | `ZLModAntiRecallStore`, `ZLModCryptoBox` |
| **Hiện / Ẩn trực tiếp trong bong bóng chat** | ✅ Hoàn thiện (Build 11) | Không sửa SQLite DB gốc; nhận diện placeholder chính xác (không nhận nhầm chữ `"thu hồi"` trong tin thường); dọn sạch associated label trên `[UITableViewCell/UICollectionViewCell prepareForReuse]`. | `MenuButton`, `ChatEntity`, `UITableViewCell`, `UICollectionViewCell` |
| **Xem ảnh thu hồi hỗ trợ Zoom** | ✅ Hoàn thiện (Build 11) | Trình xem ảnh hỗ trợ pinch-to-zoom, double-tap zoom, lưu vào Thư viện ảnh, xem trực tiếp từ cả chat lẫn lịch sử `S04`. | `ZLModPhotoPreviewViewController`, `ZLModHistoryPhotoViewerController` |

---

## 5. Tiện ích nhắn tin (`ZLModUtilities.m`)

| Tính năng | Trạng thái | Cơ chế thực thi | Anchor / Lớp liên quan |
|---|---|---|---|
| **Delay Send Undo FSM (1–10s)** | ✅ Hoàn thiện (Build 11) | FSM 5 trạng thái (`Pending`, `Cancelled`, `Dispatching`, `Dispatched`, `Failed`), hàng đợi đa tin nhắn, thanh Hủy đếm ngược trực tiếp tự tránh bàn phím, hiện toast khi lỗi gửi, tự hủy khi xuống nền / đổi tài khoản. | `ZAChatSendingManager` |
| **Quick Reply Templates + Nút chèn nhanh** | ✅ Hoàn thiện (Build 11) | Lưu riêng theo tài khoản (di chuyển từ v1), chống trùng, giới hạn 50 mẫu, nút chọn nhanh `⚡` ngay trong `BaseChatTVC`, chỉ chèn vào khung nhập (không bao giờ tự gửi). | `BaseChatTVC`, `ZLModQuickReplyStore` |
| **Ghi chú riêng tư mã hóa nhiều dòng** | ✅ Hoàn thiện (Build 11) | Trình soạn thảo `UITextView` nhiều dòng, schema v3 lưu tên hội thoại thật mã hóa, hiển thị cảnh báo `ZLModStorageHealth` nếu Keychain chưa sẵn sàng. | `ZLModPrivateNotesStore`, `ZLModPrivateNoteEditorViewController` |

---

## 6. C-Bridge & Discord Webhook Relay (`ZLModBridge.m`, `ZLModUI.m`)

| Tính năng | Trạng thái | Cơ chế thực thi | Anchor / Lớp liên quan |
|---|---|---|---|
| **CPairing & Bonjour LAN Auto-Discovery** | ✅ Hoàn thiện (Build 11) | Sửa URL health check bằng `NSURLComponents`, quét tự động máy chủ LAN qua `NSNetServiceBrowser` (`_zlmod-cbridge._tcp.` / `_http._tcp.`), gửi token qua header `Authorization: Bearer`. | `NSURLSessionWebSocketTask`, `NSNetServiceBrowser` |
| **WebSocket FSM 4 trạng thái** | ✅ Hoàn thiện (Build 11) | `Disconnected/Connecting/Connected/Closing` + `connectionEpoch` chống stale task + backoff `2s..30s` + heartbeat `20s` / pong timeout `10s` + đóng sạch khi nền / `invalidateAndCancel` khi dừng. | `ZLModBridgeManager` |
| **CSaving (Độc lập với Anti-Recall)** | ✅ Hoàn thiện (Build 11) | Nhận tin từ `ZLModMessageTapBus`, khử trùng 500 khóa, hỗ trợ `chat.undo`, khi gửi lỗi chèn lô cũ trước tin mới để bảo toàn thứ tự (cap 50). | `ZLModMessageTapBus`, `ZLModBridgeManager` |
| **CDeploy (Đồng bộ cài đặt an toàn)** | ✅ Hoàn thiện (Build 11) | Allowlist chặt `remoteDeployAllowedKeys` (cấm ghi đè bí mật/Server URL), xếp hàng khi presenter bận, luôn gửi `cdeploy_ack`, cập nhật `lastSyncDateString` khi cả đẩy lên lẫn nhận xuống. | `ZLModPreferences`, `ZLModBridgeManager` |
| **Discord Webhook Relay tự động** | ✅ Hoàn thiện (Build 11) | Tự động chuyển tiếp tin nhắn mới & tin thu hồi (kèm nội dung gốc) từ `ZLModMessageTapBus`, chỉ chấp nhận domain chính thức `https://*.discord(app).com/api/.../webhooks/...`, giới hạn tốc độ `1.5s` / HTTP `429 Retry-After`, retry tối đa 2 lần, không lộ URL trong log. | `ZLModSecretStore`, `ZLModBridgeManager` |

---

## 7. Chặn quảng cáo, Khôi phục tính năng & Bảng điều khiển (`ZLModAds.m`, `ZLModFeatures.m`, `ZLModSettings.m`, `ZLModUI.m`)

| Tính năng | Trạng thái | Cơ chế thực thi | Anchor / Lớp liên quan |
|---|---|---|---|
| **Ẩn quảng cáo (Khôi phục live)** | ✅ Hoàn thiện (Build 11) | Theo dõi ad views bằng `NSHashTable` yếu và hoàn nguyên `hidden`/`alpha`/`userInteractionEnabled` ngay khi tắt. | `ZInstantFeedAdsView`, `LocationOAAdsCell` |
| **Khôi phục Profile Music / GDrive / More Tab** | ✅ Hoàn thiện (Build 11) | Dùng chỉ mục selector 1 lượt, hoàn nguyên đầy đủ key App Group khi tắt hoặc reset. | `ZLExtendedProfileMusic`, `ProfileMusicItemModel` |
| **ZLMod Customize Entry & Dashboard (S01–S08)** | ✅ Hoàn thiện (Build 11) | Trạng thái theo từng VC (không `memcpy`/`CFRetain`), nút dự phòng trên `navigationItem` không lệch chỉ số bảng, lắc máy an toàn với Undo Typing + công tắc tắt; UI 8 màn hình đầy đủ banner `ZLModStorageHealth`, spinner, pull-to-refresh. | `SettingUI40TableViewController`, `ZLModSettings`, `ZLModUI` |

---

## 8. Ranh giới không triển khai (Non-Goals)

Original Photo mặc định, mở khóa ZCloud Premium, gian lận quyền Admin/Trưởng nhóm, bỏ qua giới hạn tải video/TTL máy chủ — các cơ chế server-authoritative cố ý không triển khai.
