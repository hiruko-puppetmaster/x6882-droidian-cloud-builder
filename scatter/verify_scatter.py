#!/usr/bin/env python3
"""Validate an X6882 (MT6789) SP Flash Tool scatter.

Supports the dual-section layout used by MediaTek: one `storage_type: EMMC`
block followed by one `storage_type: UFS` block, both describing the same GPT.
The reference geometry is ``GPT_PARTITION_TABLE_UFS.csv`` next to this file,
parsed from the primary GPT in the EasyJTAG dump of LUN2.

Usage:
    python3 verify_scatter.py [scatter.txt ...] [--images DIR]

With no argument every ``*.txt`` scatter in this directory is checked.
``--images DIR`` additionally verifies that each enabled image exists and fits.
"""

from __future__ import annotations

import argparse
import csv
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CSV_PATH = os.path.join(HERE, "GPT_PARTITION_TABLE_UFS.csv")

CAPACITY = 0x3B96000000
FLASHINFO_SIZE = 0x1000000
SGPT_SIZE = 0x8000
SGPT_SENTINEL = 0xFFFF0000
PRELOADER_SIZE = 0x100000
PGPT_SIZE = 0x8000

SPEC = {
    "UFS": {
        "storage": "UFS",
        "boot_channel": "UFSHCI_0",
        "block_size": "0x80000",
        "regions": {"UFS_LU0", "UFS_LU1", "UFS_LU2", "UFS_LU0_LU1"},
        "preloader_region": "UFS_LU0_LU1",
        "backup_region": "UFS_LU1",
        "user_region": "UFS_LU2",
        "flash_sentinel": 0xFFFF0020,
    },
    "EMMC": {
        "storage": "EMMC",
        "boot_channel": "MSDC_0",
        "block_size": "0x20000",
        "regions": {"EMMC_BOOT1_BOOT2", "EMMC_BOOT2", "EMMC_USER"},
        "preloader_region": "EMMC_BOOT1_BOOT2",
        "backup_region": "EMMC_BOOT2",
        "user_region": "EMMC_USER",
        "flash_sentinel": 0xFFFF0080,
    },
}

BLOCK_SPLIT = re.compile(r"\n(?=\s*-\s*partition_index:)")


def field(chunk: str, key: str) -> str | None:
    m = re.search(r"^\s*-?\s*" + key + r":\s*(.*?)\s*$", chunk, re.M)
    return m.group(1) if m else None


def parse(path: str) -> tuple[dict[str, str], list[dict]]:
    text = open(path, encoding="utf-8", errors="replace").read()
    parts = re.split(r"\n(?=-\s*storage_type:)", text)
    head = parts[0]
    general = {}
    for key in ("config_version", "platform", "project"):
        value = field(head, key)
        if value:
            general[key] = value

    sections = []
    for part in parts[1:]:
        m = re.match(r"-\s*storage_type:\s*(\S+)", part)
        if not m:
            continue
        section = {"storage_type": m.group(1)}
        for key in ("storage", "boot_channel", "block_size"):
            section[key] = field(part, key)
        blocks = []
        for chunk in BLOCK_SPLIT.split(part):
            if "partition_index:" not in chunk:
                continue
            d = {}
            for line in chunk.splitlines():
                fm = re.match(r"^\s*-?\s*([A-Za-z_]+):\s*(.*?)\s*$", line)
                if fm:
                    d[fm.group(1)] = fm.group(2)
            blocks.append(d)
        section["blocks"] = blocks
        sections.append(section)
    return general, sections


def load_gpt() -> list[dict]:
    with open(CSV_PATH, newline="", encoding="utf-8") as fh:
        rows = list(csv.DictReader(fh))
    return [
        {"name": r["partition_name"],
         "offset": int(r["physical_offset_hex"], 0),
         "size": int(r["size_hex"], 0)}
        for r in rows
    ]


