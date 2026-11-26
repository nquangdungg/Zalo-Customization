#!/usr/bin/env python3
"""Behavioral simulation & contract tests for Realtime Pipeline, C-Bridge, CSaving, CDeploy & Discord Relay (Areas 7-9, 15-19)."""

import re
import unittest
from collections import deque
from pathlib import Path
from urllib.parse import urlparse, urlunparse

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"


# ==============================================================================
# Reference models mirroring exact algorithms in ZLModChatEntityAdapter.m,
# ZLModMessageTap.m, and ZLModBridge.m to verify invariants under edge cases.
# ==============================================================================

EXACT_RECALL_PLACEHOLDERS = {
    "tin nhắn đã được thu hồi",
    "tin nhan da duoc thu hoi",
    "tin nhắn đã thu hồi",
    "bạn đã thu hồi một tin nhắn",
    "message has been recalled",
    "this message was recalled",
    "message was recalled",
    "this message has been deleted",
}


def is_placeholder_recalled_text(text: str) -> bool:
    if not text:
        return False
    norm = text.strip().lower().rstrip(".!")
    return norm in EXACT_RECALL_PLACEHOLDERS


def normalize_timestamp(raw_ts: float) -> tuple[float, int]:
    """Mirrors ZLModNormalizeTimestampToSecondsAndMs."""
    if raw_ts <= 0:
        return 0.0, 0
    if raw_ts > 1e11:  # milliseconds
        return raw_ts / 1000.0, int(raw_ts)
    return raw_ts, int(raw_ts * 1000.0)


class BoundedDedupCache:
    """Mirrors bounded LRU dedup used in ZLModMessageTapBus (1000) & ZLModBridge (500)."""

    def __init__(self, capacity: int):
        self.capacity = capacity
        self.seen = set()
        self.order = deque()

    def mark_if_new(self, key: str) -> bool:
        if not key:
            return True
        if key in self.seen:
            return False
        self.seen.add(key)
        self.order.append(key)
        while len(self.order) > self.capacity:
            evicted = self.order.popleft()
            self.seen.discard(evicted)
        return True


def csaving_requeue_failed_batch(failed_batch: list, newer_pending: list, max_pending: int = 50) -> list:
    """Mirrors ZLModBridge.m flushPendingMessages failure branch:
    prepend failed_batch BEFORE newer_pending and drop oldest if > max_pending.
    """
    merged = list(failed_batch) + list(newer_pending)
    if len(merged) > max_pending:
        merged = merged[-max_pending:]
    return merged


def build_bridge_endpoint_url(server_url: str, endpoint_path: str) -> str | None:
    """Mirrors ZLModBuildBridgeEndpointURL using URL components (no stringByAppendingPathComponent)."""
    trimmed = (server_url or "").strip()
    if not trimmed:
        return None
    parsed = urlparse(trimmed)
    if parsed.scheme.lower() not in ("http", "https") or not parsed.hostname:
        return None
    base_path = parsed.path.rstrip("/")
    clean_ep = endpoint_path if endpoint_path.startswith("/") else "/" + endpoint_path
    return urlunparse((parsed.scheme, parsed.netloc, base_path + clean_ep, "", "", ""))


def is_valid_discord_webhook_url(url_str: str) -> bool:
    """Mirrors +[ZLModBridgeManager isValidDiscordWebhookURLString:]."""
    trimmed = (url_str or "").strip()
    if not trimmed:
        return False
    parsed = urlparse(trimmed)
    if parsed.scheme.lower() != "https":
        return False
    allowed_hosts = {"discord.com", "discordapp.com", "ptb.discord.com", "canary.discord.com"}
    if (parsed.hostname or "").lower() not in allowed_hosts:
        return False
    if not parsed.path.startswith("/api/") or "/webhooks/" not in parsed.path:
        return False
    parts = parsed.path.split("/")
    try:
        idx = parts.index("webhooks")
    except ValueError:
        return False
    if idx + 2 >= len(parts):
        return False
    wid, wtok = parts[idx + 1], parts[idx + 2]
    return len(wid) >= 10 and len(wtok) >= 16


