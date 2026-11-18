#!/usr/bin/env python3
"""Validate an X6882 (MT6789 / UFS 2.2) SP Flash Tool scatter.

The reference geometry is ``GPT_PARTITION_TABLE_UFS.csv`` next to this file,
which was parsed from the primary GPT in the EasyJTAG dump of LUN2.

Usage:
    python3 verify_scatter.py [scatter.txt] [--images DIR]

With no argument every ``*scatter*.txt`` in this directory is checked.
``--images DIR`` additionally verifies that each enabled image exists and is
no larger than its partition (point it at the extracted stock firmware).
"""

from __future__ import annotations

import argparse
import csv
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CSV_PATH = os.path.join(HERE, "GPT_PARTITION_TABLE_UFS.csv")

# LUN2 size from the FORESEE C2G074 configuration and the GPT backup header.
CAPACITY = 0x3B96000000
# Reserved tail: 16 MiB flashinfo directly followed by the 32 KiB backup GPT.
FLASHINFO_SIZE = 0x1000000
SGPT_SIZE = 0x8000
FLASHINFO_SENTINEL = 0xFFFF0020
SGPT_SENTINEL = 0xFFFF0000

# MTK UFS region names understood by SP Flash Tool.
REGIONS = {"UFS_LU0", "UFS_LU1", "UFS_LU2", "UFS_LU0_LU1"}

BLOCK_RE = re.compile(r"\n(?=\s*-\s*partition_index:)")


def parse(path: str) -> tuple[dict[str, str], list[dict[str, str]]]:
    text = open(path, encoding="utf-8", errors="replace").read()
    storage: dict[str, str] = {}
    m = re.search(r"^-\s*storage_type:\s*(\S+)", text, re.M)
    if m:
        storage["storage_type"] = m.group(1)
    for key in ("storage", "boot_channel", "block_size"):
        m = re.search(r"^\s*"+key+r":\s*(\S+)", text, re.M)
        if m:
            storage[key] = m.group(1)

    blocks = []
    for chunk in BLOCK_RE.split(text):
        if "partition_index:" not in chunk:
            continue
        fields = {}
        for line in chunk.splitlines():
            m = re.match(r"^\s*([A-Za-z_]+):\s*(.*?)\s*$", line)
            if m:
                fields[m.group(1)] = m.group(2)
        if "partition_name" in fields:
            blocks.append(fields)
    return storage, blocks


def load_gpt() -> list[dict[str, int | str]]:
    with open(CSV_PATH, newline="", encoding="utf-8") as fh:
        rows = list(csv.DictReader(fh))
    return [
        {
            "name": r["partition_name"],
            "offset": int(r["physical_offset_hex"], 0),
            "size": int(r["size_hex"], 0),
        }
        for r in rows
    ]


