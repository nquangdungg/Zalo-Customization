# API_SPEC.md — Kiểm toán Toàn bộ API (Phase 7) & Error Handling (Phase 11)

> ZLMod có **4 tầng API** thực tế:
> 1. **External Network APIs** (C-Bridge HTTP/WS tới Local Server & Discord Webhook)
> 2. **In-Process Network Interception Rules** (`NSURLProtocol` chặn tracking/ads của Zalo)
> 3. **Zalo Host Runtime Hook Surface** (47+ Objective-C method hooks trên binary Zalo iOS)
> 4. **Offline Build / Packaging / Preflight CLI APIs** (`Packaging/*.py`, `Scripts/*`, `Makefile`)

---

## PHẦN A — EXTERNAL NETWORK APIS (`Sources/ZLModBridge.m`)

### API-01 — C-Bridge WebSocket Channel
- **Endpoint:** `ws(s)://<host>[:port]/cbridge/ws?token=<token>&account=<accountScope>&userId=<rawUid>` (`ZLModBridge.m:125-131`)
- **Method:** `GET` (WebSocket Upgrade via `NSURLSessionWebSocketTask`)
- **Purpose:** Kênh song công cho CPairing (heartbeat), CSaving (đẩy batch tin nhắn), CDeploy (upload/push/ack cài đặt).
- **Request:**
  - Query params:
    - `token`: `kZLModBridgeToken` (encode bằng `URLQueryAllowedCharacterSet` — **BUG: không escape `&`, `=`, `+`**)
    - `account`: `ZLModCurrentAccountScope()` (VD: `acc_<16hex>` hoặc `""`)
    - `userId`: `ChatDataManager.sharedChatDataManager.userId` (hoặc `""`)
  - Outbound JSON frames:
    1. Heartbeat Ping (`ZLModBridge.m:209-212`): `{"action":"ping","timestamp":<unix_sec_double>}`
    2. CDeploy Upload (`ZLModBridge.m:344-349`): `{"action":"cdeploy_upload","accountScope":"...","settings":{<17_keys>},"timestamp":<unix_sec_double>}`
    3. CDeploy Ack (`ZLModBridge.m:278-281, 313-317`): `{"action":"cdeploy_ack","status":"accepted"|"rejected","timestamp"?:<unix_sec_double>}`
    4. CSaving Batch (`ZLModBridge.m:441-445`): `{"action":"csaving","accountScope":"...","messages":[<CSavingRecord>...]}`
- **Response (Inbound JSON frames, `ZLModBridge.m:230-259`):**
  1. `{"action":"connected"}` → set status `Connected`, gọi `flushPendingMessages`
  2. `{"action":"pong"}` → tính `lastPingLatencyMs = (now - lastPingSentTime) * 1000`
  3. `{"action":"cdeploy_push","settings":{...}}` → mở `UIAlertController` xác nhận trên main thread
  - **Server implementation contract:** **`UNKNOWN — NEEDS VERIFICATION`** (server `zalo-meet-bot` nằm ngoài repo này).
- **Authentication:** Shared secret `token` truyền **plaintext trên URL query string** (và không bắt buộc TLS — thường là `ws://` trong LAN).
- **Caller:** `ZLModBridgeInstall()`, `ZLModBridgeViewController` (lưu URL/Token), `handleAppDidBecomeActive`, `handleAccountChanged`, `scheduleReconnect`.
- **Consumer:** `ZLModBridgeManager`, `ZLModBridgeViewController`, `ZLModSettingsViewController`.
- **Errors:** Lỗi `receiveMessage` hoặc `didCloseWithCode:` đặt status `Disconnected` và gọi `scheduleReconnect`. Không có pong timeout.
- **Retry:** Cố định `5.0s` (`dispatch_after`, `ZLModBridge.m:221`), không có exponential backoff, không giới hạn số lần retry, không chống chồng chéo timer.
- **Caching:** Không (hàng đợi `pendingMessages` chỉ trong RAM, mất khi tắt app).

---

