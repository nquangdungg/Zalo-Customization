#!/usr/bin/env python3
"""
macho_injector.py - Pure Python Mach-O 64-bit LC_LOAD_DYLIB Injector
Compatible with iOS ARM64 binaries (Clang/Darwin Mach-O 64-bit)

Injects a new LC_LOAD_DYLIB or LC_LOAD_WEAK_DYLIB command into the zero-padding
gap between the existing load commands and the first __TEXT section.
"""

import struct
import sys
from typing import List, Tuple, Optional

LC_LOAD_DYLIB = 0x0C
LC_LOAD_WEAK_DYLIB = 0x18 | 0x80000000  # LC_REQ_DYLD | 0x18
LC_RPATH = 0x1C | 0x80000000

FAT_MAGIC = 0xCAFEBABE
FAT_CIGAM = 0xBEBAFECA
FAT_MAGIC_64 = 0xCAFEBABF
FAT_CIGAM_64 = 0xBFBAFECA
MACHO_64_MAGIC = 0xFEEDFACF

def align8(size: int) -> int:
    return (size + 7) & ~7

def is_fat_macho(data: bytes) -> bool:
    if len(data) < 4:
        return False
    magic = struct.unpack("<I", data[:4])[0]
    return magic in (FAT_MAGIC, FAT_CIGAM, FAT_MAGIC_64, FAT_CIGAM_64)

def parse_fat_slices(data: bytes) -> List[Tuple[int, int]]:
    """Returns list of (offset, size) for 64-bit slices in a FAT Mach-O binary."""
    if len(data) < 8:
        return []
    magic = struct.unpack(">I", data[:4])[0]
    slices = []
    if magic == 0xCAFEBABE:
        nfat = struct.unpack(">I", data[4:8])[0]
        for i in range(nfat):
            arch_offset = 8 + i * 20
            cputype, cpusubtype, offset, size, align = struct.unpack(">IIIII", data[arch_offset:arch_offset + 20])
            if cputype == 0x0100000C or (cputype & 0x01000000):  # ARM64 or 64-bit ABI
                slices.append((offset, size))
    elif magic == 0xCAFEBABF:
        nfat = struct.unpack(">I", data[4:8])[0]
        for i in range(nfat):
            arch_offset = 8 + i * 32
            cputype, cpusubtype, offset, size, align, reserved = struct.unpack(">IIQQII", data[arch_offset:arch_offset + 32])
            if cputype == 0x0100000C or (cputype & 0x01000000):
                slices.append((offset, size))
    return slices

def inspect_macho_header(data: bytes) -> dict:
    if len(data) < 32:
        raise ValueError("Data too short to be Mach-O binary")
    magic = struct.unpack("<I", data[:4])[0]
    if magic != MACHO_64_MAGIC:
        raise ValueError(f"Unsupported Mach-O magic: {hex(magic)} (expected 64-bit LE 0xfeedfacf)")

    magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved = struct.unpack("<IIIIIIII", data[:32])
    return {
        "magic": magic,
        "cputype": cputype,
        "cpusubtype": cpusubtype,
        "filetype": filetype,
        "ncmds": ncmds,
        "sizeofcmds": sizeofcmds,
        "flags": flags,
        "reserved": reserved
    }

def get_load_dylibs(data: bytes) -> List[str]:
    if is_fat_macho(data):
        slices = parse_fat_slices(data)
        if slices:
            offset, size = slices[0]
            return get_load_dylibs(data[offset:offset + size])
        return []

    hdr = inspect_macho_header(data)
    ncmds = hdr["ncmds"]
    offset = 32
    dylibs = []

    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack("<II", data[offset:offset + 8])
        base_cmd = cmd & 0x7FFFFFFF
        if base_cmd in (0x0C, 0x18, 0x1F, 0x23):
            str_offset = struct.unpack("<I", data[offset + 8:offset + 12])[0]
            str_bytes = data[offset + str_offset:offset + cmdsize]
            dylib_str = str_bytes.split(b"\x00", 1)[0].decode("utf-8", errors="replace")
            dylibs.append(dylib_str)
        offset += cmdsize

    return dylibs

def get_rpaths(data: bytes) -> List[str]:
    if is_fat_macho(data):
        slices = parse_fat_slices(data)
        if slices:
            offset, size = slices[0]
            return get_rpaths(data[offset:offset + size])
        return []

    hdr = inspect_macho_header(data)
    ncmds = hdr["ncmds"]
    offset = 32
    rpaths = []

    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack("<II", data[offset:offset + 8])
        base_cmd = cmd & 0x7FFFFFFF
        if base_cmd == 0x1C:  # LC_RPATH
            str_offset = struct.unpack("<I", data[offset + 8:offset + 12])[0]
            str_bytes = data[offset + str_offset:offset + cmdsize]
            rpath_str = str_bytes.split(b"\x00", 1)[0].decode("utf-8", errors="replace")
            rpaths.append(rpath_str)
        offset += cmdsize

    return rpaths

