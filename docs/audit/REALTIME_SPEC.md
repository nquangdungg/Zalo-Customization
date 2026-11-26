# REALTIME_SPEC.md — Hệ thống Tin nhắn (Phase 5) & Realtime / Event System (Phase 6)

> **Phạm vi thực tế:** ZLMod không tự triển khai giao thức mạng của Zalo (không có SDK Zalo riêng như `zapind`). Toàn bộ luồng chat là **chặn / quan sát / biến đổi tại runtime** bên trong tiến trình Zalo iOS gốc thông qua Objective-C method swizzling, kết hợp với **1 kênh WebSocket thời gian thực (`ZLModBridgeManager`)** và **bus sự kiện nội bộ (`NSNotificationCenter`)**.

---

## PHẦN A — PHASE 5: MESSAGE / CHAT SYSTEM DEEP-DIVE

### 1. Incoming Message Pipeline (Zalo → ZLMod Anti-Recall → C-Bridge CSaving → UI)

```text
[Zalo Server / Socket / Local SQLite]
  │
  ▼ (Zalo nội bộ dựng ChatEntity)
  ├─► ConversationModel -didLoadChats:config:               (ZLModAntiRecall.m:1067)
  ├─► ChatDataManager -addChats:byUserId:willAlert:fromSrc: (ZLModAntiRecall.m:1134)
  └─► ChatDataManager -addChat:byUserId:willAlert:fromSrc:  (ZLModAntiRecall.m:1149)
        │
        ├─► [GATE BUG!] Chỉ chạy nếu kZLModAntiRecall == YES!
        │
        ▼ (Parser / Normalizer: ZLModSnapshotChatEntity, ZLModAntiRecall.m:530-629)
        ├─ Trích globalId (globalId / globalMsgId), clientId (clientId / cliMsgId)
        ├─ Trích threadId (threadId / tuid), senderId (senderId / fuid), senderName (senderName / displayname)
        ├─ Trích message (lọc bỏ nếu rỗng, prefix "Tin nhắn đã được thu hồi", hoặc CHỨA "thu hồi"!)
        ├─ Trích timestamp (time / createTime)
        │
        ├─► [Store 1: RAM Live Cache] ZLModAntiRecallStore.cacheLiveSnapshot
        │     └─ Lưu vào liveByKey[scope:g_<gid>] & liveByKey[scope:c_<cid>] (cap 500 trên liveOrder; altKey bị LEAK!)
        │
        └─► [Event Bus] postNotificationName:@"ZLModChatEntityArrivedNotification"
              │           object:chatEntity userInfo:@{@"threadId": tid}
              ▼ (Đồng bộ trên chính thread của Zalo!)
              ZLModBridgeManager -handleIncomingChatNotification: → enqueueMessageForSaving:
                ├─ Kiểm tra kZLModBridgeSaving == YES
                ├─ Trích lại properties (KHÔNG dùng lại kết quả parser của AntiRecall; thiếu fallback selectors!)
                ├─ Phân loại msgType bằng substring ([Hình ảnh]/[Nhãn dán]/[Tin nhắn thoại]/[Tệp tin])
                ├─ Tạo identityKey = "<senderId>:<threadType>:<tid>:<msgId|cliMsgId>" (KHÔNG dedup cục bộ!)
                ├─ Đẩy vào pendingMessages (cap 50, drop cũ nhất)
                └─ Nếu WS Connected → flushPendingMessages() → WS JSON {action:"csaving", messages:[...]}
                      └─► Local Server (zalo-meet-bot SQLite — server code ngoài repo: UNKNOWN — NEEDS VERIFICATION)
```

### 2. Recall / Undo Message Pipeline (Incoming Recall Event → Encrypted Archive → In-Place UI)