class BridgeStateMachine:
    """Mirrors ZLModBridgeManager 4-state FSM + connectionEpoch + exponential backoff + pong timeout."""

    DISCONNECTED = 0
    CONNECTING = 1
    CONNECTED = 2
    CLOSING = 3

    def __init__(self):
        self.status = self.DISCONNECTED
        self.epoch = 0
        self.active_task_id = None
        self.reconnect_attempt = 0
        self.awaiting_pong = False
        self.scheduled_delays = []
        self.is_manual_stop = False
        self.is_in_background = False

    def connect(self) -> tuple[int, int]:
        if self.is_manual_stop or self.is_in_background:
            return self.epoch, -1
        self.epoch += 1
        if self.active_task_id is not None:
            self.status = self.CLOSING
            self.active_task_id = None
        self.status = self.CONNECTING
        self.active_task_id = self.epoch * 100
        self.awaiting_pong = False
        return self.epoch, self.active_task_id

    def on_open(self, task_id: int) -> bool:
        if task_id != self.active_task_id:
            return False  # stale task ignored!
        self.reconnect_attempt = 0
        self.status = self.CONNECTED
        return True

    def send_ping(self) -> int:
        if self.status != self.CONNECTED:
            return -1
        self.awaiting_pong = True
        return self.epoch

    def on_pong(self, epoch: int) -> bool:
        if epoch != self.epoch or self.status != self.CONNECTED:
            return False
        self.awaiting_pong = False
        return True

    def on_pong_timeout(self, epoch: int) -> bool:
        if epoch != self.epoch or not self.awaiting_pong:
            return False
        self.handle_disconnect(epoch)
        return True

    def on_close_or_error(self, task_id: int, epoch: int) -> bool:
        if task_id != self.active_task_id or epoch != self.epoch:
            return False  # stale task ignored!
        self.handle_disconnect(epoch)
        return True

    def handle_disconnect(self, epoch: int):
        if epoch != self.epoch:
            return
        self.awaiting_pong = False
        if self.active_task_id is not None:
            self.status = self.CLOSING
            self.active_task_id = None
        self.status = self.DISCONNECTED
        if not self.is_manual_stop and not self.is_in_background:
            delay = min(30.0, 2.0 * (1 << min(self.reconnect_attempt, 4)))
            self.reconnect_attempt += 1
            self.scheduled_delays.append(delay)

    def enter_background(self):
        self.is_in_background = True
        self.epoch += 1
        self.awaiting_pong = False
        if self.active_task_id is not None:
            self.status = self.CLOSING
            self.active_task_id = None
        self.status = self.DISCONNECTED

    def stop(self):
        self.is_manual_stop = True
        self.epoch += 1
        self.awaiting_pong = False
        if self.active_task_id is not None:
            self.status = self.CLOSING
            self.active_task_id = None
        self.status = self.DISCONNECTED


