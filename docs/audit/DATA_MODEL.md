# DATA_MODEL.md — Kiểm toán Mô hình Dữ liệu (Phase 8) & Quản lý Trạng thái (Phase 9)

> ZLMod không dùng SQLite/CoreData nội bộ (trừ SQLite phía Local Server `zalo-meet-bot` bên ngoài repo: **`UNKNOWN — NEEDS VERIFICATION`**). Toàn bộ dữ liệu bền vững trên iPhone nằm trong **iOS Keychain**, **3 `NSUserDefaults` domains**, **4 tệp Binary Property List (`Documents/ZLMod*.plist`)**, và **tệp log xoay vòng `ZLMod.log`**.

---

## PHẦN A — PHASE 8: DATA MODEL & PERSISTENCE SCHEMA AUDIT

### 1. iOS Keychain Schema (`Sources/ZLModCryptoStore.m:14-15, 207-265`)
| Thuộc tính | Giá trị |
|---|---|
| `kSecClass` | `kSecClassGenericPassword` |
| `kSecAttrService` | `vn.com.vng.zingalo.zlmod.keystore` |
| `kSecAttrAccount` | `master_key_v2` |
| `kSecValueData` | 32 bytes random (`CCRandomGenerateBytes`, AES-256 master key) |
| `kSecAttrAccessible` | `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` |

**Derived Keys & Binary Ciphertext Envelope (v2):**
- `encKey = SHA256("ZLMod.v2.ENC|" || masterKey)` (32 bytes)
- `macKey = SHA256("ZLMod.v2.MAC|" || masterKey)` (32 bytes)
- Package layout (`NSData`, min length 65 bytes):
  `[0x02 (1B version)] [IV (16B)] [AES-256-CBC PKCS7 Ciphertext (k*16B)] [HMAC-SHA256 (32B)]`
- MAC input: `version(1B) || IV(16B) || ciphertext || metaLen(uint32 big-endian) || metadata`

---

### 2. `NSUserDefaults` Preferences Schema (`Sources/ZLModPreferences.m:11-59`)

**Domains:**
1. Primary suite: `vn.com.vng.zingalo.zlmod` *(lưu ý: `README.md:14` ghi sai là `com.zlmod.preferences`!)*
2. Mirror App Group suite: `group.zsettings.vn.com.vng.zingalo` *(có thể `nil` khi sideload free Apple ID)*
3. Host standard defaults: `[NSUserDefaults standardUserDefaults]` *(dùng cho external feature flags)*

| Key Constant | String Key | Type | Default | Security / Ghi chú |
|---|---|---|---|---|
| `kZLModGlassTabBar` | `zlmod.appearance.glass` | `BOOL` | `NO` | |
| `kZLModThemePreset` | `zlmod.appearance.themePreset` | `NSString` | `@""` | Enum: `""`, `classic_blue`, `dark_oled`, `pure_black`, `ocean_teal` |
| `kZLModThemeTintHex` | `zlmod.appearance.themeTintHex` | `NSString` | `@""` | `#RRGGBB` (6 hex chars) |
| `kZLModHideTyping` | `zlmod.privacy.hideTyping` | `BOOL` | `NO` | |
| `kZLModHideSeen` | `zlmod.privacy.hideSeen` | `BOOL` | `NO` | |
| `kZLModHideReadReceipts` | `zlmod.privacy.hideReadReceipts` | `BOOL` | `NO` | |
| `kZLModBlockTracking` | `zlmod.privacy.blockTracking` | `BOOL` | `NO` | |
| `kZLModBlockFirebase` | `zlmod.privacy.blockFirebase` | `BOOL` | `NO` | |
| `kZLModHideAds` | `zlmod.ads.hide` | `BOOL` | `NO` | |
| `kZLModBlockAdRequests` | `zlmod.ads.blockRequests` | `BOOL` | `NO` | |
| `kZLModRestoreProfileMusic` | `zlmod.features.profileMusic` | `BOOL` | `NO` | Mirror 4 external keys |
| `kZLModRestoreGDrive` | `zlmod.features.gdriveBackup` | `BOOL` | `NO` | Mirror `restore_gdrive_photo_csc` |
| `kZLModRestoreMoreTab` | `zlmod.features.moreTab` | `BOOL` | `NO` | Mirror `enable_tabmore` |
| `kZLModAntiRecall` | `zlmod.messaging.antiRecall` | `BOOL` | `NO` | **Cũng gián tiếp bật/tắt CSaving!** |
| `kZLModDelaySend` | `zlmod.utilities.delaySend` | `BOOL` | `NO` | |
| `kZLModDelaySendSeconds` | `zlmod.utilities.delaySendSeconds` | `double` | `3.0` | Clamp `[1.0, 10.0]` |
| `kZLModBridgeServerURL` | `zlmod.bridge.serverUrl` | `NSString` | `@""` | Plaintext |
| `kZLModBridgeToken` | `zlmod.bridge.token` | `NSString` | `@""` | **SECRET lưu plaintext trong UserDefaults & App Group!** |
| `kZLModBridgeWebhook` | `zlmod.bridge.webhook` | `NSString` | `@""` | **SECRET lưu plaintext trong UserDefaults & App Group!** |
| `kZLModBridgeSaving` | `zlmod.bridge.savingEnabled` | `BOOL` | `NO` | |
| `kZLModBridgeLastSync` | `zlmod.bridge.lastSyncTime` | `NSString` | `"Chưa đồng bộ"` | Format `"HH:mm:ss dd/MM"` (chỉ cập nhật khi pull push, không cập nhật khi upload) |