```text
[Zalo Server gửi sự kiện thu hồi]
  ▼
ConversationModel -updateDBWhenRecalledChats:completion: (ZLModAntiRecall.m:1082)
  ├─ Nếu kZLModAntiRecall == YES:
  │    ├─ Duyệt recalledChats (NSArray / NSSet / single ChatEntity)
  │    ├─ Tra ZLModLiveSnapshot theo globalId / clientId trong liveByKey
  │    ├─ Fallback: đọc text trên chính entity nếu chưa chứa "thu hồi"/"recalled"
  │    ├─ Mã hóa AES-256-CBC + HMAC-SHA256 (AAD = scope|gid|cid|tid|ts)
  │    └─ Ghi atomic vào Documents/ZLModAntiRecall.plist (TTL 14 ngày, max 400/account)
  └─ Gọi origIMP (cho Zalo cập nhật SQLite & UI thành "Tin nhắn đã được thu hồi")

[User tương tác UI trên bong bóng thu hồi]
  ├─ ChatEntity -_getRecalledMsgPreviewFromSource: (ZLModAntiRecall.m:1167)
  │    └─ Nếu unhidden → trả văn bản gốc; nếu chưa → trả preview gắn nhãn "[ZLMod Bản sao cục bộ — tin nhắn gốc đã thu hồi]"
  ├─ ChatEntity -message (ZLModAntiRecall.m:1196)
  │    └─ Nếu key có trong gUnhiddenMessageKeys → trả văn bản giải mã (không sửa SQLite)
  ├─ MenuButton -showContextMenuViewWithMenuItemArray:hasReaction: (ZLModAntiRecall.m:1224)
  │    └─ Chèn nút "Hiện" (99001) hoặc "Ẩn" (99002)
  └─ MenuButton -menuView:didTapItemType: (ZLModAntiRecall.m:1277)
       ├─ 99001 (Hiện): thêm vào gUnhiddenMessageKeys → sửa UILabel.text + assoc origText + sizeToFit
       │                → set_originTextRecallMsg: → reloadCellIfNeed → nếu có ảnh mở ZLModPhotoPreviewController
       └─ 99002 (Ẩn):   xóa khỏi gUnhiddenMessageKeys → khôi phục UILabel từ assoc origText → reloadCellIfNeed
```

### 3. Outgoing Message Pipeline (UI → Delay Send Undo FSM → Zalo Send)

```text
[User bấm Gửi trên khung chat Zalo (BaseChatTVC)]
  │ (Nếu dùng Quick Reply trước đó: ZLModQuickReplyStore -insertTemplateIntoComposer:
  │  chỉ điền vào BaseChatTVC -fillChatBarWithText: hoặc firstResponder, KHÔNG tự gửi)
  ▼
ZAChatSendingManager -sendChat:checkUpload: (ZLModUtilities.m:833)
  ├─ Nếu có assoc kZLModDelaySendBypassAssocKey == @YES HOẶC kZLModDelaySend == NO:
  │    └─ Gọi thẳng origIMP (Zalo gửi ngay bình thường)
  └─ Nếu kZLModDelaySend == YES:
       ├─ Tạo ZLModPendingSendItem (UUID, state=Pending, delay=1..10s, timer trên main queue)
       ├─ Hiện Undo Banner (tag=0x5A1E) ở đáy keyWindow: "Đang chờ gửi (Xs)... [Hủy gửi]"
       ├─ [Bấm Hủy / Background / Terminate / Account Change / Disable Toggle]:
       │    └─ Atomic Pending → Cancelled → hủy timer → gỡ banner → KHÔNG gọi origIMP
       └─ [Hết giờ timer]:
            └─ Atomic Pending → Dispatching → gỡ banner → gắn bypass assoc → gọi origIMP → Dispatched / Failed
```

### 4. Typing & Seen Outgoing Suppression Pipeline