def find_first_section_offset(data: bytes) -> int:
    """Find the lowest file offset among all sections in all segments."""
    hdr = inspect_macho_header(data)
    ncmds = hdr["ncmds"]
    offset = 32
    min_offset = len(data)

    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack("<II", data[offset:offset + 8])
        if cmd == 0x19:  # LC_SEGMENT_64
            nsects = struct.unpack("<I", data[offset + 64:offset + 68])[0]
            sec_start = offset + 72
            for s in range(nsects):
                sec_offset = sec_start + s * 80
                s_fileoff = struct.unpack("<I", data[sec_offset + 48:sec_offset + 52])[0]
                s_size = struct.unpack("<Q", data[sec_offset + 40:sec_offset + 48])[0]
                if s_size > 0 and 0 < s_fileoff < min_offset:
                    min_offset = s_fileoff
        offset += cmdsize

    return min_offset

def inject_rpath_slice(data: bytes, rpath: str) -> bytes:
    existing = get_rpaths(data)
    if rpath in existing:
        return data

    hdr = inspect_macho_header(data)
    ncmds = hdr["ncmds"]
    sizeofcmds = hdr["sizeofcmds"]
    first_sec_offset = find_first_section_offset(data)

    cmd_type = LC_RPATH
    rpath_bytes = rpath.encode("utf-8") + b"\x00"
    padded_len = align8(len(rpath_bytes))
    cmdsize = 12 + padded_len

    gap_start = 32 + sizeofcmds
    gap_available = first_sec_offset - gap_start

    if cmdsize > gap_available:
        print(f"[!] Warning: Not enough padding gap ({gap_available} bytes) for LC_RPATH '{rpath}'. Skipping.")
        return data

    gap_bytes = data[gap_start:gap_start + cmdsize]
    if any(b != 0 for b in gap_bytes):
        print("[!] Warning: Load command gap contains non-zero bytes. Skipping LC_RPATH.")
        return data

    cmd_bytes = struct.pack("<III", cmd_type, cmdsize, 12)
    cmd_bytes += rpath_bytes + (b"\x00" * (padded_len - len(rpath_bytes)))
    assert len(cmd_bytes) == cmdsize

    new_ncmds = ncmds + 1
    new_sizeofcmds = sizeofcmds + cmdsize
    new_header = struct.pack(
        "<IIIIIIII",
        hdr["magic"],
        hdr["cputype"],
        hdr["cpusubtype"],
        hdr["filetype"],
        new_ncmds,
        new_sizeofcmds,
        hdr["flags"],
        hdr["reserved"]
    )

    ba = bytearray(data)
    ba[:32] = new_header

    if sizeofcmds >= 16:
        last_cmd, last_cmdsize = struct.unpack("<II", data[32 + sizeofcmds - 16 : 32 + sizeofcmds - 8])
    else:
        last_cmd, last_cmdsize = 0, 0
    if last_cmd == 0x1D and last_cmdsize == 16:
        cs_bytes = data[32 + sizeofcmds - 16 : 32 + sizeofcmds]
        ba[32 + sizeofcmds - 16 : 32 + sizeofcmds - 16 + cmdsize] = cmd_bytes
        ba[32 + sizeofcmds - 16 + cmdsize : 32 + sizeofcmds + cmdsize] = cs_bytes
    else:
        ba[gap_start:gap_start + cmdsize] = cmd_bytes

    print(f"[+] Successfully injected LC_RPATH: '{rpath}'")
    return bytes(ba)

def inject_rpath(data: bytes, rpath: str) -> bytes:
    if is_fat_macho(data):
        slices = parse_fat_slices(data)
        if not slices:
            return data
        ba = bytearray(data)
        for offset, size in slices:
            slice_data = bytes(ba[offset:offset + size])
            modified_slice = inject_rpath_slice(slice_data, rpath)
            assert len(modified_slice) == size, "Slice size must remain unchanged"
            ba[offset:offset + size] = modified_slice
        return bytes(ba)
    return inject_rpath_slice(data, rpath)

