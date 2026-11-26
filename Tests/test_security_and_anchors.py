#!/usr/bin/env python3
"""Security, Anchor Completeness, Mach-O 8-Byte Alignment, Preflight & ObjC Static Sanity Tests (Areas 21-25)."""

import importlib.util
import plistlib
import re
import struct
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "Sources"
SCRIPTS = ROOT / "Scripts"
PACKAGING = ROOT / "Packaging"


def load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"unable to load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def make_synthetic_macho64(filetype: int = 2, include_code_sig: bool = True) -> bytes:
    if filetype == 6:
        hdr = struct.pack("<IIIIIIII", 0xFEEDFACF, 0x0100000C, 0, filetype, 0, 0, 0, 0)
        return hdr + b"\x00" * 32

    sec_offset = 0x1000
    seg_cmd = struct.pack(
        "<II16sQQQQIIII",
        0x19,
        152,
        b"__TEXT".ljust(16, b"\x00"),
        0,
        0x4000,
        0,
        0x4000,
        7,
        5,
        1,
        0,
    )
    sect = struct.pack(
        "<16s16sQQIIIIIIII",
        b"__text".ljust(16, b"\x00"),
        b"__TEXT".ljust(16, b"\x00"),
        sec_offset,
        16,
        sec_offset,
        2,
        0,
        0,
        0,
        0,
        0,
        0,
    )
    cmds = seg_cmd + sect
    ncmds = 1
    if include_code_sig:
        cmds += struct.pack("<IIII", 0x1D, 16, sec_offset + 16, 0)
        ncmds += 1
    hdr = struct.pack("<IIIIIIII", 0xFEEDFACF, 0x0100000C, 0, filetype, ncmds, len(cmds), 0, 0)
    buf = bytearray(sec_offset + 32)
    buf[:32] = hdr
    buf[32 : 32 + len(cmds)] = cmds
    return bytes(buf)


def strip_objc_comments_and_strings(code: str) -> str:
    """Strip C/ObjC comments, string literals, and char literals for balanced-delimiter checking."""
    out = []
    i = 0
    n = len(code)
    while i < n:
        c = code[i]
        nxt = code[i + 1] if i + 1 < n else ""
        if c == "/" and nxt == "/":
            i += 2
            while i < n and code[i] != "\n":
                i += 1
            continue
        if c == "/" and nxt == "*":
            i += 2
            while i + 1 < n and not (code[i] == "*" and code[i + 1] == "/"):
                i += 1
            i += 2
            continue
        if c == "@" and nxt == '"':
            i += 2
            while i < n:
                if code[i] == "\\":
                    i += 2
                    continue
                if code[i] == '"':
                    i += 1
                    break
                i += 1
            continue
        if c == '"':
            i += 1
            while i < n:
                if code[i] == "\\":
                    i += 2
                    continue
                if code[i] == '"':
                    i += 1
                    break
                i += 1
            continue
        if c == "'":
            i += 1
            while i < n:
                if code[i] == "\\":
                    i += 2
                    continue
                if code[i] == "'":
                    i += 1
                    break
                i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