### API-02 — C-Bridge HTTP Healthcheck (CPairing Ping) — **BROKEN**
- **Endpoint:** `[serverUrl stringByAppendingPathComponent:@"/api/cbridge/health"]` (`ZLModBridge.m:472`)
- **Method:** `GET` (timeout `5.0s`, dùng `[NSURLSession sharedSession]`)
- **Purpose:** Kiểm tra server sống & đo độ trễ RTT khi user bấm *"Kiểm tra kết nối ngay (Ping Server)"*.
- **Request:** Header `Authorization: Bearer <token>` (nếu `token.length > 0`).
- **Response:** Kiểm tra duy nhất `statusCode == 200` (bỏ qua hoàn toàn response body `data`).
- **Authentication:** Bearer token header.
- **Caller:** `ZLModBridgeViewController` (`ZLModUI.m:185`).
- **Consumer:** Toast kết quả & `tableView reloadData`.
- **Errors:** **BUG NGHIÊM TRỌNG (`ZLModBridge.m:472`):** `NSString -stringByAppendingPathComponent:` biến `"http://192.168.1.15:3000"` thành **`"http:/192.168.1.15:3000/api/cbridge/health"`** (rút gọn `//` thành `/`!), khiến request luôn lỗi trên mọi URL `http://`/`https://` hợp lệ! Ngoài ra nếu server trả `401`/`403`/`500`, không đọc body hay phân biệt mã HTTP (chỉ báo `"Máy chủ trả về mã lỗi"`).
- **Retry / Caching:** Không retry, không cache.

---

### API-03 — Discord Webhook Test — **PARTIAL / TEST-ONLY**
- **Endpoint:** `<kZLModBridgeWebhook>` (do user nhập tự do, placeholder `https://discord.com/api/webhooks/...`, `ZLModBridge.m:507`)
- **Method:** `POST` (timeout `8.0s`, `Content-Type: application/json`)
- **Purpose:** Chỉ gửi tin nhắn test kết nối thủ công; **không có endpoint/caller nào gửi cảnh báo thực tế**.
- **Request:** `{"content": "🔔 **[ZLMod C-Bridge]** Kiểm tra kết nối Webhook thành công từ iPhone!\nTài khoản: `<accountScope>`"}`
- **Response:** Chấp nhận HTTP `200` hoặc `204`; khác trả `"Lỗi gửi Webhook: Mã lỗi HTTP <status>"`.
- **Authentication:** Bí mật nằm trong chính URL webhook (lưu plaintext trong `NSUserDefaults` + App Group).
- **Caller:** `ZLModBridgeViewController` (`ZLModUI.m:248`).
- **Consumer:** Toast thông báo kết quả.
- **Errors:** Không validate host thuộc `discord.com` / `discordapp.com` (SSRF nội bộ có thể POST `accountScope` tới bất kỳ URL nào user dán vào).
- **Retry / Caching:** Không.

---

## PHẦN B — IN-PROCESS NETWORK INTERCEPTION (`Sources/ZLModURIFilter.m`)

Đăng ký `ZLModBlockURLProtocol : NSURLProtocol` qua `[NSURLProtocol registerClass:]` (`ZLModURIFilter.m:91`):

| Nhóm | Toggle điều khiển | Matching Rules (`ZLModURIFilter.m:15-36`) | Phản hồi giả lập | Hạn chế thực tế |
|---|---|---|---|---|
| **Tracking** | `kZLModBlockTracking` | Host `== "log.api.zaloapp.com"`, HOẶC path prefix `/tracking`, HOẶC path chứa `/tracking-v3` hoặc `/tracking-rt` | HTTP `204 No Content`, `Content-Length: 0`, body rỗng | **Bị bypass** bởi mọi `NSURLSession` dùng custom `NSURLSessionConfiguration` và toàn bộ `WKWebView` |
| **Ads** | `kZLModBlockAdRequests` | Host `== "ads.platform.zalo.me"`, HOẶC path chứa `/zpads/`, `/get/ads`, `/ads_out_stream`, `/ads_boost`, `/v1/ads/` | HTTP `204 No Content`, `Content-Length: 0`, body rỗng | Như trên; ngoài ra `/ads_out_stream` không tồn tại trong IPA `260401/708` |

