#!/usr/bin/env python3
"""Pre-flight AVB check for the X6882 stock restore images.

Confirms that the stock boot chain in this folder is self-consistent before it
is flashed:

  * every image verifies with its own signed vbmeta footer where it has one,
  * the `vendor_boot` and `dtbo` hash descriptors in `vbmeta.img` match the
    actual files,
  * the `boot`, `vbmeta_system` and `vbmeta_vendor` chain-descriptor keys in
    `vbmeta.img` match the keys embedded in those images.

Requires `avbtool` on PATH. Usage:

    python3 verify-stock-avb.py [DIR]
"""

from __future__ import annotations

import hashlib
import os
import re
import shutil
import subprocess
import sys

IMAGES = [
    "boot.img",
    "vendor_boot.img",
    "dtbo.img",
    "vbmeta.img",
    "vbmeta_system.img",
    "vbmeta_vendor.img",
]

# Hash descriptors verified directly against a file in this folder.
HASH_CHECKED = {"vendor_boot": "vendor_boot.img", "dtbo": "dtbo.img"}
# Chain descriptors and the image that should hold the matching key.
CHAIN_CHECKED = {
    "boot": "boot.img",
    "vbmeta_system": "vbmeta_system.img",
    "vbmeta_vendor": "vbmeta_vendor.img",
}


def avbtool(*args: str) -> tuple[int, str]:
    if not shutil.which("avbtool"):
        sys.exit("avbtool not found on PATH")
    p = subprocess.run(["avbtool", *args], capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def parse(text: str) -> dict:
    out: dict = {"descriptors": []}
    m = re.search(r"^Algorithm:\s+(\S+)$", text, re.M)
    if m:
        out["algorithm"] = m.group(1)
    m = re.search(r"^Public key \(sha1\):\s+([0-9a-f]+)$", text, re.M)
    if m:
        out["key"] = m.group(1)
    m = re.search(r"^Flags:\s+(\d+)$", text, re.M)
    if m:
        out["flags"] = int(m.group(1))

    kind = None
    cur: dict | None = None
    for line in text.splitlines():
        s = line.strip()
        if s == "Hash descriptor:":
            kind, cur = "hash", {}
            out["descriptors"].append((kind, cur))
            continue
        if s == "Hashtree descriptor:":
            kind, cur = "tree", {}
            out["descriptors"].append((kind, cur))
            continue
        if s == "Chain Partition descriptor:":
            kind, cur = "chain", {}
            out["descriptors"].append((kind, cur))
            continue
        if not s:
            kind, cur = None, None
            continue
        if kind and ":" in s:
            k, v = s.split(":", 1)
            cur[k.strip()] = v.strip()
    return out


def main() -> int:
    folder = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))
    folder = os.path.abspath(folder)
    errors: list[str] = []

    for name in IMAGES:
        if not os.path.isfile(os.path.join(folder, name)):
            errors.append(f"{name}: missing")
    if errors:
        for e in errors:
            print(f"FAIL  {e}")
        return 1

    parsed: dict[str, dict] = {}
    for name in IMAGES:
        path = os.path.join(folder, name)
        rc, text = avbtool("info_image", "--image", path)
        if rc != 0 or "Minimum libavb version" not in text:
            errors.append(f"{name}: no readable vbmeta footer")
            continue
        parsed[name] = parse(text)

        rc, vtext = avbtool("verify_image", "--image", path)
        flags = parsed[name].get("flags", 0)
        if flags & 2:
            # avbtool still prints "Successfully verified" but skips every
            # descriptor; a stock image must not have this bit set.
            good = False
            reason = f"verification disabled in footer (flags={flags})"
        elif "Error verifying descriptor" in vtext and name != "vbmeta.img":
            good = False
            reason = "descriptor verification failed"
        elif name == "vbmeta.img":
            # It has a chained boot partition; avbtool cannot check it without
            # --expected_chain_partition and returns non-zero for that.
            good = "Successfully verified SHA256_RSA2048 vbmeta struct" in vtext
            reason = "vbmeta signature"
        else:
            good = "Successfully verified" in vtext
            reason = "footer and descriptors"
        if not good:
            errors.append(f"{name}: {reason}")
        print(f"{'ok  ' if good else 'FAIL'}  {name:20} {parsed[name].get('algorithm','?'):16} "
              f"flags {flags}  key {parsed[name].get('key','-')[:12]}")

    top = parsed.get("vbmeta.img")
    if top is None:
        print()
        for e in errors:
            print(f"FAIL  {e}")
        return 1

    print()
    for kind, d in top["descriptors"]:
        if kind == "hash" and d.get("Partition Name") in HASH_CHECKED:
            name = HASH_CHECKED[d["Partition Name"]]
            size = int(d["Image Size"].split()[0])
            salt = bytes.fromhex(d["Salt"])
            digest = hashlib.sha256(salt + open(os.path.join(folder, name), "rb").read(size)).hexdigest()
            ok = digest == d["Digest"]
            print(f"{'ok  ' if ok else 'FAIL'}  hash descriptor {d['Partition Name']:12} -> {name}")
            if not ok:
                errors.append(f"{d['Partition Name']}: digest mismatch in {name}")

        if kind == "chain" and d.get("Partition Name") in CHAIN_CHECKED:
            part = d["Partition Name"]
            name = CHAIN_CHECKED[part]
            want = d.get("Public key (sha1)", "")
            got = parsed.get(name, {}).get("key", "")
            ok = want == got and want != ""
            print(f"{'ok  ' if ok else 'FAIL'}  chain descriptor {part:12} -> {name}")
            if not ok:
                errors.append(f"{part}: chain key {want[:12]} != {name} key {got[:12]}")

    print()
    if errors:
        for e in errors:
            print(f"FAIL  {e}")
        print(f"\n{len(errors)} problem(s); do not flash these images.")
        return 1
    print("PASS  stock boot chain is AVB-consistent; safe to flash boot and vendor_boot")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