**Internal Backup Keys (trong `own` suite):** `zlmod.internal.prev.<extKey>` & `zlmod.internal.prev.present.<extKey>` lưu giá trị cũ của 6 external Zalo keys: `kProfileMusicSetting`, `profile_music`, `features@profile_music`, `enable_rbt`, `restore_gdrive_photo_csc`, `enable_tabmore`.

---

### 3. Binary Plist Schemas (`<Documents>/ZLMod*.plist`)

#### 3.1. `Documents/ZLModPolicies.plist` (`Sources/ZLModPolicyStore.m:104-175`)
```json
{
  "version": 2,
  "policies": {
    "<accountScope>:<convType>:<threadId>": {
      "accountScope": "acc_0123456789abcdef",
      "convType": "user | group",
      "threadId": "raw_zalo_thread_id",
      "threadHash": "h_a1b2c3d4",
      "hideSeen": true,
      "hideTyping": false,
      "localUnread": true,
      "updatedAt": 1731234567.0
    }
  }
}
```
- **Ghi chú:** Không mã hóa; chứa `threadId` dạng plaintext (dù UI chỉ hiển thị `threadHash`); tự xóa entry nếu cả 3 cờ đều `NO`.

#### 3.2. `Documents/ZLModAntiRecall.plist` (`Sources/ZLModAntiRecall.m:62-360`)
```json
{
  "version": 2,
  "records": {
    "<accountScope>:g_<globalId> | <accountScope>:c_<clientId>": {
      "accountScope": "acc_0123456789abcdef",
      "globalId": 12345678901234,
      "clientId": 9876543210,
      "threadHash": "h_a1b2c3d4",
      "senderHash": "h_e5f60718",
      "timestamp": 1731234500.0,
      "savedAt": 1731234567.0,
      "cipher": "<NSData: ZLModCryptoBox v2 envelope>"
    }
  }
}
```
- **AAD metadata:** `"ZLModAntiRecall.v2|<accountScope>|<gid>|<cid>|<threadId>|<int64(ts)>"` (hoặc tương đương dùng lúc encrypt/decrypt trong `ZLModAntiRecall.m`).
- **TTL & Cap:** Hết hạn sau `14 * 86400` giây (14 ngày), tối đa `400` bản ghi/account.
- **Lưu ý bảo mật/thiết kế:** `senderName` & `message` được gộp mã hóa trong `cipher`; `threadId` không lưu plaintext ở record (chỉ `threadHash`), nhưng ảnh thu hồi **không có trường lưu trữ nào** (chỉ đọc nóng từ `ChatEntity` trong RAM!).