class RealtimeAndBridgeTests(unittest.TestCase):
    # Area 7: Message normalization — timestamps & exact recall placeholder matching
    def test_07_message_normalization_timestamps_and_exact_recall_matching(self):
        sec, ms = normalize_timestamp(1710000000)
        self.assertAlmostEqual(1710000000.0, sec)
        self.assertEqual(1710000000000, ms)

        sec2, ms2 = normalize_timestamp(1710000000456)
        self.assertAlmostEqual(1710000000.456, sec2)
        self.assertEqual(1710000000456, ms2)

        # Exact placeholders MUST match
        self.assertTrue(is_placeholder_recalled_text("Tin nhắn đã được thu hồi"))
        self.assertTrue(is_placeholder_recalled_text("  Tin nhắn đã được thu hồi. "))
        self.assertTrue(is_placeholder_recalled_text("Message has been recalled"))

        # Normal sentences containing the words "thu hồi" or "recalled" MUST NOT false-positive!
        self.assertFalse(is_placeholder_recalled_text("Bạn ơi đừng thu hồi tin nhắn nhé"))
        self.assertFalse(is_placeholder_recalled_text("Hôm qua tôi recalled lại bài học"))
        self.assertFalse(is_placeholder_recalled_text("Lệnh thu hồi sản phẩm đã ban hành"))

        adapter_src = (SOURCES / "ZLModChatEntityAdapter.m").read_text(encoding="utf-8")
        self.assertIn("isPlaceholderRecalledText:", adapter_src)
        self.assertIn("rawTs > 100000000000.0", adapter_src)

    # Area 8: Message deduplication — bounded LRU separating observed vs recalled
    def test_08_message_dedup_bounded_lru_and_event_separation(self):
        cache = BoundedDedupCache(capacity=3)
        self.assertTrue(cache.mark_if_new("obs:u1:0:t1:100"))
        self.assertFalse(cache.mark_if_new("obs:u1:0:t1:100"))
        # Recall of same message MUST NOT be dropped by observed dedup!
        self.assertTrue(cache.mark_if_new("recall:u1:0:t1:100"))
        self.assertFalse(cache.mark_if_new("recall:u1:0:t1:100"))

        # Capacity bound evicts oldest
        self.assertTrue(cache.mark_if_new("obs:u1:0:t1:101"))
        self.assertTrue(cache.mark_if_new("obs:u1:0:t1:102"))
        self.assertEqual(3, len(cache.seen))
        self.assertTrue(cache.mark_if_new("obs:u1:0:t1:100"))  # evicted earlier -> accepted again

        tap_src = (SOURCES / "ZLModMessageTap.m").read_text(encoding="utf-8")
        bridge_src = (SOURCES / "ZLModBridge.m").read_text(encoding="utf-8")
        self.assertIn("kZLModMessageTapDedupCapacity", tap_src)
        self.assertIn("kZLModBridgeDedupCapacity", bridge_src)

    # Area 9: Message ordering — CSaving failed batch prepended before newer messages & capped at 50
    def test_09_csaving_failed_batch_preserves_chronological_order_and_cap(self):
        failed = [{"id": 1}, {"id": 2}, {"id": 3}]
        newer = [{"id": 4}, {"id": 5}]
        requeued = csaving_requeue_failed_batch(failed, newer, max_pending=50)
        self.assertEqual([1, 2, 3, 4, 5], [m["id"] for m in requeued])

        # Cap enforcement trims oldest first while keeping newest chronological tail
        big_failed = [{"id": i} for i in range(1, 41)]
        big_newer = [{"id": i} for i in range(41, 61)]
        capped = csaving_requeue_failed_batch(big_failed, big_newer, max_pending=50)
        self.assertEqual(50, len(capped))
        self.assertEqual(list(range(11, 61)), [m["id"] for m in capped])

        bridge_src = (SOURCES / "ZLModBridge.m").read_text(encoding="utf-8")
        self.assertIn("[merged addObjectsFromArray:batch];", bridge_src)
        self.assertIn("[merged addObjectsFromArray:strongSelf.pendingMessages];", bridge_src)

    # Area 15: WebSocket 4-state FSM & session teardown
    def test_15_websocket_fsm_transitions_and_session_lifecycle(self):
        fsm = BridgeStateMachine()
        self.assertEqual(fsm.DISCONNECTED, fsm.status)
        ep1, t1 = fsm.connect()
        self.assertEqual(fsm.CONNECTING, fsm.status)
        self.assertTrue(fsm.on_open(t1))
        self.assertEqual(fsm.CONNECTED, fsm.status)
        fsm.enter_background()
        self.assertEqual(fsm.DISCONNECTED, fsm.status)
        self.assertEqual([], fsm.scheduled_delays)  # background must NOT trigger reconnect loop

        bridge_h = (SOURCES / "ZLModBridge.h").read_text(encoding="utf-8")
        bridge_m = (SOURCES / "ZLModBridge.m").read_text(encoding="utf-8")
        self.assertIn("ZLModBridgeStatusClosing", bridge_h)
        self.assertIn("invalidateAndCancel", bridge_m)
        self.assertIn("NSURLSessionWebSocketCloseCodeGoingAway", bridge_m)

    # Area 16: Reconnect race guard (connectionEpoch) & exponential backoff 2->4->8->16->30
    def test_16_reconnect_stale_task_race_guard_and_exponential_backoff(self):
        fsm = BridgeStateMachine()
        ep1, t1 = fsm.connect()
        # Immediately reconnect -> spawns ep2/t2 while t1 is cancelled
        ep2, t2 = fsm.connect()
        self.assertTrue(fsm.on_open(t2))
        self.assertEqual(fsm.CONNECTED, fsm.status)

        # Late error callback from stale t1 MUST BE IGNORED!
        self.assertFalse(fsm.on_close_or_error(t1, ep1))
        self.assertEqual(fsm.CONNECTED, fsm.status)
        self.assertEqual([], fsm.scheduled_delays)

        # Repeated failures on active epochs follow exponential backoff capped at 30s
        for _ in range(6):
            ep, task = fsm.connect()
            self.assertTrue(fsm.on_close_or_error(task, ep))
        self.assertEqual([2.0, 4.0, 8.0, 16.0, 30.0, 30.0], fsm.scheduled_delays)

        # Successful connection resets backoff attempt counter to 0
        ep_ok, t_ok = fsm.connect()
        self.assertTrue(fsm.on_open(t_ok))
        self.assertEqual(0, fsm.reconnect_attempt)

        bridge_m = (SOURCES / "ZLModBridge.m").read_text(encoding="utf-8")
        self.assertIn("connectionEpoch", bridge_m)
        self.assertIn("kZLModBridgeReconnectMinSec", bridge_m)
        self.assertIn("kZLModBridgeReconnectMaxSec", bridge_m)

    # Area 17: Heartbeat 20s + Pong timeout 10s
    def test_17_heartbeat_and_pong_timeout_detection(self):
        fsm = BridgeStateMachine()
        ep, t = fsm.connect()
        fsm.on_open(t)
        ping_ep = fsm.send_ping()
        self.assertTrue(fsm.awaiting_pong)
        self.assertTrue(fsm.on_pong(ping_ep))
        self.assertFalse(fsm.awaiting_pong)
        # Timeout after pong already arrived is a no-op
        self.assertFalse(fsm.on_pong_timeout(ping_ep))
        self.assertEqual(fsm.CONNECTED, fsm.status)

        # Missing pong triggers disconnect + backoff
        ping_ep2 = fsm.send_ping()
        self.assertTrue(fsm.on_pong_timeout(ping_ep2))
        self.assertEqual(fsm.DISCONNECTED, fsm.status)
        self.assertEqual([2.0], fsm.scheduled_delays)

        bridge_m = (SOURCES / "ZLModBridge.m").read_text(encoding="utf-8")
        self.assertIn("startPongTimeoutForEpoch:", bridge_m)
        self.assertIn("kZLModBridgePongTimeoutSec", bridge_m)

    # Area 18: CPairing URL construction, Bonjour LAN discovery, CDeploy allowlist & ACK
    def test_18_cpairing_url_bonjour_cdeploy_allowlist_and_ack(self):
        # Verify URL building preserves http://host:port cleanly (fixes stringByAppendingPathComponent bug!)
        self.assertEqual(
            "http://192.168.1.15:3000/api/cbridge/health",
            build_bridge_endpoint_url("http://192.168.1.15:3000", "/api/cbridge/health"),
        )
        self.assertEqual(
            "https://bridge.local:8443/sub/api/cbridge/health",
            build_bridge_endpoint_url("https://bridge.local:8443/sub/", "/api/cbridge/health"),
        )
        self.assertIsNone(build_bridge_endpoint_url("ftp://192.168.1.15:3000", "/api/cbridge/health"))
        self.assertIsNone(build_bridge_endpoint_url("not-a-url", "/api/cbridge/health"))

        bridge_m = (SOURCES / "ZLModBridge.m").read_text(encoding="utf-8")
        prefs_m = (SOURCES / "ZLModPreferences.m").read_text(encoding="utf-8")
        self.assertNotIn("stringByAppendingPathComponent:@\"/api/cbridge/health\"", bridge_m)
        self.assertIn("ZLModBuildBridgeEndpointURL", bridge_m)
        self.assertIn("NSNetServiceBrowser", bridge_m)
        self.assertIn("startLANDiscoveryWithCompletion:", bridge_m)
        self.assertIn("remoteDeployAllowedKeys", prefs_m)
        self.assertIn("applyRemoteSettingsBatch:settings allowedKeys:allowedKeys", bridge_m)
        self.assertIn("presenter_unavailable", bridge_m)
        self.assertIn("cdeploy_upload_ack", bridge_m)

        # Ensure secret/connection keys are NEVER in remoteDeployAllowedKeys block
        match = re.search(r"remoteDeployAllowedKeys\s*\{(.*?)\n\}", prefs_m, re.DOTALL)
        self.assertIsNotNone(match)
        allowlist_body = match.group(1)
        for forbidden in ("kZLModBridgeServerURL", "kZLModBridgeToken", "kZLModBridgeWebhook"):
            self.assertNotIn(forbidden, allowlist_body)

    # Area 19: Discord Webhook domain validation & automatic relay
    def test_19_discord_webhook_validation_and_automatic_relay(self):
        valid = "https://discord.com/api/webhooks/123456789012345678/abcdefghijklmnopqrstuvwxyz123456"
        valid_ptb = "https://ptb.discord.com/api/v10/webhooks/123456789012345678/abcdefghijklmnopqrstuvwxyz123456"
        self.assertTrue(is_valid_discord_webhook_url(valid))
        self.assertTrue(is_valid_discord_webhook_url(valid_ptb))

        # Reject non-HTTPS, non-Discord domains, short IDs/tokens, missing /webhooks/
        self.assertFalse(is_valid_discord_webhook_url("http://discord.com/api/webhooks/123456789012345678/abcdefghijklmnopqrstuvwxyz"))
        self.assertFalse(is_valid_discord_webhook_url("https://evil-discord.com/api/webhooks/123456789012345678/abcdefghijklmnopqrstuvwxyz"))
        self.assertFalse(is_valid_discord_webhook_url("https://discord.com/api/webhooks/123/short"))
        self.assertFalse(is_valid_discord_webhook_url("https://discord.com/channels/123/456"))

        bridge_m = (SOURCES / "ZLModBridge.m").read_text(encoding="utf-8")
        self.assertIn("isValidDiscordWebhookURLString:", bridge_m)
        self.assertIn("enqueueNormalizedModelForDiscordRelay:", bridge_m)
        self.assertIn("drainDiscordQueue", bridge_m)
        self.assertIn("Retry-After", bridge_m)
        self.assertIn("kZLModDiscordMinIntervalSec", bridge_m)


if __name__ == "__main__":
    unittest.main()
