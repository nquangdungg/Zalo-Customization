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

        # 7. Required system headers present (Security, os/lock, math, arpa/inet, float, string, stdlib, stdarg)
        zlmod_h_text = (SOURCES / "ZLMod.h").read_text(encoding="utf-8")
        self.assertIn("<Security/Security.h>", zlmod_h_text)
        self.assertIn("<float.h>", zlmod_h_text)
        self.assertIn("<string.h>", zlmod_h_text)
        self.assertIn("<stdlib.h>", zlmod_h_text)
        self.assertIn("<stdarg.h>", zlmod_h_text)

        # 8. Log redaction covers Discord webhooks, query secrets, Bearer tokens, and long digit IDs
        self.assertIn("discordWebhookRegex", core_text)
        self.assertIn("discord(?:app)?\\\\.com/api", core_text)
        self.assertIn("Bearer", core_text)
        self.assertIn("webhook", core_text)

    # Area 26: Clang ARC Cocoa ownership naming & strict @interface visibility regression guard
    def test_26_objc_arc_ownership_naming_and_interface_visibility(self):
        h_files = sorted(SOURCES.glob("*.h"))
        m_files = sorted(SOURCES.glob("*.m"))
        all_files = h_files + m_files

        def arc_family(name: str):
            stripped = name.lstrip("_")
            for fam in ("alloc", "new", "copy", "mutableCopy", "init"):
                if stripped.startswith(fam):
                    rest = stripped[len(fam) :]
                    if rest == "" or not rest[0].islower():
                        return fam
            return None

        # 1. Verify zero ARC Cocoa ownership naming violations on properties & methods
        for path in all_files:
            cleaned = strip_objc_comments_and_strings(path.read_text(encoding="utf-8"))
            for lineno, line in enumerate(cleaned.splitlines(), 1):
                pm = re.match(r"^\s*@property\s*(?:\(([^)]*)\))?\s*(.+?);", line)
                if pm:
                    attrs, decl = pm.group(1) or "", pm.group(2).strip()
                    bm = re.search(r"\(\s*\^\s*(\w+)\s*\)", decl)
                    prop_name = bm.group(1) if bm else (re.search(r"(\w+)\s*$", decl).group(1) if re.search(r"(\w+)\s*$", decl) else "")
                    gm = re.search(r"getter\s*=\s*(\w+)", attrs)
                    getter = gm.group(1) if gm else prop_name
                    fam = arc_family(getter)
                    self.assertIsNone(
                        fam,
                        f"{path.name}:{lineno} property '{prop_name}' (getter '{getter}') violates ARC '{fam}' ownership naming",
                    )

                mm = re.match(r"^\s*([-+])\s*\(([^)]+)\)\s*([A-Za-z_]\w*)", line)
                if mm:
                    ret, first_sel = mm.group(2).strip(), mm.group(3)
                    fam = arc_family(first_sel)
                    if fam == "init":
                        is_obj = ret in ("instancetype", "id") or "*" in ret
                        self.assertTrue(
                            is_obj,
                            f"{path.name}:{lineno} init-family method '{first_sel}' returns non-object '{ret}'",
                        )
                    elif fam in ("alloc", "new", "copy", "mutableCopy"):
                        self.assertEqual(
                            "copyWithZone",
                            first_sel,
                            f"{path.name}:{lineno} method '{first_sel}' (returns '{ret}') falls into ARC '{fam}' family",
                        )

        # 2. Verify strict @interface visibility for every [[ZLMod* shared/alloc] ...] and [ZLMod* ...] call
        iface_global = {}
        iface_file = {}
        impl_file = {}
        class_super = {}

        def extract_selector(sig: str):
            sig = re.sub(r"\s+", " ", sig).strip()
            if ":" in sig:
                parts = re.findall(r"([A-Za-z_]\w*)\s*:", sig)
                return ":".join(parts) + ":" if parts else None
            sm = re.match(r"([A-Za-z_]\w*)", sig)
            return sm.group(1) if sm else None

        def parse_objc(files, is_header: bool):
            for path in files:
                bn = path.name
                lines = strip_objc_comments_and_strings(path.read_text(encoding="utf-8")).splitlines()
                mode, cls = None, None
                i = 0
                while i < len(lines):
                    line = lines[i]
                    mi = re.match(r"^\s*@interface\s+(\w+)\s*(?::\s*(\w+))?", line)
                    mimpl = re.match(r"^\s*@implementation\s+(\w+)", line)
                    if mi:
                        mode, cls = "iface", mi.group(1)
                        if mi.group(2):
                            class_super[cls] = mi.group(2)
                    elif mimpl:
                        mode, cls = "impl", mimpl.group(1)
                    elif re.match(r"^\s*@end\b", line):
                        mode, cls = None, None
                    elif cls:
                        mp = re.match(r"^\s*@property\s*(?:\(([^)]*)\))?\s*(.+?);", line)
                        if mp and mode == "iface":
                            attrs, decl = mp.group(1) or "", mp.group(2).strip()
                            bm = re.search(r"\(\s*\^\s*(\w+)\s*\)", decl)
                            prop_name = bm.group(1) if bm else (re.search(r"(\w+)\s*$", decl).group(1) if re.search(r"(\w+)\s*$", decl) else "")
                            if prop_name:
                                gm = re.search(r"getter\s*=\s*(\w+)", attrs)
                                getter = gm.group(1) if gm else prop_name
                                sels = [getter]
                                if "readonly" not in attrs:
                                    sels.append("set" + prop_name[0].upper() + prop_name[1:] + ":")
                                bucket = iface_global.setdefault(cls, set()) if is_header else iface_file.setdefault(bn, {}).setdefault(cls, set())
                                bucket.update(sels)
                        mm = re.match(r"^\s*([-+])\s*\([^)]+\)\s*(.*)", line)
                        if mm:
                            sig = mm.group(2)
                            j = i
                            while ";" not in sig and "{" not in sig and j + 1 < len(lines):
                                j += 1
                                sig += " " + lines[j]
                            sel = extract_selector(re.split(r"[;{]", sig)[0])
                            if sel:
                                if mode == "iface":
                                    bucket = iface_global.setdefault(cls, set()) if is_header else iface_file.setdefault(bn, {}).setdefault(cls, set())
                                else:
                                    bucket = impl_file.setdefault(bn, {}).setdefault(cls, set())
                                bucket.add(sel)
                    i += 1

        parse_objc(h_files, True)
        parse_objc(m_files, False)

        std_methods = {
            "alloc", "init", "new", "shared", "class", "isKindOfClass:", "respondsToSelector:",
            "copy", "mutableCopy", "initWithStyle:", "initWithNibName:bundle:",
            "initWithRootViewController:", "view", "navigationItem", "navigationController",
        }

        def visible_for(bn: str, cls: str, in_impl):
            vis = set(std_methods)
            cur = cls
            seen = set()
            while cur and cur not in seen:
                seen.add(cur)
                vis |= iface_global.get(cur, set())
                vis |= iface_file.get(bn, {}).get(cur, set())
                if in_impl == cur:
                    vis |= impl_file.get(bn, {}).get(cur, set())
                cur = class_super.get(cur)
            return vis

        def parse_call_selector(text: str, start: int):
            depth_sq, depth_par, depth_cur = 1, 0, 0
            top = []
            i = start
            while i < len(text) and depth_sq > 0:
                ch = text[i]
                if ch == "[":
                    depth_sq += 1
                elif ch == "]":
                    depth_sq -= 1
                    if depth_sq == 0:
                        break
                elif ch == "(":
                    depth_par += 1
                elif ch == ")":
                    depth_par -= 1
                elif ch == "{":
                    depth_cur += 1
                elif ch == "}":
                    depth_cur -= 1
                elif depth_sq == 1 and depth_par == 0 and depth_cur == 0:
                    top.append(ch)
                i += 1
            body = "".join(top).strip()
            if not body:
                return None
            if ":" in body:
                if "?" in body:
                    fm = re.match(r"^([A-Za-z_]\w*)\s*:", body)
                    return (fm.group(1) + ":", True) if fm else None
                parts = re.findall(r"([A-Za-z_]\w*)\s*:", body)
                return (":".join(parts) + ":", False) if parts else None
            sm = re.match(r"^([A-Za-z_]\w*)\s*$", body)
            return (sm.group(1), False) if sm else None

        for path in m_files:
            bn = path.name
            cleaned = strip_objc_comments_and_strings(path.read_text(encoding="utf-8"))
            impl_spans = []
            for m in re.finditer(r"(?m)^\s*@implementation\s+(\w+)", cleaned):
                end_m = re.search(r"(?m)^\s*@end\b", cleaned[m.end() :])
                end_pos = m.end() + end_m.start() if end_m else len(cleaned)
                impl_spans.append((m.start(), end_pos, m.group(1)))

            def impl_at(pos: int):
                for s, e, c in impl_spans:
                    if s <= pos <= e:
                        return c
                return None

            for m in re.finditer(r"\[\s*\[\s*(ZLMod\w+)\s+(shared|alloc)\s*\]\s+", cleaned):
                cls = m.group(1)
                res = parse_call_selector(cleaned, m.end())
                if not res:
                    continue
                sel, is_prefix = res
                vis = visible_for(bn, cls, impl_at(m.start()))
                ok = any(v.startswith(sel) for v in vis) if is_prefix else (sel in vis)
                ln = cleaned.count("\n", 0, m.start()) + 1
                self.assertTrue(ok, f"{bn}:{ln} calls [[{cls} {m.group(2)}] {sel}] without visible @interface declaration")

            for m in re.finditer(r"\b(ZLMod\w+)\s*\*\s*(\w+)\s*=", cleaned):
                vcls, vname = m.group(1), m.group(2)
                window = cleaned[m.end() : m.end() + 2500]
                stop = re.search(r"(?m)^(?:@end|\}\s*$)", window)
                if stop:
                    window = window[: stop.start()]
                for cm in re.finditer(rf"\[\s*{re.escape(vname)}\s+(?=[A-Za-z_])", window):
                    res = parse_call_selector(cleaned, m.end() + cm.end())
                    if not res:
                        continue
                    sel, is_prefix = res
                    abs_pos = m.end() + cm.start()
                    vis = visible_for(bn, vcls, impl_at(abs_pos))
                    ok = any(v.startswith(sel) for v in vis) if is_prefix else (sel in vis)
                    ln = cleaned.count("\n", 0, abs_pos) + 1
                    self.assertTrue(ok, f"{bn}:{ln} calls [{vname}({vcls}) {sel}] without visible @interface declaration")

        # 3. No nil passed to SEL/void* params of UIImageWriteToSavedPhotosAlbum
        for path in m_files:
            raw = path.read_text(encoding="utf-8")
            for m in re.finditer(r"UIImageWriteToSavedPhotosAlbum\s*\(([^;]+)\)\s*;", raw):
                args = [a.strip() for a in m.group(1).split(",")]
                self.assertEqual(4, len(args), f"Unexpected arg count in {path.name}: {args}")
                self.assertNotEqual("nil", args[2], f"{path.name}: pass NULL (not nil) for SEL param")
                self.assertNotEqual("nil", args[3], f"{path.name}: pass NULL (not nil) for void* contextInfo")


if __name__ == "__main__":
    unittest.main()