#### 3.3. `Documents/ZLModNotes.plist` (`Sources/ZLModUtilities.m:41-136`)
```json
{
  "version": 2,
  "records": {
    "<accountScope>:<threadId>": {
      "accountScope": "acc_0123456789abcdef",
      "threadId": "raw_zalo_thread_id",
      "threadHash": "h_a1b2c3d4",
      "updatedAt": 1731234567.0,
      "cipher": "<NSData: ZLModCryptoBox v2 envelope>"
    }
  }
}
```
- **AAD metadata:** `"ZLModNote.v2|<accountScope>|<threadId>"`.
- **Lưu ý:** Nội dung `note` đã mã hóa nhưng `threadId` vẫn lưu plaintext trong key và trường `threadId`. Không lưu `displayTitle` (tên người/nhóm) nên S06 không hiển thị được tên hội thoại.

#### 3.4. `Documents/ZLModQuickReplies.plist` (`Sources/ZLModUtilities.m:313-352`)
```json
[
  "Mình đang bận một chút, lát mình nhắn lại nhé!",
  "Đã nhận thông tin, cảm ơn bạn nhé.",
  "Ok bạn, để mình kiểm tra rồi phản hồi ngay."
]
```
- **Lưu ý:** Không có trường `version`, không phân tách theo `accountScope` (dùng chung mọi tài khoản), không mã hóa, giới hạn `kZLModMaxQuickReplies = 50`.

---

### 4. In-Memory Runtime Models & Wire DTOs

| Model / DTO | File:Line | Fields chính | Nullable / Type Notes |
|---|---|---|---|
| `ZLModLiveSnapshot` | `ZLModAntiRecall.m:20-31` | `globalId (int64)`, `clientId (int64)`, `message (NSString)`, `senderName (NSString)`, `senderId (NSString)`, `threadId (NSString)`, `timestamp (NSTimeInterval)` | Chỉ sống trong RAM (`liveByKey`, cap 500, nhưng `altKey` bị leak!) |
| `ZLModMenuSession` | `ZLModConversationMenu.m:66-76` | `identifier`, `threadId`, `convType`, `displayTitle`, `createdAt` | Single-use, TTL 120s, cap 32 |
| `ZLModPendingSendItem` | `ZLModUtilities.m:485-494` | `sendId (UUID)`, `state (enum 0..4)`, `weak senderManager`, `strong chatEntity`, `checkUpload (BOOL)`, `targetHash`, `fireTime`, `timer (dispatch_source_t)` | Chỉ trong RAM; hủy khi background/terminate/account change |
| `ZLModBFSNode` | `ZLModSettings.m:144-154` | `object`, `depth`, `parentEntry`, `ivarName` | Tạm thời trong quá trình BFS tìm Settings row |
| **Wire DTO: CSaving Message** | `ZLModBridge.m:404-416` | `identityKey (str)`, `threadId (str)`, `threadType (0\|1)`, `msgId (str)`, `cliMsgId (str)`, `senderUid (str)`, `senderName (str)`, `text (str)`, `msgType (chat.text\|photo\|sticker\|voice\|file)`, `timestampMs (int64)`, `isSelf (BOOL)` | **Schema mismatch nghiêm trọng** với Zalo `ChatEntity` (xem mục 5) |
| **Wire DTO: CDeploy Upload** | `ZLModBridge.m:325-349` | `action="cdeploy_upload"`, `accountScope`, `settings (17 keys)`, `timestamp` | Chỉ upload 17/21 keys (loại trừ `serverUrl`, `token`, `webhook`, `lastSync`) |
| **Wire DTO: CDeploy Push** | `ZLModBridge.m:253-303` | `action="cdeploy_push"`, `settings (arbitrary NSDictionary)` | **Không đối xứng với Upload:** chấp nhận MỌI key bất kỳ không allowlist! |
| **Compatibility Manifest** | `Resources/compatibility.json` | `targets[{version, build, bundleIdentifiers[]}]` | 2 bản ghi: `261002/261002802`, `261101/261101802` |
| **Preflight Report JSON** | `Packaging/ipa_preflight.py:223-247` | `file`, `size_bytes`, `sha256`, `app_name`, `bundle_id`, `version`, `build`, `minimum_os`, `zlmod_supported`, `main_executable`, `macho_inventory`, `encrypted_macho_paths`, `installability{state, directly_installable, is_signed, warnings, ...}` | Bug: `state="PROVISIONED_AND_SIGNED"` khi `directly_installable=False`! |