---

## PHẦN C — ZALO HOST RUNTIME HOOK API (47+ Swizzled Methods)

Toàn bộ danh sách phương thức Objective-C của Zalo bị ZLMod hook tại runtime (xác minh từ `Sources/*.m` + đối chiếu `Decrypted/vn.com.vng.zingalo_260401_decrypted_by_TTJB.ipa`):

| Module | Class | Kind | Selector | Args / Return | Hành vi khi bật | Hiện diện trong IPA `260401` |
|---|---|---|---|---|---|---|
| `Core` | `AppDelegate` | `-` | `didLogout`, `didLogin` | `0 / v` | Invalidate `accountScope`, clear `PrivacyContext`, post `ZLModAccountDidChangeNotification` | OK |
| `Privacy` | `BaseChatTVC` | `-` | `zaloViewDidAppear:`, `zaloViewWillDisappear:` | `1 / v` | Cập nhật `ZLModPrivacyContext` (`activeThreadId`, `activeChatController`) | OK |
| `Privacy` | *(Scan all app classes)* | `-` | `sendSeenMessageWithChatEntity:`, `sendSeenMessageWithTalkTableItem:`, `sendSeenMessages:messageDict:incomingData:` | `1,1,3 / v` | Drop nếu global/per-chat `hideSeen` | OK |
| `Privacy` | `ChatSendSeenDataManager` | `-` | `_sendSeenMessageWithSeenData:messageType:`, `sendSeenServer`, `forceSendSeenServer`, `sendSeenLastMessageWithThreadIds:withMessageType:` | `2,0,0,2 / v` | Drop hoặc lọc mảng `threadIds` bỏ các thread `hideSeen` | OK |
| `Privacy` | `ChatSocketCmdHelper` | `+` | `sendSeenChatACK:withSubCommandType:`, `sendSeenGroupChatACKByData:withSubCommandType:` | `2 / v` | Drop nếu `hideReadReceipts` hoặc per-chat `hideSeen` | OK |
| `Privacy` | `FriendRequestManager` | `-` | `sendSeenCurrentUnreadFriendRequest:sourceView:`, `...retryTime:sourceView:` | `2,3 / v` | Drop nếu `hideSeen` | OK |
| `Privacy` | `ChatDataManager` | `-` | `sendTypingWithType:toUserId:messageType:isE2eeChat:` | `4 / Bc` | Trả `NO` nếu global/per-chat `hideTyping` | OK |
| `Privacy` | `ChatSocketCmdHelper` | `+` | `sendStatusTyping:withCommand:withSubCommand:withDestType:withGlobalMessageId:` | `5 / Q` | Trả `0` nếu global `hideTyping` hoặc `activeThreadId` `hideTyping` | OK |
| `Ads` | `ZInstantFeedAdsView`, `LocationOAAdsCell` | `-` | `didMoveToWindow`, `setHidden:` | `0,1 / v` | Ép `hidden=YES, alpha=0, userInteractionEnabled=NO` | OK |
| `Features` | *(Scan ProfileMusic classes)* | `-` | `enableProfileMusic`, `enableProfileMusicRBT`, `enableShareProfileMusic`, `newFlagEnableProfileMusic`, `setEnableProfileMusicLocal:` | `0/Bc`, `1/v` | Ép trả `YES` / ép tham số `YES` | OK (nhưng key `features@profile_music` MISSING) |
| `Features` | *(Scan GDrive classes)* | `-` | `__basicBackupGDriveSectionZInstantData`, `_basicBackupGDriveSectionZInstantData` | `0 / @` | Bridge 2 chiều section GDrive | **MISSING cả 2!** |
| `Settings` | `UIWindow` | `-` | `motionEnded:withEvent:` | `2 / v` | Lắc máy mở `ZLModSettingsViewController` | OK (UIKit) |
| `Settings` | `SettingUI40TableViewController` *(+4 fallback)* | `-` | `viewDidLoad`, `viewWillAppear:`, `viewDidAppear:`, `updateTitleObjects`, `tableView:didSelectRowAtIndexPath:`, `tableView:numberOfRowsInSection:`, `tableView:cellForRowAtIndexPath:` | `0,1,1,0,2,2,2` | Chèn & xử lý click hàng `"ZLMod Customize"` | OK |
| `Glass` | `ZaloTabBarViewController` | `-` | `viewDidAppear:` | `1 / v` | Gắn `UIBlurEffect` lên `UITabBarAppearance` | OK |
| `ConvMenu` | `InboxContextMenuManager` | `-` | `getActionsWithItem:` | `1 / @` | Chèn section 4 action (9101–9104) | OK (nhưng `ZAContextMenuAction` MISSING) |
| `ConvMenu` | `InboxContextMenuManager` | `-` | `contextMenu:didSelectActionId:forIdentifier:` | `3 / v` | Thực thi 4 action per-chat | **MISSING!** |
| `ConvMenu` | `UXInboxMessageCell` | `-` | `setObject:`, `prepareForReuse` | `1,0 / v` | Vẽ/ẩn chấm xanh `#0068FF` | OK |
| `ConvMenu` | `ChatListItemCell` | `-` | `setListItem:`, `prepareForReuse` | `1,0 / v` | Vẽ/ẩn chấm xanh `#0068FF` | **MISSING!** |
| `AntiRecall` | `ConversationModel` | `-` | `didLoadChats:config:`, `updateDBWhenRecalledChats:completion:` | `2,2 / v` | Snapshot tin nhắn & lưu bản mã hóa khi thu hồi | OK |
| `AntiRecall` | `ChatDataManager` | `-` | `addChats:byUserId:willAlert:fromSrc:`, `addChat:byUserId:willAlert:fromSrc:` | `4,4 / v` | Snapshot tin nhắn đến (và post notif CSaving!) | OK |
| `AntiRecall` | `ChatEntity` | `-` | `_getRecalledMsgPreviewFromSource:`, `message` | `1/@`, `0/@` | Trả về văn bản giải mã khi đã unhide hoặc preview cục bộ | OK |
| `AntiRecall` | `MenuButton` | `-` | `showContextMenuViewWithMenuItemArray:hasReaction:`, `menuView:didTapItemType:` | `2,2 / v` | Chèn & xử lý nút Hiện (`99001`) / Ẩn (`99002`) | OK |
| `Utilities` | `ZAChatSendingManager` | `-` | `sendChat:checkUpload:` | `2 / v` | Hoãn gửi 1–10s theo 5-state FSM | OK |