def inject_load_dylib_slice(data: bytes, dylib_path: str, weak: bool = False) -> bytes:
    hdr = inspect_macho_header(data)
    existing_dylibs = get_load_dylibs(data)
    if dylib_path in existing_dylibs:
        print(f"[!] Dylib '{dylib_path}' is already referenced in load commands. Skipping.")
        return data

    ncmds = hdr["ncmds"]
    sizeofcmds = hdr["sizeofcmds"]
    first_sec_offset = find_first_section_offset(data)

    cmd_type = LC_LOAD_WEAK_DYLIB if weak else LC_LOAD_DYLIB
    dylib_path_bytes = dylib_path.encode("utf-8") + b"\x00"
    padded_path_len = align8(len(dylib_path_bytes))
    cmdsize = 24 + padded_path_len

    gap_start = 32 + sizeofcmds
    gap_available = first_sec_offset - gap_start

    if cmdsize > gap_available:
        raise RuntimeError(f"Cannot inject dylib: required {cmdsize} bytes, but only {gap_available} bytes available in padding gap!")

    gap_bytes = data[gap_start:gap_start + cmdsize]
    if any(b != 0 for b in gap_bytes):
        raise RuntimeError("Load command padding gap contains non-zero data! Aborting injection for safety.")

    cmd_bytes = struct.pack(
        "<IIIIII",
        cmd_type,
        cmdsize,
        24,             # name.offset = 24 bytes from start of command
        2,              # timestamp
        0x00010000,     # current_version 1.0.0
        0x00010000      # compatibility_version 1.0.0
    )
    cmd_bytes += dylib_path_bytes + (b"\x00" * (padded_path_len - len(dylib_path_bytes)))
    assert len(cmd_bytes) == cmdsize

    new_ncmds = ncmds + 1
    new_sizeofcmds = sizeofcmds + cmdsize
    new_header = struct.pack(
        "<IIIIIIII",
        hdr["magic"],
        hdr["cputype"],
        hdr["cpusubtype"],
        hdr["filetype"],
        new_ncmds,
        new_sizeofcmds,
        hdr["flags"],
        hdr["reserved"]
    )

    ba = bytearray(data)
    ba[:32] = new_header

    if sizeofcmds >= 16:
        last_cmd, last_cmdsize = struct.unpack("<II", data[32 + sizeofcmds - 16 : 32 + sizeofcmds - 8])
    else:
        last_cmd, last_cmdsize = 0, 0
    if last_cmd == 0x1D and last_cmdsize == 16:
        cs_bytes = data[32 + sizeofcmds - 16 : 32 + sizeofcmds]
        ba[32 + sizeofcmds - 16 : 32 + sizeofcmds - 16 + cmdsize] = cmd_bytes
        ba[32 + sizeofcmds - 16 + cmdsize : 32 + sizeofcmds + cmdsize] = cs_bytes
        print("    [!] Preserved LC_CODE_SIGNATURE as the final load command (shifted forward).")
    else:
        ba[gap_start:gap_start + cmdsize] = cmd_bytes

    print(f"[+] Successfully injected {'LC_LOAD_WEAK_DYLIB' if weak else 'LC_LOAD_DYLIB'}: '{dylib_path}'")
    print(f"    New ncmds: {new_ncmds} (was {ncmds})")
    print(f"    New sizeofcmds: {new_sizeofcmds} (was {sizeofcmds})")
    print(f"    Remaining padding gap: {gap_available - cmdsize} bytes")

    return bytes(ba)

def inject_load_dylib(data: bytes, dylib_path: str, weak: bool = False) -> bytes:
    """
    Inject LC_LOAD_DYLIB or LC_LOAD_WEAK_DYLIB command into Mach-O 64-bit or FAT binary.
    Returns modified binary bytes.
    """
    if is_fat_macho(data):
        slices = parse_fat_slices(data)
        if not slices:
            raise ValueError("No 64-bit architecture slice found in FAT Mach-O binary.")
        ba = bytearray(data)
        for offset, size in slices:
            slice_data = bytes(ba[offset:offset + size])
            modified_slice = inject_load_dylib_slice(slice_data, dylib_path, weak)
            assert len(modified_slice) == size, "Slice size must remain unchanged"
            ba[offset:offset + size] = modified_slice
        return bytes(ba)
    return inject_load_dylib_slice(data, dylib_path, weak)

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print("Usage: python macho_injector.py <macho_file> <dylib_path> [output_file]")
        sys.exit(1)

    in_path = sys.argv[1]
    dylib_to_inject = sys.argv[2]
    out_path = sys.argv[3] if len(sys.argv) > 3 else in_path

    with open(in_path, "rb") as f:
        binary_data = f.read()

    modified = inject_load_dylib(binary_data, dylib_to_inject)

    with open(out_path, "wb") as f:
        f.write(modified)
    print(f"[+] Output written to: {out_path}")
