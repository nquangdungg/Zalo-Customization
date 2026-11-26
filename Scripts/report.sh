#!/bin/bash
# ZLMod — build metadata + implementation report + compatibility report.
set -euo pipefail

DYLIB="${1:-build/libZLMod.dylib}"
OUTDIR="${2:-build}"
DEFAULT_VERSION=$(python3 -c 'import json; print(json.load(open("Resources/version.json"))["tag"])' 2>/dev/null || echo "build-11")
VERSION="${ZLMOD_VERSION:-$DEFAULT_VERSION}"
TAG="${GITHUB_REF_NAME:-local}"
COMMIT="${GITHUB_SHA:-$(git rev-parse --short HEAD 2>/dev/null || echo local)}"

mkdir -p "$OUTDIR"

shasum -a 256 "$DYLIB" | awk '{print $1}' > "$OUTDIR/libZLMod.dylib.sha256"

nm -m "$DYLIB" > "$OUTDIR/libZLMod.nm.txt" 2>/dev/null || true
otool -L "$DYLIB" > "$OUTDIR/libZLMod.otool-L.txt" 2>/dev/null || true
file "$DYLIB" > "$OUTDIR/libZLMod.file.txt" 2>/dev/null || true

BUILD_DATE=$(date -u +"%Y-%m-%d %H:%M UTC")

cat > "$OUTDIR/IMPLEMENTATION-REPORT.md" <<EOF
# ZLMod — Implementation Report

- Version: ${VERSION}
- Build: ${BUILD_DATE}
- Commit: ${COMMIT}
- Artifact: $(basename "$DYLIB") ($(stat -f%z "$DYLIB" 2>/dev/null || stat -c%s "$DYLIB") bytes)
- SHA-256: $(cat "$OUTDIR/libZLMod.dylib.sha256")
- Target: iOS 15.1+, arm64 — Zalo 26.10.02 (261002802) & 26.11.01 (261101802), vn.com.vng.zingalo / vn.com.vng.zingalo2

## Modules

| Module | Deliverable |
|---|---|
| ZLModCore | two-phase constructor boot (background hooks + main-thread UI), module isolation, redacted ring-buffer + async file logging, session observers |
| ZLModCompatibility | single-truth host identity + exact version/build gate + verified 3-class runtime anchor quorum |
| ZLModPreferences | persistent toggles, Keychain-backed secrets (ZLModSecretStore), batch updates, strict CDeploy allowlist |
| ZLModHookEngine | single-pass selector index, ABI-validated instance/class method replacement, main-thread safe UIKit helpers |
| ZLModChatEntityAdapter | immutable ZLModMessageModel normalization (ms/s timestamps, exact recall placeholder matching, photo extraction) |
| ZLModCryptoStore | Keychain-backed AES-256-CBC + HMAC-SHA256 v2 binary/text storage box, ZLModSecretStore, storage health state, async disk I/O |
| ZLModOverlayUI | decoupled main-thread helpers + queued VoiceOver/Dynamic-Type toast banner |
| ZLModPolicyStore | LIFO active chat context stack + account-scoped per-conversation policies with encrypted conversation titles |
| ZLModURIFilter | in-process tracking/ad endpoint blocking covering NSURLSession default/ephemeral configs + Bridge/Discord/WS exemptions |
| ZLModPrivacy | Mach-O verified Seen & Typing hooks (global + per-conversation) + reversible Firebase opt-out |
| ZLModConversationMenu | InboxContextMenuManager & InboxContextMenuProvider long-press menu + UXInboxMessageCell / ChatListItemCell blue dot |
| ZLModMessageTap | decoupled ZLModMessageTapBus routing normalized message/recall events to AntiRecall, CSaving, and DiscordRelay |
| ZLModAntiRecall | local encrypted Ghost Preview (text + encrypted disk photos, 20MB quota, 14-day TTL, non-mutating, cell reuse cleanup) |
| ZLModUtilities | multi-line encrypted Private Notes, account-scoped Quick Reply picker, multi-item keyboard-aware Delay Send Undo FSM |
| ZLModTheme | unified ZLModAppearanceCoordinator + optional theme presets & strict #RRGGBB tint with baseline restoration |
| ZLModAds | ad request blocking + reversible live ad view neutralization |
| ZLModFeatures | Profile Music restore, Google Drive backup bridge, More tab key (single-pass selector index) |
| ZLModSettings | per-VC isolated ZLMod Customize entry + guaranteed zero-index-shift nav bar fallback + undo-safe Shake Gesture |
| ZLModUI | full settings dashboard + 7 child management/diagnostic screens with storage health banners & pull-to-refresh |
| ZLModGlass | system ultra-thin blur tab bar material coordinated via ZLModAppearanceCoordinator |
| ZLModBridge | 4-state WebSocket FSM with epoch guard, backoff & pong timeout, Bonjour LAN discovery, decoupled CSaving, allowlisted CDeploy, automatic Discord Webhook relay |

## Exported interface

\`\`\`
$(nm -g "$DYLIB" 2>/dev/null | head -50 || echo "nm unavailable")
\`\`\`
EOF

cat > "$OUTDIR/COMPATIBILITY-REPORT.md" <<EOF
# ZLMod — Compatibility Report

- Host: Zalo 26.10.02 (261002802) & 26.11.01 (261101802), vn.com.vng.zingalo / vn.com.vng.zingalo2, arm64
- Fallback compatibility: verified 3-class runtime anchor quorum (ZaloTabBarViewController + ChatDataManager + SettingUI40TableViewController/BasicSettingTableViewController); loose bundle substring checks removed.
- Deployment target: iOS 15.1 (host MinimumOSVersion)
- Runtime guards: every host class/selector is resolved via NSClassFromString /
  sel_registerName and validated (arity + return encoding) before use; missing
  anchors degrade to a logged no-op — no crash path.
- Multi-account & encryption: per-conversation policies, Private Notes,
  Anti-Recall records/photos, and Quick Replies are scoped by verified accountScope
  (SHA-256 prefix of the active Zalo userId). Sensitive secrets (Bridge Token,
  Discord Webhook) are stored exclusively in iOS Keychain (ZLModSecretStore).
- Tab Bar Material: Zalo opts out of the iOS 26 redesign
  (UIDesignRequiresCompatibility=YES), so ZLMod applies UIBlurEffectStyleSystemUltraThinMaterial
  via ZLModAppearanceCoordinator without referencing UIGlassEffect.
- Not ported by design (no usable iOS mechanism / server-authoritative / unsafe):
  Original Photo Default, ZCloud premium unlock, video transcode bypass,
  server TTL/upload limit override, group admin/owner spoofing, chat-head overlay.
EOF

echo "reports written to $OUTDIR"