---

## PHẦN D — OFFLINE CLI / PACKAGING / CI APIS

| Script / Tool | Interface (Arguments) | Input → Output | Caller |
|---|---|---|---|
| `Scripts/generate_compatibility.py` | `<manifest.json> <output.h>` | `Resources/compatibility.json` → `Sources/ZLModCompatibilityData.h` | `Makefile`, `Tests/test_compatibility_contract.py` |
| `Packaging/package_ipa.py` | `--input <ipa> --output <ipa> --bundle-id <id\|auto\|preserve> [--display-name] [--dylib] [--no-appex] [--allow-custom-bundle-id]` | Decrypted IPA + `libZLMod.dylib` → Unsigned injected IPA | CLI, `.github/workflows/build.yml`, `.github/workflows/release.yml` |
| `Packaging/macho_injector.py` | `<macho_file> <dylib_path> [output_file]` (+ Python API `inject_rpath`, `inject_load_dylib`, `get_load_dylibs`, `get_rpaths`) | Mach-O 64-bit / FAT → Patched Mach-O | `package_ipa.py`, `Tests/test_packaging_contract.py` |
| `Packaging/ipa_preflight.py` | `<ipa> [--expect-bundle] [--require-unencrypted-main] [--require-compatible] [--require-installable] [--json-output]` | IPA → Console & JSON Forensics Report (exit 0/1/2) | CLI, `Tests/test_packaging_contract.py` |
| `Scripts/gates.sh` | `[path/to/libZLMod.dylib]` | Static binary gate check (exit 0/1) | `Makefile`, CI |
| `Scripts/anchors-verify.sh` | `ZLMOD_IPA_DUMP=<dir> ./Scripts/anchors-verify.sh` | Verify 86 anchors against dump | Manual IPA intake |
| `Scripts/project_gate.py` | `[root_dir]` | Kiểm tra rò rỉ chuỗi `Zync`/`ZYNC`/`zync` | CI, `Tests/test_product_identity.py` |
| `Scripts/report.sh` | `[dylib] [outdir]` | Sinh `.sha256`, `.nm.txt`, `.otool-L.txt`, `.file.txt`, `IMPLEMENTATION-REPORT.md`, `COMPATIBILITY-REPORT.md` | CI |