def resolve(block: dict, sentinel: int) -> tuple[int, int]:
    name = block.get("partition_name")
    size = int(block["partition_size"], 16)
    if name == "flashinfo":
        return CAPACITY - SGPT_SIZE - FLASHINFO_SIZE, size
    if name == "sgpt":
        return CAPACITY - SGPT_SIZE, size
    return int(block["linear_start_addr"], 16), size


def validate_section(section: dict, gpt: dict[str, dict], images: str | None) -> list[str]:
    errors: list[str] = []
    kind = section["storage_type"]
    spec = SPEC.get(kind)
    if spec is None:
        return [f"unknown storage_type {kind!r}"]

    if section["storage"] != spec["storage"]:
        errors.append(f"storage is {section['storage']!r}, expected {spec['storage']!r}")
    if section["boot_channel"] != spec["boot_channel"]:
        errors.append(f"boot_channel is {section['boot_channel']!r}, expected {spec['boot_channel']}")
    if section["block_size"] != spec["block_size"]:
        errors.append(f"block_size is {section['block_size']!r}, expected {spec['block_size']}")

    blocks = section["blocks"]
    if len(blocks) != 72:
        errors.append(f"{len(blocks)} entries, expected 72")

    names: set[str] = set()
    for i, b in enumerate(blocks):
        name = b.get("partition_name", "?")
        if name in names:
            errors.append(f"duplicate partition_name {name}")
        names.add(name)
        if b.get("partition_index") != f"SYS{i}":
            errors.append(f"{name}: partition_index {b.get('partition_index')!r}, expected SYS{i}")
        if b.get("storage") != f"HW_STORAGE_{kind}":
            errors.append(f"{name}: storage {b.get('storage')!r}, expected HW_STORAGE_{kind}")
        region = b.get("region")
        if region not in spec["regions"]:
            errors.append(f"{name}: unknown region {region!r}")

        try:
            off, size = resolve(b, spec["flash_sentinel"])
        except (KeyError, ValueError):
            errors.append(f"{name}: missing or invalid address/size")
            continue

        if name == "preloader":
            if region != spec["preloader_region"]:
                errors.append(f"preloader: region {region!r}, expected {spec['preloader_region']}")
            if (off, size) != (0, PRELOADER_SIZE):
                errors.append(f"preloader: {hex(off)}/{hex(size)}, expected 0x0/{hex(PRELOADER_SIZE)}")
        elif name == "preloader_backup":
            if region != spec["backup_region"]:
                errors.append(f"preloader_backup: region {region!r}, expected {spec['backup_region']}")
        elif name == "pgpt":
            if (off, size) != (0, PGPT_SIZE):
                errors.append(f"pgpt: {hex(off)}/{hex(size)}, expected 0x0/{hex(PGPT_SIZE)}")
        elif name == "flashinfo":
            if int(b["linear_start_addr"], 16) != spec["flash_sentinel"]:
                errors.append(
                    f"flashinfo: {b['linear_start_addr']}, expected sentinel {hex(spec['flash_sentinel'])}"
                )
            if size != FLASHINFO_SIZE:
                errors.append(f"flashinfo: size {hex(size)}, expected {hex(FLASHINFO_SIZE)}")
            if b.get("boundary_check") != "false" or b.get("is_reserved") != "true":
                errors.append("flashinfo: must be boundary_check=false, is_reserved=true")
        elif name == "sgpt":
            if int(b["linear_start_addr"], 16) != SGPT_SENTINEL:
                errors.append(f"sgpt: {b['linear_start_addr']}, expected sentinel {hex(SGPT_SENTINEL)}")
            if size != SGPT_SIZE:
                errors.append(f"sgpt: size {hex(size)}, expected {hex(SGPT_SIZE)}")
            if b.get("boundary_check") != "false" or b.get("is_reserved") != "true":
                errors.append("sgpt: must be boundary_check=false, is_reserved=true")
        else:
            ref = gpt.get(name)
            if ref is None:
                errors.append(f"{name}: not present in the GPT")
            elif (off, size) != (ref["offset"], ref["size"]):
                errors.append(
                    f"{name}: {hex(off)}/{hex(size)} != GPT {hex(ref['offset'])}/{hex(ref['size'])}"
                )

    missing = sorted(set(gpt) - names)
    if missing:
        errors.append("missing GPT partitions: " + ", ".join(missing))

    # user area must be contiguous and stop exactly at flashinfo
    ranges = []
    for b in blocks:
        off, size = resolve(b, spec["flash_sentinel"])
        if b.get("region") == spec["user_region"]:
            ranges.append((off, off + size, b["partition_name"]))
    ranges.sort()
    for (a_start, a_end, a_name), (b_start, _, b_name) in zip(ranges, ranges[1:]):
        if a_end > b_start:
            errors.append(f"overlap: {a_name} ends {hex(a_end)} > {b_name} starts {hex(b_start)}")

    userdata = next((b for b in blocks if b.get("partition_name") == "userdata"), None)
    if userdata:
        end = int(userdata["linear_start_addr"], 16) + int(userdata["partition_size"], 16)
        expect = CAPACITY - SGPT_SIZE - FLASHINFO_SIZE
        if end != expect:
            errors.append(f"userdata ends at {hex(end)}, expected {hex(expect)}")

    for b in blocks:
        if b.get("is_download") != "true":
            continue
        fn = b.get("file_name", "NONE")
        if fn == "NONE":
            errors.append(f"{b['partition_name']}: is_download=true but file_name is NONE")
            continue
        if images is None:
            continue
        path = os.path.join(images, fn)
        if not os.path.isfile(path):
            errors.append(f"{b['partition_name']}: missing image {fn}")
            continue
        fsz = os.path.getsize(path)
        psz = int(b["partition_size"], 16)
        if fsz > psz:
            errors.append(f"{b['partition_name']}: {fn} is {fsz} bytes > partition {psz}")

    return errors