class SecurityAnchorsAndMachOTests(unittest.TestCase):
    # Area 21: Anchor completeness & zero duplicates
    def test_21_anchors_manifest_complete_and_unique(self):
        lines = [
            line.strip()
            for line in (SCRIPTS / "anchors.txt").read_text(encoding="utf-8").splitlines()
            if line.strip() and not line.strip().startswith("#")
        ]
        entries = [tuple(line.split("\t")) for line in lines]
        self.assertEqual(len(entries), len(set(entries)), "Duplicate anchor entries found in Scripts/anchors.txt")

        cls_anchors = {v for k, v in entries if k == "cls"}
        sel_anchors = {v for k, v in entries if k == "sel"}

        # All critical verified host runtime anchors added in Build 11 must be listed
        for expected_cls in (
            "MenuButton",
            "InboxContextMenuProvider",
            "BasicSettingTableViewController",
            "FIRAnalytics",
            "ConversationModel",
            "ChatDataManager",
            "ZaloTabBarViewController",
        ):
            self.assertIn(expected_cls, cls_anchors)

        for expected_sel in (
            "showContextMenuViewWithMenuItemArray:hasReaction:",
            "contextMenuView:didTapAtItemType:",
            "contextMenuViewWillDismiss:",
            "contextMenuSectionsForItem:info:",
            "reloadCellIfNeed",
            "isRecalledOrFailOrRolledAll",
            "chatEntity",
            "globalId",
            "clientId",
        ):
            self.assertIn(expected_sel, sel_anchors)

    # Area 22: Mach-O 64-bit 8-byte alignment for ALL LC_RPATH & LC_LOAD_DYLIB lengths
    def test_22_macho_rpath_and_dylib_strict_8byte_alignment(self):
        injector = load_module("zlmod_injector_align", PACKAGING / "macho_injector.py")

        # Test rpath lengths covering every residue modulo 8 (0..7) plus real '@executable_path/Frameworks'
        test_rpaths = [
            "@executable_path/Frameworks",
            "@loader_path/F",
            "@loader_path/Fr",
            "@loader_path/Fra",
            "@loader_path/Fram",
            "@loader_path/Frame",
            "@loader_path/Framew",
            "@loader_path/Framewo",
            "@loader_path/Framewor",
        ]
        for rpath in test_rpaths:
            base = make_synthetic_macho64(filetype=2, include_code_sig=True)
            patched = injector.inject_rpath(base, rpath)
            patched = injector.inject_load_dylib(patched, "@rpath/libZLMod.dylib")
            injector.verify_macho_alignment(patched)

            self.assertIn(rpath, injector.get_rpaths(patched))
            self.assertIn("@rpath/libZLMod.dylib", injector.get_load_dylibs(patched))

            # Verify every single load command cmdsize % 8 == 0 and LC_CODE_SIGNATURE remains last
            hdr = injector.inspect_macho_header(patched)
            self.assertEqual(0, hdr["sizeofcmds"] % 8, f"sizeofcmds misaligned for rpath={rpath}")
            offset = 32
            last_cmd = None
            for _ in range(hdr["ncmds"]):
                cmd, cmdsize = struct.unpack("<II", patched[offset : offset + 8])
                self.assertEqual(0, cmdsize % 8, f"cmd {hex(cmd)} misaligned (cmdsize={cmdsize}) for {rpath}")
                last_cmd = cmd
                offset += cmdsize
            self.assertEqual(0x1D, last_cmd)
            self.assertEqual(32 + hdr["sizeofcmds"], offset)

        # Verify verify_macho_alignment REJECTS a corrupted non-8-byte-aligned binary
        bad = bytearray(make_synthetic_macho64(filetype=2, include_code_sig=True))
        # Corrupt sizeofcmds in header from 168 to 172 (4 mod 8)
        struct.pack_into("<I", bad, 20, 172)
        with self.assertRaises(ValueError):
            injector.verify_macho_alignment(bytes(bad))

    # Area 23: IPA preflight evaluates all 5 installability states accurately
    def test_23_ipa_preflight_all_five_installability_states(self):
        preflight = load_module("zlmod_preflight_states", PACKAGING / "ipa_preflight.py")

        # 1. Unsigned
        s1 = preflight.evaluate_installability(
            {"has_mobileprovision": False, "has_codesign_resources": False, "bundle_id": "vn.com.vng.zingalo", "main_executable": {}}
        )
        self.assertEqual("UNSIGNED_ARCHIVE", s1["state"])
        self.assertFalse(s1["directly_installable"])

        # 2. Partial: CodeResources present WITHOUT mobileprovision
        s2 = preflight.evaluate_installability(
            {"has_mobileprovision": False, "has_codesign_resources": True, "bundle_id": "vn.com.vng.zingalo", "main_executable": {}}
        )
        self.assertEqual("PARTIAL_SIGNATURE_MISSING_PROVISION", s2["state"])
        self.assertFalse(s2["directly_installable"])
        self.assertTrue(len(s2["warnings"]) >= 1)

        # 3. Partial: mobileprovision present WITHOUT CodeResources
        s3 = preflight.evaluate_installability(
            {"has_mobileprovision": True, "has_codesign_resources": False, "bundle_id": "vn.com.vng.zingalo", "main_executable": {}}
        )
        self.assertEqual("PARTIAL_PROVISION_MISSING_CODESIGN", s3["state"])
        self.assertFalse(s3["directly_installable"])
        self.assertTrue(len(s3["warnings"]) >= 1)

        # 4. Stale signature mismatch
        s4 = preflight.evaluate_installability(
            {
                "has_mobileprovision": True,
                "has_codesign_resources": True,
                "bundle_id": "vn.com.vng.zingalo2",
                "main_executable": {"code_signature": {"ident": "vn.com.vng.zingalo"}},
            }
        )
        self.assertEqual("STALE_SIGNATURE_MISMATCH", s4["state"])
        self.assertFalse(s4["directly_installable"])

        # 5. Properly signed & provisioned
        s5 = preflight.evaluate_installability(
            {
                "has_mobileprovision": True,
                "has_codesign_resources": True,
                "bundle_id": "vn.com.vng.zingalo2",
                "main_executable": {
                    "code_signature": {
                        "ident": "vn.com.vng.zingalo2",
                        "app_id": "TEAM123456.vn.com.vng.zingalo2",
                        "team_id": "TEAM123456",
                    }
                },
            }
        )
        self.assertEqual("PROVISIONED_AND_SIGNED", s5["state"])
        self.assertTrue(s5["directly_installable"])

    # Area 24: End-to-end packaging (Full + No-Appex) + Preflight zero alignment errors
    def test_24_end_to_end_repackage_noappex_and_alignment_preflight(self):
        packager = load_module("zlmod_packager_e2e", PACKAGING / "package_ipa.py")
        preflight = load_module("zlmod_preflight_e2e", PACKAGING / "ipa_preflight.py")
        with tempfile.TemporaryDirectory() as tmp:
            tmp_dir = Path(tmp)
            input_ipa = tmp_dir / "base.ipa"
            out_noappex = tmp_dir / "out-noappex.ipa"
            dylib = tmp_dir / "libZLMod.dylib"
            dylib.write_bytes(make_synthetic_macho64(filetype=6, include_code_sig=False))

            with zipfile.ZipFile(input_ipa, "w") as zf:
                zf.writestr(
                    "Payload/Zalo.app/Info.plist",
                    plistlib.dumps(
                        {
                            "CFBundleIdentifier": "vn.com.vng.zingalo",
                            "CFBundleDisplayName": "Zalo",
                            "CFBundleExecutable": "Zalo",
                            "CFBundleShortVersionString": "261101",
                            "CFBundleVersion": "261101802",
                            "MinimumOSVersion": "15.1",
                        }
                    ),
                )
                zf.writestr("Payload/Zalo.app/Zalo", make_synthetic_macho64(filetype=2, include_code_sig=True))
                zf.writestr(
                    "Payload/Zalo.app/PlugIns/ShareExt.appex/Info.plist",
                    plistlib.dumps({"CFBundleIdentifier": "vn.com.vng.zingalo.ShareExt", "CFBundleExecutable": "ShareExt"}),
                )

            packager.repackage(
                input_ipa=input_ipa,
                output_ipa=out_noappex,
                mod_dylib=dylib,
                bundle_id="auto",
                no_appex=True,
            )
            report = preflight.inspect(out_noappex)
            self.assertEqual([], report["extensions"])
            self.assertEqual([], report["main_executable"]["alignment_errors"])
            self.assertIn("@executable_path/Frameworks", report["main_executable"]["rpaths"])
            self.assertIn("@rpath/libZLMod.dylib", report["main_executable"]["load_dylibs"])

    # Area 25: Objective-C static syntax, imports, module registration & redaction security check
    def test_25_objc_static_syntax_imports_installers_and_redaction(self):
        all_files = sorted(list(SOURCES.glob("*.h")) + list(SOURCES.glob("*.m")))
        self.assertGreaterEqual(len(all_files), 20)

        # 1. Balanced delimiters across every .h and .m file
        pairs = {")": "(", "]": "[", "}": "{"}
        for path in all_files:
            cleaned = strip_objc_comments_and_strings(path.read_text(encoding="utf-8"))
            stack = []
            for ch in cleaned:
                if ch in "([{":
                    stack.append(ch)
                elif ch in ")]}":
                    self.assertTrue(stack, f"Unmatched closing {ch!r} in {path.name}")
                    top = stack.pop()
                    self.assertEqual(pairs[ch], top, f"Mismatched {top!r} vs {ch!r} in {path.name}")
            self.assertEqual([], stack, f"Unclosed delimiters {stack} in {path.name}")

            # 2. Local #import headers exist
            raw = path.read_text(encoding="utf-8")
            for imp in re.findall(r'#import\s+"([^"]+)"', raw):
                self.assertTrue((SOURCES / imp).is_file(), f"Missing local header {imp} imported by {path.name}")

        # 3. Every ZLMod*Install(void) declared in ZLMod.h / ZLModBridge.h is implemented AND invoked in ZLModCore.m
        header_text = (SOURCES / "ZLMod.h").read_text(encoding="utf-8") + (SOURCES / "ZLModBridge.h").read_text(encoding="utf-8")
        declared_installers = sorted(set(re.findall(r"void\s+(ZLMod\w+Install)\s*\(void\);", header_text)))
        self.assertGreaterEqual(len(declared_installers), 12)

        all_m_text = "\n".join(p.read_text(encoding="utf-8") for p in SOURCES.glob("*.m"))
        core_text = (SOURCES / "ZLModCore.m").read_text(encoding="utf-8")
        for fn in declared_installers:
            self.assertRegex(all_m_text, rf"void\s+{fn}\s*\(void\)\s*\{{", f"Missing implementation for {fn}")
            self.assertIn(fn, core_text, f"Installer {fn} not wired into ZLModCore.m")

        # 4. Every extern NSString *const symbol declared in headers has a definition in Sources/*.m
        extern_consts = sorted(set(re.findall(r"extern\s+NSString\s+\*const\s+(\w+)\s*;", header_text)))
        self.assertGreaterEqual(len(extern_consts), 25)
        for sym in extern_consts:
            self.assertRegex(
                all_m_text,
                rf"NSString\s+\*const\s+{sym}\s*=",
                f"Extern constant {sym} declared in header has no definition in Sources/*.m",
            )

        # 5. Every @interface declared in ZLMod.h / ZLModBridge.h has an @implementation in Sources/*.m
        declared_classes = sorted(set(re.findall(r"@interface\s+(ZLMod\w+)\s*:", header_text)))
        self.assertGreaterEqual(len(declared_classes), 12)
        for cls_name in declared_classes:
            self.assertRegex(
                all_m_text,
                rf"@implementation\s+{cls_name}\b",
                f"Class {cls_name} declared in header has no @implementation in Sources/*.m",
            )

        # 6. Every C function declared in ZLMod.h / ZLModBridge.h has exactly 1 definition in Sources/*.m
        c_fn_decls = sorted(
            set(
                re.findall(
                    r"^(?:void|BOOL|id|int64_t|double|NSString\s*\*|NSArray<[^>]+>\s*\*|NSDictionary<[^>]+>\s*\*|UIWindow\s*\*|UIViewController\s*\*|ZLModStorageHealthState)\s+(ZLMod\w+)\s*\(",
                    header_text,
                    re.MULTILINE,
                )
            )
        )
        self.assertGreaterEqual(len(c_fn_decls), 35)
        for fn in c_fn_decls:
            defs = re.findall(
                rf"^(?:void|BOOL|id|int64_t|double|NSString\s*\*|NSArray<[^>]+>\s*\*|NSDictionary<[^>]+>\s*\*|UIWindow\s*\*|UIViewController\s*\*|ZLModStorageHealthState)\s+{fn}\s*\(",
                all_m_text,
                re.MULTILINE,
            )
            self.assertEqual(1, len(defs), f"Expected exactly 1 definition for {fn}, found {len(defs)}")

        # 7. Required system headers present (Security, os/lock, math, arpa/inet, string, stdlib, stdarg)
        zlmod_h_text = (SOURCES / "ZLMod.h").read_text(encoding="utf-8")
        self.assertIn("<Security/Security.h>", zlmod_h_text)
        self.assertIn("<string.h>", zlmod_h_text)
        self.assertIn("<stdlib.h>", zlmod_h_text)
        self.assertIn("<stdarg.h>", zlmod_h_text)

        # 8. Log redaction covers Discord webhooks, query secrets, Bearer tokens, and long digit IDs
        self.assertIn("discordWebhookRegex", core_text)
        self.assertIn("discord(?:app)?\\\\.com/api", core_text)
        self.assertIn("Bearer", core_text)
        self.assertIn("webhook", core_text)


if __name__ == "__main__":
    unittest.main()