---

### 5. Duplicate Models & Schema Mismatches phát hiện được

1. **Duplicate & Inconsistent `ChatEntity` Extraction (AntiRecall vs Bridge):**
   - `ZLModAntiRecall.m:530-595` dùng đa fallback: `globalId` / `globalMsgId`, `clientId` / `cliMsgId`, `senderName` / `displayname`, `senderId` / `fuid`, `threadId` / `tuid`, `time` / `createTime`.
   - `ZLModBridge.m:370-381` **chỉ đọc 1 bộ hẹp**: `globalId`, `clientId`, `threadId`/`tuid`, `message`, `senderName`, `senderId`, `createTime`, `isOwner`, `isChatGroup` — nếu Zalo dùng `globalMsgId`/`cliMsgId`/`fuid`/`displayname`/`time` trên loại tin nhắn nào đó, CSaving sẽ gửi chuỗi rỗng/0!
2. **Timestamp Unit Mismatch:**
   - `ZLModAntiRecall` & `ZLModPolicyStore` & `ZLModNotes` & CDeploy `timestamp`: lưu đơn vị **giây (`NSTimeInterval`)**.
   - `ZLModBridge` CSaving `timestampMs`: lấy `createTime` trực tiếp (`ZLModBridge.m:377-378`); nếu `createTime` từ Zalo là giây hay mili-giây không được chuẩn hóa, còn fallback lại nhân `* 1000.0` (ms)!
3. **CDeploy Upload vs Push Schema Asymmetry:**
   - Upload đóng gói đúng 17 keys an toàn (`ZLModBridge.m:325-332`), nhưng Push (`applyRemoteSettings:`, dòng 289-303) không giới hạn tập key nào → có thể ghi đè 4 keys cấu hình/secret (`serverUrl`, `token`, `webhook`, `lastSync`) hoặc key bất kỳ.
4. **`accountScope` vs `rawUid` Duplicate Identity:**
   - Mọi store cục bộ dùng `accountScope` (`acc_<sha256_16hex>`), nhưng `ZLModBridge.m:119-129` gửi thêm `rawUid` lấy riêng từ `ChatDataManager.userId` (không dùng đủ 4 nguồn fallback như `ZLModCryptoStore.m:80-95`).
5. **Compatibility Policy Drift (Build/Preflight vs Runtime):**
   - `Resources/compatibility.json` & `Packaging/ipa_preflight.py` dùng strict exact matching.
   - `Sources/ZLModCompatibility.m:22-30` thêm runtime fallback động → cùng một IPA (`260401/708`), `ipa_preflight.py` báo `supported=False`, còn runtime dylib báo `hostSupported=YES`!

---

## PHẦN B — PHASE 9: STATE MANAGEMENT AUDIT