```text
[User gõ phím trong BaseChatTVC]
  ├─ ChatDataManager -sendTypingWithType:toUserId:messageType:isE2eeChat: (ZLModPrivacy.m:317)
  │    └─ Kiểm tra global kZLModHideTyping || per-chat hideTyping(toUserId) → return NO (drop) hoặc gọi origIMP
  └─ ChatSocketCmdHelper +sendStatusTyping:withCommand:withSubCommand:withDestType:withGlobalMessageId: (ZLModPrivacy.m:337)
       └─ Kiểm tra global kZLModHideTyping || per-chat hideTyping(activeThreadId) → return 0 (drop) hoặc gọi origIMP

[User mở/đọc tin nhắn trong BaseChatTVC]
  ├─ BaseChatTVC -zaloViewDidAppear: / -zaloViewWillDisappear: → cập nhật ZLModPrivacyContext
  ├─ sendSeenMessageWithChatEntity: / TalkTableItem: / Messages: / _sendSeenMessageWithSeenData:
  │    └─ Kiểm tra global kZLModHideSeen || per-chat hideSeen(tid) → drop hoặc gọi origIMP
  ├─ ChatSendSeenDataManager -sendSeenLastMessageWithThreadIds:withMessageType: (ZLModPrivacy.m:223)
  │    └─ Nếu global hideSeen → drop; ngược lại LỌC bỏ từng threadId có hideSeen=YES rồi gửi các thread còn lại!
  ├─ ChatSendSeenDataManager -sendSeenServer / -forceSendSeenServer (ZLModPrivacy.m:201, 212)
  │    └─ Drop nếu kZLModHideReadReceipts || hideSeen(activeThreadId)
  ├─ ChatSocketCmdHelper +sendSeenChatACK: / +sendSeenGroupChatACKByData: (ZLModPrivacy.m:257, 268)
  │    └─ Drop nếu kZLModHideReadReceipts || hideSeen(threadId)
  └─ FriendRequestManager -sendSeenCurrentUnreadFriendRequest:... (ZLModPrivacy.m:283, 294)
       └─ Drop nếu kZLModHideSeen
```

### 5. Ma trận Khả năng Chat/Messaging thực sự tồn tại trong ZLMod

| Khả năng | Thực tế trong ZLMod | Chi tiết & Bằng chứng |
|---|---|---|
| **Message model** | Đọc động từ `ChatEntity` của Zalo | `globalId`/`globalMsgId`, `clientId`/`cliMsgId`, `message`, `senderName`/`displayname`, `senderId`/`fuid`, `threadId`/`tuid`, `time`/`createTime`, `isOwner`, `isChatGroup`, `_originTextRecallMsg`, `isRecalled` |
| **Conversation model** | Đọc động từ `ConversationModel`, `UXInboxMessageCellItem`, `BaseChatTVC` | Chỉ lấy `threadId`, `convType` (`user`/`group`), `displayTitle` |
| **Sender / Receiver** | Chỉ đọc `senderId`/`senderName` và `tuid`/`threadId` | Không truy xuất đầy đủ danh bạ hay avatar |
| **Message ID / Conversation ID** | `int64_t globalId`, `int64_t clientId`; `NSString *threadId` | AntiRecall dùng `g_<gid>` & `c_<cid>`; CSaving ghép `identityKey` |
| **Timestamp** | `NSTimeInterval` (giây) ở AntiRecall; `timestampMs` (ms) ở CSaving | Có rủi ro lệch đơn vị nếu `createTime` trả giây thay vì ms (`ZLModBridge.m:377`) |
| **Message type** | Chỉ nhận diện text + ảnh (AntiRecall) và heuristic chuỗi 5 loại (CSaving) | CSaving thiếu `Undo`; AntiRecall chỉ khôi phục ảnh nếu ảnh còn sống trong RAM/cache `ChatEntity` |
| **Attachments** | Không quản lý download/upload attachment | Chỉ trích ảnh có sẵn trên `ChatEntity` khi xem lại ảnh thu hồi (`originalImage`/`hdLocalFilePath`/`localFilePath`/`photoPath`) |
| **Reactions / Reply / Edit / History / Pagination** | **KHÔNG CAN THIỆP** (hoàn toàn do app Zalo gốc xử lý) | Không có hook nào cho reactions, reply, edit, history paging |
| **Delete / Recall** | **CÓ (Anti-Recall)** | Chặn/lưu trước khi thu hồi ở `updateDBWhenRecalledChats:completion:` |
| **Unread** | **CÓ (Local Mark Unread)** | Chấm xanh `#0068FF` cục bộ, không gửi server, không tự tắt khi mở hội thoại |
| **Typing** | **CÓ (Hide Typing)** | Chặn gửi typing toàn cục & theo hội thoại |
| **Realtime** | **CÓ (C-Bridge WS + Host hooks)** | Xem Phần B bên dưới |
| **Retry / Failed message** | Chỉ có ở CSaving WS (`re-enqueue` bị bug) | DelaySend không có retry khi `origIMP` ném exception |
| **Duplicate prevention** | AntiRecall ghi đè theo khóa `g_<gid>`/`c_<cid>`; **CSaving KHÔNG dedup cục bộ** | Tin đến qua cả `addChat:` và `didLoadChats:` bị đẩy trùng lên WS |

