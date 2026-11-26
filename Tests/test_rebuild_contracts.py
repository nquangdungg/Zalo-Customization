#!/usr/bin/env python3
"""Comprehensive contract & architectural tests for ZLMod Build 11 rebuild (Areas 1-6, 10-14, 20)."""

import importlib.util
import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"
RESOURCES = ROOT / "Resources"
SCRIPTS = ROOT / "Scripts"


class RebuildContractsTests(unittest.TestCase):
    # Area 1: Compatibility — single unified evaluator, zero loose substring bypass
    def test_01_compatibility_unified_evaluator_and_no_loose_substring_bypass(self):
        compat = (SOURCES / "ZLModCompatibility.m").read_text(encoding="utf-8")
        self.assertIn("ZLModEvaluateHostCompatibility", compat)
        self.assertIn("ZLModHasVerifiedRuntimeAnchorQuorum", compat)
        self.assertIn("ZaloTabBarViewController", compat)
        self.assertIn("ChatDataManager", compat)
        # Must NOT contain the old loose substring bypass on bundle ID
        self.assertNotIn('containsString:@"zalo"', compat)
        self.assertNotIn('containsString:@"zing"', compat)

    # Area 2: Version Single Source of Truth consistency
    def test_02_version_single_source_of_truth(self):
        version_json = json.loads((RESOURCES / "version.json").read_text(encoding="utf-8"))
        self.assertIn("version", version_json)
        self.assertIn("buildNumber", version_json)
        self.assertIn("buildLabel", version_json)
        self.assertIn("tag", version_json)

        # Regenerate into temp file and verify exact match with checked-in ZLModVersionData.h
        gen_script = SCRIPTS / "generate_version.py"
        with tempfile.TemporaryDirectory() as tmp:
            out_h = Path(tmp) / "ZLModVersionData.h"
            res = subprocess.run(
                [sys.executable, str(gen_script), str(RESOURCES / "version.json"), str(out_h)],
                text=True,
                capture_output=True,
            )
            self.assertEqual(0, res.returncode, res.stderr)
            expected = out_h.read_text(encoding="utf-8")
        actual = (SOURCES / "ZLModVersionData.h").read_text(encoding="utf-8")
        self.assertEqual(expected, actual)

        # Verify invalid version manifest is rejected
        with tempfile.TemporaryDirectory() as tmp:
            bad_json = Path(tmp) / "bad.json"
            bad_json.write_text(json.dumps({"version": "4.0"}), encoding="utf-8")
            bad_res = subprocess.run(
                [sys.executable, str(gen_script), str(bad_json), str(Path(tmp) / "out.h")],
                text=True,
                capture_output=True,
            )
            self.assertNotEqual(0, bad_res.returncode)

        # Verify Makefile, report.sh, and release.yml stay aligned with version.json
        makefile = (ROOT / "Makefile").read_text(encoding="utf-8")
        self.assertIn("Resources/version.json", makefile)
        self.assertIn("Scripts/generate_version.py", makefile)
        self.assertIn("Sources/ZLModVersionData.h", makefile)

        release_yml = (ROOT / ".github" / "workflows" / "release.yml").read_text(encoding="utf-8")
        self.assertIn(f'default: "{version_json["tag"]}"', release_yml)

        report_sh = (SCRIPTS / "report.sh").read_text(encoding="utf-8")
        self.assertIn("Resources/version.json", report_sh)
        self.assertNotIn("build-5", report_sh)

    # Area 3: Secret persistence — Keychain-only, zero plaintext in NSUserDefaults/URLs
    def test_03_secret_persistence_keychain_only(self):
        crypto = (SOURCES / "ZLModCryptoStore.m").read_text(encoding="utf-8")
        prefs = (SOURCES / "ZLModPreferences.m").read_text(encoding="utf-8")
        bridge = (SOURCES / "ZLModBridge.m").read_text(encoding="utf-8")
        core = (SOURCES / "ZLModCore.m").read_text(encoding="utf-8")

        self.assertIn("@implementation ZLModSecretStore", crypto)
        self.assertIn("kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly", crypto)
        self.assertIn("secretPreferenceKeys", prefs)
        self.assertIn("migrateLegacySecretsToKeychainIfNeeded", prefs)
        self.assertIn("migrateLegacySecretsToKeychainIfNeeded", core)
        self.assertIn("[[ZLModSecretStore shared] setSecret:", prefs)
        self.assertIn("[[ZLModSecretStore shared] secretForKey:", prefs)
        self.assertIn("[self.own removeObjectForKey:secretKey];", prefs)
        self.assertIn("[self.standard removeObjectForKey:secretKey];", prefs)

        # WebSocket must send token via Authorization Bearer header, NEVER query param token=
        self.assertIn('forHTTPHeaderField:@"Authorization"', bridge)
        self.assertNotIn("token=%@", bridge)

    # Area 4: Keychain failure & Storage Health explicit reporting
    def test_04_keychain_failure_and_storage_health_reporting(self):
        crypto = (SOURCES / "ZLModCryptoStore.m").read_text(encoding="utf-8")
        ui = (SOURCES / "ZLModUI.m").read_text(encoding="utf-8")

        self.assertIn("ZLModCurrentStorageHealth", crypto)
        self.assertIn("ZLModStorageHealthReady", crypto)
        self.assertIn("ZLModStorageHealthAccountUnidentified", crypto)
        self.assertIn("ZLModStorageHealthKeychainUnavailable", crypto)
        self.assertIn("lastKeychainStatus", crypto)

        # UI must render warning banner instead of disguising failures as empty states
        self.assertIn("ZLModStorageHealthHeaderViewForWidth", ui)
        self.assertIn("ZLModStorageHealthDescription()", ui)

    # Area 5: Preferences batch updates, coalesced notifications & zero deprecated synchronize
    def test_05_preferences_batch_reset_and_no_deprecated_synchronize(self):
        prefs = (SOURCES / "ZLModPreferences.m").read_text(encoding="utf-8")
        self.assertIn("performBatchUpdates:", prefs)
        self.assertIn("applyRemoteSettingsBatch:", prefs)
        self.assertIn("allowedKeys:", prefs)
        self.assertIn("ZLModPrefsChangedKeysUserInfoKey", prefs)
        self.assertIn("clearAllSecrets", prefs)
        self.assertNotIn("synchronize]", prefs)

    # Area 6: Account switch invalidation across all stores & caches
    def test_06_account_switch_invalidation(self):
        core = (SOURCES / "ZLModCore.m").read_text(encoding="utf-8")
        anti = (SOURCES / "ZLModAntiRecall.m").read_text(encoding="utf-8")
        bridge = (SOURCES / "ZLModBridge.m").read_text(encoding="utf-8")
        utils = (SOURCES / "ZLModUtilities.m").read_text(encoding="utf-8")

        self.assertIn("ZLModInvalidateCachedAccountScope()", core)
        self.assertIn("[ZLModPrivacyContext clearActiveContext]", core)
        self.assertIn("[[ZLModMessageTapBus shared] clearDedupCache]", core)
        self.assertIn("ZLModAccountDidChangeNotification", anti)
        self.assertIn("purgeLiveSnapshots", anti)
        self.assertIn("handleAccountChanged", bridge)
        self.assertIn("ZLModAccountDidChangeNotification", utils)

    # Area 10: Anti-Recall decoupled, leak-free LRU, non-mutating, cell reuse cleanup
    def test_10_anti_recall_decoupled_leakfree_and_reuse_safe(self):
        anti = (SOURCES / "ZLModAntiRecall.m").read_text(encoding="utf-8")
        tap = (SOURCES / "ZLModMessageTap.m").read_text(encoding="utf-8")

        # Subscribed to ZLModMessageTapBus instead of posting ZLModChatEntityArrivedNotification
        self.assertIn("ZLModMessageTapBus", anti)
        self.assertNotIn("ZLModChatEntityArrivedNotification", anti)
        self.assertNotIn("set_originTextRecallMsg:", anti)
        self.assertNotIn("ZLModPresentRecalledMessageContent", anti)

        # Evicts BOTH primaryKey and altKey atomically
        self.assertIn("oldest.primaryKey", anti)
        self.assertIn("oldest.altKey", anti)

        # Cleans cell reuse associated labels on BOTH UITableViewCell & UICollectionViewCell
        self.assertIn("ZLModCleanupAssociatedRecallLabelsInView", anti)
        self.assertIn("[UITableViewCell class]", anti)
        self.assertIn("[UICollectionViewCell class]", anti)

        # MessageTap active when ANY of AntiRecall, CSaving, or DiscordRelay is ON
        self.assertIn("kZLModAntiRecall", tap)
        self.assertIn("kZLModBridgeSaving", tap)
        self.assertIn("kZLModBridgeDiscordRelay", tap)

    # Area 11: Recalled photo encrypted disk persistence & quota/TTL
    def test_11_recalled_photo_encrypted_disk_persistence(self):
        anti = (SOURCES / "ZLModAntiRecall.m").read_text(encoding="utf-8")
        self.assertIn("ZLModRecallPhotos", anti)
        self.assertIn("encryptData:", anti)
        self.assertIn("decryptRawData:", anti)
        self.assertIn("enforcePhotoQuotaAsync", anti)
        self.assertIn("kZLModAntiRecallMaxPhotoBytes", anti)
        self.assertIn("ZLModWriteDataAsync", anti)
        self.assertIn("deletePhotoFilesAsync:", anti)

    # Area 12: Delay Send 5-state FSM, multi-item queue, keyboard awareness & failure handling
    def test_12_delay_send_fsm_multi_item_and_keyboard_aware(self):
        utils = (SOURCES / "ZLModUtilities.m").read_text(encoding="utf-8")
        for state in (
            "ZLModDelaySendStatePending",
            "ZLModDelaySendStateCancelled",
            "ZLModDelaySendStateDispatching",
            "ZLModDelaySendStateDispatched",
            "ZLModDelaySendStateFailed",
        ):
            self.assertIn(state, utils)
        self.assertIn("UIKeyboardWillChangeFrameNotification", utils)
        self.assertIn("UIKeyboardWillHideNotification", utils)
        self.assertIn("cancelAllPendingSends", utils)
        self.assertIn("Hủy hết", utils)

    # Area 13: Quick Replies account-scoped, dedup, 1-tap chat picker, never auto-sends
    def test_13_quick_replies_account_scoped_and_inchat_picker(self):
        utils = (SOURCES / "ZLModUtilities.m").read_text(encoding="utf-8")
        ui = (SOURCES / "ZLModUI.m").read_text(encoding="utf-8")
        self.assertIn("ZLModPresentQuickReplyPicker", utils)
        self.assertIn("kZLModMaxQuickRepliesCount", utils)
        self.assertIn("templatesByAccount", utils)
        self.assertIn("Khôi phục mẫu câu mặc định?", ui)

    # Area 14: Private Notes multi-line editor + encrypted display titles
    def test_14_private_notes_multiline_and_encrypted_titles(self):
        utils = (SOURCES / "ZLModUtilities.m").read_text(encoding="utf-8")
        policy = (SOURCES / "ZLModPolicyStore.m").read_text(encoding="utf-8")
        ui = (SOURCES / "ZLModUI.m").read_text(encoding="utf-8")

        self.assertIn("ZLModPrivateNoteEditorViewController", utils)
        self.assertIn("UITextView", utils)
        self.assertIn("titleCipher", utils)
        self.assertIn("titleCipher", policy)
        self.assertIn("displayTitle", ui)
        self.assertIn("countForCurrentAccount", ui)

    # Area 20: UI state propagation, Appearance Coordinator, reversible Ads/Firebase, safe Settings
    def test_20_ui_propagation_coordinator_and_safety(self):
        ui = (SOURCES / "ZLModUI.m").read_text(encoding="utf-8")
        theme = (SOURCES / "ZLModTheme.m").read_text(encoding="utf-8")
        glass = (SOURCES / "ZLModGlass.m").read_text(encoding="utf-8")
        settings = (SOURCES / "ZLModSettings.m").read_text(encoding="utf-8")
        ads = (SOURCES / "ZLModAds.m").read_text(encoding="utf-8")
        privacy = (SOURCES / "ZLModPrivacy.m").read_text(encoding="utf-8")
        uri = (SOURCES / "ZLModURIFilter.m").read_text(encoding="utf-8")

        # S02 must NOT manually post duplicate ZLModPrefsDidChangeNotification or redundant [mgr reconnect]
        s02_slice = ui.split("#pragma mark - S03:")[0]
        self.assertNotIn("postNotificationName:ZLModPrefsDidChangeNotification", s02_slice)
        self.assertNotIn("[mgr reconnect]", s02_slice)
        self.assertIn("dequeueReusableCellWithIdentifier:", s02_slice)
        self.assertIn("UIActivityIndicatorView", ui)
        self.assertIn("UIRefreshControl", ui)

        # S01 observes Bridge & Prefs changes and validates hex tint
        self.assertIn("name:ZLModBridgeStatusDidChangeNotification", ui)
        self.assertIn("![mgr applyCustomTintHex:hex]", ui)

        # Unified Appearance Coordinator
        self.assertIn("@implementation ZLModAppearanceCoordinator", theme)
        self.assertIn("[ZLModAppearanceCoordinator shared]", glass)
        self.assertNotIn("UIGlassEffect", glass)

        # Safe Settings (no memcpy/CFRetain, per-VC state, undo-safe shake gesture)
        self.assertNotIn("memcpy(", settings)
        self.assertNotIn("CFRetain(", settings)
        self.assertIn("ZLModSettingsVCState", settings)
        self.assertIn("kZLModDisableShakeToOpen", settings)
        self.assertIn("ZLModIsAnyTextInputActive()", settings)

        # Reversible Ads & Firebase + NSURLSession URLProtocol coverage
        self.assertIn("ZLModRefreshAllTrackedAdViews", ads)
        self.assertIn("setAnalyticsCollectionEnabled:", privacy)
        self.assertIn("defaultSessionConfiguration", uri)
        self.assertIn("ephemeralSessionConfiguration", uri)
        self.assertIn("Upgrade", uri)


if __name__ == "__main__":
    unittest.main()