| State Bucket | Classification | Owner | Source | Consumers | Update Mechanism | Persistence | Potential Stale State | Potential Race Condition |
|---|---|---|---|---|---|---|---|---|
| **Feature Preferences (21 keys)** | `PERSISTED STATE` + `GLOBAL STATE` | `ZLModPreferences` | `NSUserDefaults` (`own` + `group`) | Toàn bộ 11 modules & S01/S02 | Setter + `ZLModPrefsDidChangeNotification` | `Library/Preferences/vn.com.vng.zingalo.zlmod.plist` (+ App Group) | `ZLModUI.m` tự giữ cache `self.switches` (đồng bộ lại ở `cellForRow`) | Ghi đồng thời không có lock (dựa vào thread-safety của `NSUserDefaults`); double/triple notifications từ `ZLModUI.m` & `resetAllPreferences` |
| **Account Scope Cache (`gCachedAccountScope`)** | `CACHE` + `GLOBAL STATE` | `ZLModCryptoStore.m` | 4 Zalo singletons (`ZAApplicationContext`, ...) | `PolicyStore`, `AntiRecall`, `Notes`, `Bridge`, S01 | Lazy resolve + invalidate khi `didLogin`/`didLogout` | Không (RAM) | Nếu Zalo đổi user không qua `didLogin`/`didLogout` hook → stale scope! | Khóa `os_unfair_lock` (an toàn thread) |
| **Active Chat Context (`gActiveChatController`, `gActiveThreadId`, `gActiveConvType`)** | `GLOBAL STATE` | `ZLModPrivacyContext` (`ZLModPolicyStore.m`) | Hook `BaseChatTVC -zaloViewDidAppear:` / `willDisappear:` | `ZLModPrivacy`, `ZLModQuickReplyStore` | Direct class methods dưới `gPrivacyCtxLock` | Không (RAM) | Nếu push 2 `BaseChatTVC` chồng nhau rồi pop, `willDisappear:` của VC trước có thể xóa hoặc để lại sai active thread; socket typing/seen background dùng nhầm `activeThreadId` | `os_unfair_lock` bảo vệ truy cập, nhưng race logic giữa UI transition và background socket calls |
| **Per-Conversation Policies (`policies`)** | `PERSISTED STATE` + `GLOBAL STATE` | `ZLModConversationPolicyStore` | `Documents/ZLModPolicies.plist` | `ZLModPrivacy`, `ZLModConversationMenu`, S01, S03 | Mutate dưới `_lock` + atomic plist write + `ZLModConversationPolicyDidChangeNotification` | Disk (binary plist) | Không (observer cập nhật cell & S01) | `_lock` bảo vệ tốt |
| **Anti-Recall Live Cache (`liveByKey`, `liveOrder`)** | `CACHE` | `ZLModAntiRecallStore` | Hook `didLoadChats`, `addChats`, `addChat` | `ZLModAntiRecall` (recall capture + unhide fallback) | Ghi dưới `_lock`; xóa khi account change | Không (RAM) | **Memory leak:** `altKey` (`c_<cid>`) không bao giờ bị xóa khỏi `liveByKey` khi `liveOrder` evict! | `_lock` bảo vệ tốt |
| **Anti-Recall Encrypted Archive (`records`)** | `PERSISTED STATE` | `ZLModAntiRecallStore` | `Documents/ZLModAntiRecall.plist` | `ZLModAntiRecall`, S01, S04 | Mutate dưới `_lock` + atomic plist write; prune TTL 14d | Disk (encrypted plist) | `entries` ở S04 chỉ đọc ở `viewDidLoad` (không auto-refresh nếu có tin mới thu hồi lúc đang mở S04) | `_lock` bảo vệ tốt |
| **Unhidden Message Keys (`gUnhiddenMessageKeys`)** | `GLOBAL STATE` (UI transient) | `ZLModAntiRecall.m` | Bấm nút Hiện (`99001`) / Ẩn (`99002`) | `ChatEntity -message`, `_getRecalledMsgPreviewFromSource:`, `MenuButton` | Set/Remove dưới `os_unfair_lock`; clear khi account change | Không (RAM, mất khi restart app) | Associated object `kZLModOrigRecallTextKey` trên `UILabel` có thể **stale khi `UITableViewCell` được reuse**! | Lock bảo vệ set, nhưng mutation UILabel chạy trên main thread tách rời khỏi cell reuse |
| **Delay Send Queue (`items`)** | `REALTIME STATE` | `ZLModDelaySendManager` | Hook `ZAChatSendingManager -sendChat:checkUpload:` | Undo Banner (`tag=0x5A1E`), `dispatch_source_t` timers | Atomic 5-state transitions dưới `_lock` | Không (RAM) | Chỉ 1 banner hiển thị → gửi nhiều tin làm mất UI hủy của tin cũ | State machine dùng `_lock` tốt; UI banner race nếu 2 tin gửi sát nhau |
| **Quick Replies (`templates`)** | `PERSISTED STATE` | `ZLModQuickReplyStore` | `Documents/ZLModQuickReplies.plist` | S01 (count), S05 | CRUD dưới `_lock` + atomic plist write | Disk (unencrypted plist) | Không | `_lock` bảo vệ tốt |
| **Private Notes (`records`)** | `PERSISTED STATE` | `ZLModPrivateNotesStore` | `Documents/ZLModNotes.plist` | S01 (count), S06, `ZLModConversationMenu` | CRUD dưới `_lock` + atomic plist write | Disk (encrypted plist) | Không (S06 reload ở completion) | `_lock` bảo vệ tốt |
| **C-Bridge State (`status`, `lastPingLatencyMs`, `savedMessagesCount`, `pendingMessages`, `webSocketTask`)** | `REALTIME STATE` + `SERVER STATE` | `ZLModBridgeManager` | Local Server WebSocket + `ZLModChatEntityArrivedNotification` | S01, S02 | Delegate callbacks + `ZLModBridgeStatusDidChangeNotification` | Chỉ `lastSyncDateString` lưu vào `kZLModBridgeLastSync`; `savedMessagesCount` & `pendingMessages` chỉ RAM | **Stale latency UI** (pong không bắn notification khi đã `Connected`); **stale status** ở S01 (không observe Bridge notification) | **NHIỀU DATA RACES:** `status`, `savedMessagesCount`, `webSocketTask` đọc/ghi không có `_lock` giữa Zalo background thread và main queue; stale cancelled WS task ghi đè status task mới! |
| **Settings Injection State (`gSettingsClass`, `gOurRow`, `gFallbackActive`, `gSectionSnapshot`)** | `GLOBAL STATE` | `ZLModSettings.m` | Hook `SettingUI40TableViewController` | `ZLModSettings.m` | Static vars trên main queue | Không (RAM) | **Stale `gOurRow` / `gSectionSnapshot`** nếu Zalo tạo lại controller Settings mới | Không lock (giả định chỉ chạy main thread, nhưng `ZLModSettingsInstall` chạy từ background boot queue!) |
| **TabBar & Theme Baselines (`gSavedStandard`, `gSavedScrollEdge`, Associated Objects)** | `LOCAL STATE` / `GLOBAL STATE` | `ZLModGlass.m`, `ZLModTheme.m` | Snapshot từ UIKit bars trước khi override | `ZLModGlass`, `ZLModTheme` | Static vars (Glass) & Associated Objects (Theme) | Không (RAM) | **DUPLICATE STATE:** Glass và Theme lưu 2 bản baseline `UITabBarAppearance` độc lập → ghi đè chéo nhau! | `ZLModThemeInstall` đọc `activePresetId` từ background boot thread không lock |
| **Hook Registry & App Class Cache (`gHookedMethods`, `gAppClasses`)** | `GLOBAL STATE` + `CACHE` | `ZLModHookEngine.m` | `objc_getClassList` + các lần `ZLModReplace*` | Mọi module installer | `dispatch_once` + `@synchronized` | Không (RAM) | Ảnh dylib/framework load muộn sau boot không có trong `gAppClasses` | An toàn thread |
| **Module Statuses & Ring Buffer Logs (`gModuleStatuses`, `gRingBuffer`)** | `GLOBAL STATE` + `PERSISTED STATE` | `ZLModCore.m` | `ZLModSetModuleStatus`, `ZLMOD_LOG` | S01, S07, S08 | `@synchronized` / serial log queue | `Documents/ZLMod.log` (+ App Group) | S07 & S08 chỉ snapshot 1 lần ở `viewDidLoad` | An toàn thread |
| **Inbox Menu Sessions (`gMenuSessions`) & Visible Cells (`gVisibleCells`)** | `LOCAL STATE` / `CACHE` | `ZLModConversationMenu.m` | Long-press & `setObject:`/`setListItem:` | `ZLModConversationMenu.m` | Lock + `NSHashTable` weak | Không (RAM) | Session tự hết hạn sau 120s | An toàn thread |