def validate(path: str, images: str | None) -> list[str]:
    errors: list[str] = []
    storage, blocks = parse(path)
    gpt = load_gpt()
    gpt_by_name = {e["name"]: e for e in gpt}

    # --- storage header -----------------------------------------------------
    if storage.get("storage_type") != "UFS":
        errors.append(f"storage_type is {storage.get('storage_type')!r}, expected UFS")
    if storage.get("boot_channel") != "UFSHCI_0":
        errors.append(f"boot_channel is {storage.get('boot_channel')!r}, expected UFSHCI_0")
    if storage.get("block_size") != "0x80000":
        errors.append(f"block_size is {storage.get('block_size')!r}, expected 0x80000")

    # --- per-block fields ---------------------------------------------------
    names: set[str] = set()
    resolved: list[tuple[int, int, str]] = []
    for i, b in enumerate(blocks):
        name = b.get("partition_name", "?")
        if name in names:
            errors.append(f"duplicate partition_name {name}")
        names.add(name)
        if b.get("storage") != "HW_STORAGE_UFS":
            errors.append(f"{name}: storage {b.get('storage')!r}, expected HW_STORAGE_UFS")
        if b.get("region") not in REGIONS:
            errors.append(f"{name}: unknown region {b.get('region')!r}")
        try:
            off = int(b["linear_start_addr"], 16)
            size = int(b["partition_size"], 16)
        except (KeyError, ValueError):
            errors.append(f"{name}: missing or invalid address/size")
            continue

        if name == "flashinfo":
            if off != FLASHINFO_SENTINEL:
                errors.append(
                    f"flashinfo: {hex(off)}, expected sentinel {hex(FLASHINFO_SENTINEL)}"
                )
            if size != FLASHINFO_SIZE:
                errors.append(f"flashinfo: size {hex(size)}, expected {hex(FLASHINFO_SIZE)}")
            if b.get("boundary_check") != "false" or b.get("is_reserved") != "true":
                errors.append("flashinfo: must be boundary_check=false, is_reserved=true")
            off = CAPACITY - SGPT_SIZE - FLASHINFO_SIZE
        elif name == "sgpt":
            if off != SGPT_SENTINEL:
                errors.append(f"sgpt: {hex(off)}, expected sentinel {hex(SGPT_SENTINEL)}")
            if size != SGPT_SIZE:
                errors.append(f"sgpt: size {hex(size)}, expected {hex(SGPT_SIZE)}")
            if b.get("boundary_check") != "false" or b.get("is_reserved") != "true":
                errors.append("sgpt: must be boundary_check=false, is_reserved=true")
            off = CAPACITY - SGPT_SIZE
        elif name == "preloader":
            if b.get("region") != "UFS_LU0_LU1":
                errors.append(f"preloader: region {b.get('region')!r}, expected UFS_LU0_LU1")
            if (off, size) != (0, 0x100000):
                errors.append(f"preloader: {hex(off)}/{hex(size)}, expected 0x0/0x100000")
        elif name == "preloader_backup":
            if b.get("region") != "UFS_LU1":
                errors.append(
                    f"preloader_backup: region {b.get('region')!r}, expected UFS_LU1"
                )
        elif name == "pgpt":
            if (off, size) != (0, 0x8000):
                errors.append(f"pgpt: {hex(off)}/{hex(size)}, expected 0x0/0x8000")
        else:
            ref = gpt_by_name.get(name)
            if ref is None:
                errors.append(f"{name}: not present in the GPT")
            elif (off, size) != (ref["offset"], ref["size"]):
                errors.append(
                    f"{name}: {hex(off)}/{hex(size)} != GPT "
                    f"{hex(ref['offset'])}/{hex(ref['size'])}"
                )

        if b.get("region") == "UFS_LU2" and name not in ("flashinfo", "sgpt"):
            resolved.append((off, off + size, name))

    # --- coverage -----------------------------------------------------------
    missing = sorted(set(gpt_by_name) - names)
    if missing:
        errors.append("missing GPT partitions: " + ", ".join(missing))

    # --- no overlap on LUN2 -------------------------------------------------
    resolved.sort()
    for (a_start, a_end, a_name), (b_start, _, b_name) in zip(resolved, resolved[1:]):
        if a_end > b_start:
            errors.append(f"overlap on UFS_LU2: {a_name} ends {hex(a_end)} > {b_name} {hex(b_start)}")

    # --- reserved tail ------------------------------------------------------
    userdata = next((b for b in blocks if b.get("partition_name") == "userdata"), None)
    if userdata:
        u_end = int(userdata["linear_start_addr"], 16) + int(userdata["partition_size"], 16)
        expect = CAPACITY - SGPT_SIZE - FLASHINFO_SIZE
        if u_end != expect:
            errors.append(f"userdata ends at {hex(u_end)}, expected {hex(expect)}")

    # --- enabled images -----------------------------------------------------
    for b in blocks:
        if b.get("is_download") != "true":
            continue
        fn = b.get("file_name", "NONE")
        if fn == "NONE":
            errors.append(f"{b['partition_name']}: is_download=true but file_name is NONE")
            continue
        if images is None:
            continue
        p = os.path.join(images, fn)
        if not os.path.isfile(p):
            errors.append(f"{b['partition_name']}: missing image {fn}")
            continue
        fsz = os.path.getsize(p)
        psz = int(b["partition_size"], 16)
        if fsz > psz:
            errors.append(f"{b['partition_name']}: {fn} is {fsz} bytes > partition {psz}")

    return errors


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("scatter", nargs="*", help="scatter file(s) to check")
    ap.add_argument("--images", help="directory with the firmware images")
    args = ap.parse_args()

    paths = args.scatter or sorted(
        os.path.join(HERE, f)
        for f in os.listdir(HERE)
        if f.lower().endswith(".txt") and "scatter" in f.lower()
    )
    if not paths:
        print("no scatter files found", file=sys.stderr)
        return 2

    failed = 0
    for path in paths:
        if not os.path.isfile(path):
            print(f"FAIL  {path}: no such file")
            failed += 1
            continue
        errors = validate(path, args.images)
        state = "PASS" if not errors else "FAIL"
        print(f"{state}  {os.path.basename(path)}")
        for err in errors:
            print(f"      - {err}")
        failed += bool(errors)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