---

## PHẦN E — API DEPENDENCY MAP & ANOMALIES

```text
[S02 ZLModBridgeViewController]
  ├── Ping Server ──► ZLModBridgeManager.testPairingWithCompletion: ──► GET <BROKEN http:/>/api/cbridge/health ──► Local Server
  ├── Save URL/Tok ─► ZLModPreferences.setString: (+DUP notif +direct) ─► 3x reconnect() ──► WS /cbridge/ws ────► Local Server
  ├── Test Webhook ─► ZLModBridgeManager.testWebhookWithCompletion: ──► POST <user_url> ─────────────────────────► Discord API
  └── Upload CDeploy► ZLModBridgeManager.uploadCurrentSettings: ──────► WS action="cdeploy_upload" ──────────────► Local Server

[Zalo ConversationModel / ChatDataManager]
  └── Hook ZLModAntiRecall (ONLY if kZLModAntiRecall=YES!)
        └── NSNotification "ZLModChatEntityArrivedNotification"
              └── ZLModBridgeManager.enqueueMessageForSaving: ──► WS action="csaving" ──► Local Server (SQLite)

[Zalo UI / Network]
  ├── NSURLConnection / sharedSession ──► ZLModBlockURLProtocol ──► HTTP 204 (bypassed by custom NSURLSession & WKWebView!)
  ├── ChatDataManager / ChatSendSeenDataManager / ChatSocketCmdHelper ──► ZLModPrivacy ──► Drop / Filter
  └── ZAChatSendingManager ──► ZLModDelaySendManager ──► Timer 1-10s ──► origIMP (Zalo Send)
```

### Phát hiện bất thường API (API Audit Findings)
1. **Duplicate API Calls / 3x Reconnect (`ZLModUI.m:203-206, 221-224`):** Một thao tác bấm "Lưu" Server URL hoặc Bridge Token gọi `reconnect` **3 lần liên tiếp** (tạo 3 WebSocket handshakes đua nhau và hủy lẫn nhau).
2. **Broken Endpoint (`ZLModBridge.m:472`):** `GET /api/cbridge/health` bị phá hỏng cú pháp URL (`http:/...`) trước khi gửi đi.
3. **Duplicate Message Streaming (`ZLModBridge.m:366-426`):** Cùng một `ChatEntity` bị bắn qua cả `addChat:` và `didLoadChats:` mà không có local dedup cache trước khi gửi WS `csaving`.
4. **Unused / Stub Endpoint:** Discord Webhook không có luồng sản xuất, chỉ có nút test.
5. **Inconsistent Response & Auth Patterns:** WS gửi token qua query string không escape đúng (`?token=`), còn HTTP healthcheck gửi qua `Authorization: Bearer`; `cdeploy_upload` không chờ ACK còn `cdeploy_push` có `cdeploy_ack`.
6. **Race Conditions:** `ZLModBridgeManager` không so sánh `webSocketTask == self.webSocketTask` trong `receiveMessageWithCompletionHandler:` và `didCloseWithCode:` → đóng socket cũ giết nhầm socket mới.

---

## PHẦN F — PHASE 11: ERROR HANDLING AUDIT

