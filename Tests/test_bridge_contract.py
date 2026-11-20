#!/usr/bin/env python3
"""Contract tests for ZLMod C-Bridge client (CPairing, CSaving, CDeploy)."""

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCES = ROOT / "Sources"


class BridgeContractTests(unittest.TestCase):
    def test_bridge_sources_exist(self):
        self.assertTrue((SOURCES / "ZLModBridge.h").is_file())
        self.assertTrue((SOURCES / "ZLModBridge.m").is_file())

    def test_preference_keys_declared_and_defined(self):
        header = (SOURCES / "ZLMod.h").read_text(encoding="utf-8")
        prefs = (SOURCES / "ZLModPreferences.m").read_text(encoding="utf-8")

        keys = [
            "kZLModBridgeServerURL",
            "kZLModBridgeToken",
            "kZLModBridgeWebhook",
            "kZLModBridgeSaving",
            "kZLModBridgeLastSync",
        ]
        for key in keys:
            self.assertIn(f"extern NSString *const {key};", header)
            self.assertIn(f"NSString *const {key}", prefs)
            self.assertIn(key, prefs)

    def test_bridge_installer_registered_in_core(self):
        header = (SOURCES / "ZLMod.h").read_text(encoding="utf-8")
        core = (SOURCES / "ZLModCore.m").read_text(encoding="utf-8")

        self.assertIn("void ZLModBridgeInstall(void);", header)
        self.assertIn('ZLModRunInstaller(@"Bridge", ZLModBridgeInstall);', core)

    def test_bridge_ui_integrated_in_dashboard(self):
        ui = (SOURCES / "ZLModUI.m").read_text(encoding="utf-8")

        self.assertIn('#import "ZLModBridge.h"', ui)
        self.assertIn("@interface ZLModBridgeViewController : UITableViewController", ui)
        self.assertIn("@implementation ZLModBridgeViewController", ui)
        self.assertIn('@"C-Bridge & Local Server"', ui)
        self.assertIn('@"bridge_settings"', ui)
        self.assertIn("ZLModBridgeViewController *vc = [[ZLModBridgeViewController alloc]", ui)

    def test_cdeploy_requires_user_confirmation_dialog(self):
        bridge_m = (SOURCES / "ZLModBridge.m").read_text(encoding="utf-8")

        # Must present UIAlertController on main thread before applying settings
        self.assertIn("handleDeployPushSettings", bridge_m)
        self.assertIn("UIAlertControllerStyleAlert", bridge_m)
        self.assertIn("Chấp nhận", bridge_m)
        self.assertIn("Từ chối", bridge_m)
        self.assertIn("cdeploy_ack", bridge_m)
        self.assertIn("ZLModTopPresenterViewController()", bridge_m)

    def test_csaving_bounded_buffer_and_deduplication(self):
        bridge_m = (SOURCES / "ZLModBridge.m").read_text(encoding="utf-8")

        # Bounded buffer to prevent memory exhaustion
        self.assertIn("kZLModMaxPendingMessages", bridge_m)
        self.assertIn("pendingMessages.count >= kZLModMaxPendingMessages", bridge_m)
        self.assertIn("identityKey", bridge_m)
        self.assertIn("csaving", bridge_m)

    def test_cpairing_and_websocket_heartbeat(self):
        bridge_m = (SOURCES / "ZLModBridge.m").read_text(encoding="utf-8")

        self.assertIn("NSURLSessionWebSocketTask", bridge_m)
        self.assertIn("kZLModHeartbeatInterval", bridge_m)
        self.assertIn("sendHeartbeatPing", bridge_m)
        self.assertIn("testPairingWithCompletion", bridge_m)


if __name__ == "__main__":
    unittest.main()