def validate(path: str, images: str | None) -> list[str]:
    general, sections = parse(path)
    errors: list[str] = []

    if general.get("platform") not in (None, "MT6789"):
        errors.append(f"platform {general.get('platform')!r}, expected MT6789")
    if not sections:
        return errors + ["no storage section found"]

    kinds = [s["storage_type"] for s in sections]
    if "UFS" not in kinds:
        errors.append("no UFS section; this phone is UFS 2.2")
    if len(kinds) != len(set(kinds)):
        errors.append("duplicate storage section")

    gpt = {e["name"]: e for e in load_gpt()}
    for section in sections:
        prefix = section["storage_type"]
        errors += [f"{prefix}: {e}" for e in validate_section(section, gpt, images)]

    # the two sections must describe the same layout
    if len(sections) == 2:
        a, b = sections
        if [x.get("partition_name") for x in a["blocks"]] != [x.get("partition_name") for x in b["blocks"]]:
            errors.append("EMMC and UFS sections list different partitions")
        else:
            for x, y in zip(a["blocks"], b["blocks"]):
                sx = resolve(x, SPEC[a["storage_type"]]["flash_sentinel"])
                sy = resolve(y, SPEC[b["storage_type"]]["flash_sentinel"])
                if sx != sy:
                    errors.append(f"{x['partition_name']}: geometry differs between sections")
                    break
        if {(x["partition_name"], x.get("file_name"), x.get("is_download"))
            for x in a["blocks"]} != {(x["partition_name"], x.get("file_name"), x.get("is_download"))
                                      for x in b["blocks"]}:
            errors.append("EMMC and UFS sections enable different images")

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
        print(f"{'PASS' if not errors else 'FAIL'}  {os.path.basename(path)}")
        for err in errors:
            print(f"      - {err}")
        failed += bool(errors)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