---

## PHẦN B — PHASE 6: REALTIME & EVENT SYSTEM AUDIT

Hệ thống có **3 cơ chế realtime / sự kiện**:
1. **WebSocket client (`ZLModBridgeManager`, `Sources/ZLModBridge.m`)** — Không có SSE, không có HTTP polling.
2. **In-Process Event Bus (`NSNotificationCenter`)** — 6 custom notifications + 4 system/host notifications.
3. **GCD Timers (`dispatch_source_t` & `dispatch_after`)** — Boot timers, Heartbeat 20s, Reconnect 5s, DelaySend timers.

### 1. Bảng Chi tiết Toàn bộ Events & Listeners

| Event | Source | Payload | Listener(s) | Processor | State Update | UI Effect | Persistence | Error Handling |
|---|---|---|---|---|---|---|---|---|
| **WS `connected`** | Local Server (`/cbridge/ws`) | `{"action":"connected"}` | `ZLModBridgeManager -listenForMessages` | `handleIncomingTextMessage:` (`ZLModBridge.m:248`) | `status = Connected` | Post `ZLModBridgeStatusDidChangeNotification` → reload S02 | Không | JSON lỗi bỏ qua im lặng |
| **WS `pong`** | Local Server | `{"action":"pong"}` | `ZLModBridgeManager -listenForMessages` | `handleIncomingTextMessage:` (`ZLModBridge.m:242`) | `lastPingLatencyMs = (now - lastPingSentTime)*1000` | **BUG:** Không reload S02 vì `_status` đã là `Connected`! | Không | Không có pong timeout |
| **WS `cdeploy_push`** | Local Server | `{"action":"cdeploy_push","settings":{...}}` | `ZLModBridgeManager -listenForMessages` | `handleDeployPushSettings:` (`ZLModBridge.m:263`) | Nếu user Chấp nhận → ghi toàn bộ keys (không allowlist!) + `lastSyncDateString` | Hiện `UIAlertController` xác nhận + Toast | `ZLModPreferences` | Nếu `presenter == nil` hoặc đang bận modal → rơi im lặng, không gửi `cdeploy_ack` |
| **WS `didOpenWithProtocol:`** | `NSURLSessionWebSocketDelegate` | protocol string | `ZLModBridgeManager` (`ZLModBridge.m:588`) | Set `Connected`, gửi `ping` ngay, gọi `flushPendingMessages` | `status = Connected` | Reload S02 | Không | Không |
| **WS `didCloseWithCode:` / `receiveMessage` error** | `NSURLSessionWebSocketTask` | closeCode / `NSError` | `ZLModBridgeManager` (`ZLModBridge.m:167, 595`) | Set `Disconnected`, hủy heartbeat, gọi `scheduleReconnect` (5s) | `status = Disconnected` | Reload S02 | Không | **BUG RACE:** Không kiểm tra task có phải `self.webSocketTask` hiện tại không! |
| **Timer Heartbeat (20s)** | `dispatch_source_t` trên main queue | None | `ZLModBridgeManager` (`ZLModBridge.m:183`) | `sendHeartbeatPing` → gửi WS `{"action":"ping","timestamp":...}` | `lastPingSentTime = now` | Không | Không | Bỏ qua nếu `status != Connected` |
| **`ZLModChatEntityArrivedNotification`** | `ZLModAntiRecall.m:624` *(chỉ khi AntiRecall=ON!)* | `object: chatEntity`, `userInfo: {threadId}` | `ZLModBridgeManager` (`ZLModBridge.m:73`) | `enqueueMessageForSaving:` → `flushPendingMessages` | Thêm vào `pendingMessages`, gửi WS `csaving` | Không tự reload S02 | RAM buffer (mất khi tắt app) | Send fail re-enqueue sai thứ tự & phá cap 50 |
| **`ZLModPrefsDidChangeNotification`** | `ZLModPreferences.m` + `ZLModBridge.m:310` + *(trùng lặp)* `ZLModUI.m:174,204,222,242` | `object: key` hoặc `@"*"` | `ZLModPrivacy`, `ZLModFeatures`, `ZLModGlass`, `ZLModTheme`, `ZLModDelaySendManager`, `ZLModBridgeManager` | Đồng bộ cờ external, áp/gỡ Glass/Theme, hủy DelaySend, tắt Firebase, reconnect Bridge | Cập nhật trạng thái module tương ứng | Đổi giao diện Glass/Theme, gỡ Undo banner | `NSUserDefaults` | Nhiều observer nhận 21+1 notif khi `resetAllPreferences` |
| **`ZLModAccountDidChangeNotification`** | `ZLModCore.m:267` (từ `didLogout`, `didLogin`, `kNotifyDidLogoutAnimation`) | `object: nil` | `ZLModAntiRecall`, `ZLModDelaySendManager`, `ZLModConversationMenu`, `ZLModBridgeManager`, `ZLModSettingsViewController` | Xóa cache live/unhidden, hủy pending sends, refresh chấm xanh, reconnect WS, reload S01 | Xóa sạch state RAM của account cũ | Cập nhật S01 & Inbox cells | Không | Chạy trên main queue |
| **`ZLModConversationPolicyDidChangeNotification`** | `ZLModPolicyStore.m:113, 237` | `userInfo: {ZLModPolicyThreadIdKey}` | `ZLModConversationMenu`, `ZLModSettingsViewController` | Refresh toàn bộ `gVisibleCells`, rebuild model S01 | Không (đã lưu plist trước) | Bật/tắt chấm xanh tức thì, cập nhật count trên S01 | `ZLModPolicies.plist` | Main queue |
| **`ZLModThemeDidChangeNotification`** | `ZLModTheme.m:143, 160, 167` | `object: nil` | `ZLModSettingsViewController` (`ZLModUI.m:901`) | `externalStateDidChange:` | Rebuild model S01 | Cập nhật label Preset/Tint ở S01 | `ZLModPreferences` | Chỉ reload khi S01 đang hiển thị |
| **`ZLModBridgeStatusDidChangeNotification`** | `ZLModBridge.m:154` | `object: nil` | `ZLModBridgeViewController` (`ZLModUI.m:25`) | `bridgeStateChanged` | Không | Reload S02 *(S01 KHÔNG lắng nghe!)* | Không | Main queue |
| **UIKit Lifecycle (`DidFinishLaunching`, `DidBecomeActive`, `DidEnterBackground`, `WillTerminate`)** | iOS `UIApplication` | None | `ZLModCore`, `ZLModBridge`, `ZLModTheme`, `ZLModDelaySendManager` | Boot dylib; reconnect WS khi foreground; refresh Theme; hủy mọi DelaySend khi background/terminate | Tùy module | Gỡ Undo Banner, áp Theme | Không | `ZLModBridge.handleAppDidEnterBackground` là hàm rỗng! |