| Error Source | Error Handler | User-Facing Behavior | Vấn đề (Swallowed / Ignored / Misleading) |
|---|---|---|---|
| **Network — WS disconnect / timeout (`ZLModBridge.m:167, 595`)** | Log + set `Disconnected` + `scheduleReconnect` (5s) | Chỉ đổi text trạng thái ở S02 thành `"Disconnected"` | **Logged, không báo lỗi cụ thể** (không phân biệt sai Token 401, sai IP, hay bị iOS chặn Local Network!) |
| **Network — Healthcheck Ping (`ZLModBridge.m:489-494`)** | Dispatch main → completion toast | Toast `"Lỗi kết nối: ..."` | Bị bug phá URL ở dòng 472; nuốt HTTP status code (chỉ hiện `"Máy chủ trả về mã lỗi"`). |
| **Network — CSaving WS send fail (`ZLModBridge.m:454-459`)** | Re-enqueue vào `pendingMessages` | Không báo user | Re-enqueue sai thứ tự & vượt trần 50 tin; không log lỗi thất bại! |
| **Network — Discord Webhook (`ZLModBridge.m:526-532`)** | Completion toast với HTTP status | Toast `"Lỗi gửi Webhook: Mã lỗi HTTP ..."` | Tương đối rõ ràng. |
| **Auth / Account Scope (`ZLModCryptoStore.m:106`)** | Trả `nil` (fail-closed) | Ở S01 hiện `"unidentified (fail-closed)"`; ở S03/S04/S06 hiện **Empty State**! | **Converted to Empty State** ở 3 màn hình quản lý; user tưởng mất hết dữ liệu. |
| **Keychain Error (`ZLModCryptoStore.m:231, 262`)** | Log `OSStatus` + fail-closed (`nil`) | Lưu Private Note/Anti-Recall thất bại **im lặng**! | **Logged nhưng không báo user**; `ZLModPresentPrivateNoteEditor` không hiện toast khi `setNote:` trả `NO`. |
| **Validation — Theme Hex (`ZLModTheme.m:152`)** | Reset hex về `@""` | UI đổi thành `"Mặc định"` | **Swallowed** — không báo cho user biết chuỗi vừa nhập sai chuẩn `#RRGGBB`. |
| **Validation — Quick Reply (`ZLModUtilities.m:365-374`)** | Trả `NO` nếu rỗng hoặc ≥ 50 mẫu | Đóng alert không làm gì | **Swallowed** — không báo đạt giới hạn 50 mẫu. |
| **Persistence — Plist load/save (`PolicyStore`, `AntiRecall`, `Notes`, `QuickReplies`)** | `@try/@catch` + rollback RAM nếu ghi đĩa fail | Trả `NO` (đa số caller bỏ qua giá trị trả về) | Lỗi hỏng file `.plist` bị nuốt (chỉ log hoặc return NO), có nguy cơ dữ liệu trên đĩa biến mất như empty state. |
| **Runtime Hook — Missing Anchor / ABI mismatch (`ZLModHookEngine.m`, `ZLModCore.m`)** | Trả `NO`, log chi tiết, ghi `NOT_INSTALLED` | Xem được trong S07 (Module Status) và S08 (Logs) | Xử lý an toàn không crash, nhưng không có banner cảnh báo trên S01 khi module quan trọng (VD Settings/ConversationMenu) bị `NOT_INSTALLED`. |
| **Delay Send — `origIMP` throws (`ZLModUtilities.m:678-681`)** | `@catch`, log + set `ZLModDelaySendStateFailed` | Không báo user | **Logged nhưng không báo user** — tin nhắn biến mất không gửi đi được mà user tưởng đã gửi! |
| **UI — CDeploy Push khi đang có modal (`ZLModBridge.m:265-286`)** | Kiểm tra `!presenter` rồi gọi `presentViewController:` | Không hiện popup nếu `presenter` đang bận hiện alert khác | **Ignored** — không gửi `cdeploy_ack`, server treo chờ phản hồi. |