### 2. Kiểm tra lỗi Realtime (Phase 6 Checklist)

| Hạng mục kiểm tra | Kết quả audit | Bằng chứng (`file:line`) |
|---|---|---|
| **Duplicate listeners / Duplicate events** | **CÓ LỖI** | (1) `ZLModUI.m:174, 204, 222, 242` tự post `ZLModPrefsDidChangeNotification` sau khi `ZLModPreferences` đã post; (2) `ZLModUI.m:206, 224` gọi thêm `[mgr reconnect]` lần thứ 3; (3) `ZLModPreferences.m:181-183` post 21 notif lẻ + 1 notif `@"*"` khi reset; (4) `ZLModBridge.m:310` post `@"*"` sau khi vòng `for` ở dòng 296-301 đã post từng key. |
| **Missing listeners** | **CÓ LỖI** | (1) `ZLModSettingsViewController` (S01) không lắng nghe `ZLModBridgeStatusDidChangeNotification` và `ZLModPrefsDidChangeNotification`; (2) `ZLModBridgeManager -handlePrefsChanged:` không lắng nghe `object:@"*"` (nên Reset All không tự disconnect nếu chỉ dựa vào `"*"`); (3) `ZLModBridgeManager` không có listener độc lập cho tin nhắn đến (bị phụ thuộc vào `ZLModAntiRecall`). |
| **Stale listeners / Cleanup** | **CƠ BẢN ỔN (có 1 điểm yếu)** | Các VC (`ZLModBridgeViewController`, `ZLModSettingsViewController`) có `removeObserver:self` trong `dealloc`; các singleton sống suốt vòng đời app nên không remove; tuy nhiên `NSURLSession` trong `ZLModBridgeManager` giữ strong reference tới `delegate:self` (`ZLModBridge.m:53` — chấp nhận được với singleton, nhưng không có `invalidateAndCancel` ở `stop`). |
| **Race conditions** | **NGHIÊM TRỌNG** | (1) Stale `webSocketTask` bị cancel trong `reconnect` trả lỗi về `receiveMessageWithCompletionHandler:` ghi đè trạng thái socket mới về `Disconnected` (`ZLModBridge.m:134-172`); (2) `ZLModBridgeManager` truy cập `status`, `savedMessagesCount`, `webSocketTask` không khóa giữa thread nền của Zalo (`enqueueMessageForSaving:`) và main queue; (3) `ZLModBoot()` chạy trên background queue gọi các module UIKit. |
| **Reconnect bugs** | **NGHIÊM TRỌNG** | (1) Fixed `5.0s` `dispatch_after` không có backoff, không có cờ chống lịch hẹn trùng (khi cả `receiveMessage` error và `didCloseWithCode` cùng bắn, cả 2 đều gọi `scheduleReconnect` → 2 timer cùng nổ sau 5s!); (2) `handleAppDidEnterBackground` rỗng nên socket chết ngầm khi tắt màn hình; (3) Không phát hiện half-open connection (không có pong timeout). |
| **Event ordering** | **CÓ LỖI** | `ZLModBridge.m:457` khi gửi CSaving batch lỗi sẽ nối `batch` cũ vào **cuối** `pendingMessages` sau các tin nhắn mới đến trong lúc đang gửi → **đảo lộn thứ tự thời gian tin nhắn!** |
| **Duplicate messages** | **CÓ LỖI** | (1) `ZLModAntiRecall` gọi `ZLModSnapshotChatEntity` ở cả `addChat:`, `addChats:`, và `didLoadChats:` → phát `ZLModChatEntityArrivedNotification` nhiều lần cho cùng 1 tin → `ZLModBridge` đẩy lặp sang Local Server (không có dedup cache cục bộ); (2) Khi kết nối lại, cả `didOpenWithProtocol:` (`ZLModBridge.m:592`) và `action:"connected"` (`ZLModBridge.m:252`) đều gọi `flushPendingMessages` (may là `removeAllObjects` trong lock nên không gửi trùng batch cũ, nhưng nếu gửi đang in-flight mà thất bại thì có thể race). |
