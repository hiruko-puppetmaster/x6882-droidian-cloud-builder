#!/usr/bin/env bash
#
# setup_repo.sh - create the x6882-droidian-cloud-builder repository.
#
# This script is self-contained: every file below is embedded as a quoted
# heredoc and verified with SHA-256 after it is written.  It never downloads
# anything, never touches the stock dumps, and only needs bash, coreutils and
# git.
#
# Usage:
#   bash setup_repo.sh
#   TARGET_DIR=$HOME/x6882-droidian-cloud-builder bash setup_repo.sh
#   GIT_REMOTE=git@github.com:OWNER/x6882-droidian-cloud-builder.git PUSH=1 \
#       bash setup_repo.sh
#
# Variables:
#   TARGET_DIR     destination (default: this directory when it already
#                  contains the tree, otherwise ./x6882-droidian-cloud-builder)
#   GIT_REMOTE     origin URL to add or update
#   PUSH=1         push main after committing
#   SKIP_PUSH=1    force no push even when PUSH=1
#   FORCE=1        allow a non-empty destination
#   INCLUDE_SELF=0 do not copy this script into the destination
#   GIT_NAME, GIT_EMAIL
#                  commit identity used when git has none configured
#
# The generated repository is well under 1 MB and contains no binaries.
#
set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "${SCRIPT_PATH}")" && pwd)"

TARGET_DIR="${TARGET_DIR:-}"
GIT_REMOTE="${GIT_REMOTE:-}"
PUSH="${PUSH:-0}"
SKIP_PUSH="${SKIP_PUSH:-0}"
FORCE="${FORCE:-0}"
INCLUDE_SELF="${INCLUDE_SELF:-1}"
GIT_NAME="${GIT_NAME:-X6882 Droidian CI}"
GIT_EMAIL="${GIT_EMAIL:-ci@x6882.invalid}"

log()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
fail() { printf '\n\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

command -v git >/dev/null 2>&1 || fail "git is required"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is required"

if [ -z "${TARGET_DIR}" ]; then
    if [ -f "${SCRIPT_DIR}/README.md" ] && \
       [ -f "${SCRIPT_DIR}/.github/workflows/build-droidian-kernel.yml" ] && \
       [ -f "${SCRIPT_DIR}/configs/droidian_x6882.conf" ]; then
        TARGET_DIR="${SCRIPT_DIR}"
    else
        TARGET_DIR="${PWD}/x6882-droidian-cloud-builder"
    fi
fi

mkdir -p "${TARGET_DIR}"
TARGET_DIR="$(cd "${TARGET_DIR}" && pwd)"

# Shared mounts (for example /sdcard on Android) are often owned by another
# uid, which makes git refuse to operate.  Register this one directory as safe
# instead of disabling the ownership check globally.
if ! git config --global --get-all safe.directory 2>/dev/null | grep -qxF "${TARGET_DIR}"; then
    git config --global --add safe.directory "${TARGET_DIR}" || true
fi

if [ "${TARGET_DIR}" = "${SCRIPT_DIR}" ]; then
    log "Updating the tree in place: ${TARGET_DIR}"
    log "Embedded files will be rewritten byte-for-byte from this script."
elif [ "${FORCE}" != "1" ]; then
    if [ -n "$(find "${TARGET_DIR}" -mindepth 1 -maxdepth 1 -print -quit)" ]; then
        fail "destination is not empty: ${TARGET_DIR} (use FORCE=1 to overwrite)"
    fi
fi

log "Writing the repository to ${TARGET_DIR}"
mkdir -p "${TARGET_DIR}/.github/workflows" \
         "${TARGET_DIR}/anykernel" \
         "${TARGET_DIR}/configs" \
         "${TARGET_DIR}/debian/source" \
         "${TARGET_DIR}/scripts"

log "Writing .gitignore"
cat > "${TARGET_DIR}/.gitignore" <<'X6882_FILE_01_64f4bfa6'
# Local build outputs
/out/
/build/
/kernel/
/.toolchain/
/anykernel3/
/stock/
/mode-b/
/Image.gz
/kernel.config
/magiskboot
/Magisk-*.apk

# Logs and scratch files
*.log
*.tmp
X6882_FILE_01_64f4bfa6

log "Writing README.md"
cat > "${TARGET_DIR}/README.md" <<'X6882_FILE_02_fb5ddbeb'
# x6882-droidian-cloud-builder

Build a Droidian (Trixie / Halium 13) kernel and boot images for the
**Infinix Hot 50 4G (`X6882`, MediaTek Helio G100 / `MT6789`)** entirely in
GitHub Actions.

Nothing is compiled locally. There is no kernel checkout, no Docker image, no
downloaded toolchain and no stock image in this repository: the whole tree is
well under 1 MB, and every build runs on a GitHub-hosted runner.

```
push to main ─────────────► Mode A ──► Image.gz + AnyKernel3 zip
workflow_dispatch
   ├─ raw_gki_image ──────► Mode A
   ├─ droidian_deb_package ► Mode B ──► .deb + boot-droidian-base.img
   │                                     + vbmeta-disabled.img + Image.gz
   │                                          │
   │                                          ▼
   └─ both ───────────────► Mode A + Mode B + patch-images
                                              ├─ boot-droidian.img
                                              ├─ vendor_boot-droidian.img
                                              └─ vbmeta-disabled.img
```

## Device facts this tree is built around

| Item | Value |
| --- | --- |
| SoC | MediaTek Helio G100 (`MT6789`) |
| Architecture | arm64, GKI 2.0, kernel 5.10 |
| Boot header | v4 (split `boot` + `vendor_boot`) |
| `boot_a` / `boot_b` | 64 MiB each |
| `vendor_boot_a` / `vendor_boot_b` | 64 MiB each |
| `init_boot_a` / `init_boot_b` | 8 MiB each (too small for the Halium initrd) |
| Kernel source | <https://github.com/XTENSEI/kernel_common_5.10> |
| Default branch | `android12-5.10-rebased` (5.10.274) |
| Alternative branch | `android12-5.10` (5.10.259) |
| Base config | `arch/arm64/configs/gki_defconfig` |
| Cmdline | `bootopt=64S3,32N2,64N2 console=tty0 droidian.lvm.prefer systemd.unified_cgroup_hierarchy=0 selinux=0 enforcing=0` |

## What is in the repository

| Path | Purpose |
| --- | --- |
| `configs/droidian_x6882.conf` | Droidian/Halium config fragment, validated against the pinned Halium `check-kernel-config` |
| `scripts/prepare_kernel_cloud.sh` | Copies `gki_defconfig`, applies the fragment, runs the Halium checker, dedupes symbols, produces `x6882_droidian_defconfig` |
| `debian/kernel-info.mk` | Droidian packaging settings: device identity, cmdline, boot header v4, toolchain |
| `debian/rules` | Includes `linux-packaging-snippets/kernel-snippet.mk`, generates `debian/control`, checks the resolved `.config` |
| `debian/check-config.sh` | Last-line assertions on the `.config` that `olddefconfig` actually produced |
| `debian/copyright`, `debian/source/format` | Debian source package metadata (`3.0 (native)`) |
| `scripts/build_deb_in_container.sh` | Runs inside `quay.io/droidian/build-essential:trixie-amd64`; generates control, builds debs, extracts images |
| `scripts/patch_vendor_boot_cloud.sh` | Merges the stock MTK modules into the Halium initrd, repacks `boot` and `vendor_boot` |
| `anykernel/anykernel.sh` | Hardlink-safe AnyKernel3 script (kernel-only update, `split_boot` + `flash_boot`) |
| `.github/workflows/build-droidian-kernel.yml` | The three CI jobs |
| `setup_repo.sh` | Self-contained bootstrap that recreates every file above and initialises/pushes the git repo |

The kernel tree itself is **not** committed. The workflow clones
`kernel_common_5.10` shallowly, writes the prepared defconfig into it, and for
Mode B uses the checkout as the Debian source package root.

## Prerequisites

1. A GitHub repository (public or private) containing this tree.
2. A release in that repository named exactly **`dump-assets`** with two
   assets named exactly **`boot.img`** and **`vendor_boot.img`** (stock
   X6882 dumps, 64 MiB each). The patch job downloads them with `gh`.
3. An unlocked bootloader on the phone and `fastboot` on the machine that
   flashes the result.
4. GitHub Actions enabled. The free `ubuntu-latest` runner is enough; the
   workflow removes ~20 GB of preinstalled SDKs to make room for the kernel
   build.

Create the release from a machine that has the dumps:

```bash
gh release create dump-assets \
  --repo OWNER/REPO \
  --title "X6882 stock dumps" \
  --notes "Stock boot.img and vendor_boot.img used by the patch stage" \
  boot.img vendor_boot.img
```

If the release already exists:

```bash
gh release upload dump-assets boot.img vendor_boot.img --clobber --repo OWNER/REPO
```

Optional but strongly recommended: upload your stock `vbmeta.img` (and the
rest of a full dump) as well, so a full restore is possible. The workflow only
reads `boot.img` and `vendor_boot.img`; extra assets are ignored.

## Creating the repository

`setup_repo.sh` embeds every file with a quoted heredoc, verifies each file's
SHA-256 after writing, sets executable bits, runs `git init -b main`, commits,
and optionally pushes:

```bash
# create ./x6882-droidian-cloud-builder and commit it
bash setup_repo.sh

# or create it somewhere else
TARGET_DIR=$HOME/x6882-droidian-cloud-builder bash setup_repo.sh

# create, add origin, and push
GIT_REMOTE=git@github.com:OWNER/x6882-droidian-cloud-builder.git \
PUSH=1 bash setup_repo.sh
```

Useful variables:

| Variable | Default | Meaning |
| --- | --- | --- |
| `TARGET_DIR` | `$PWD/x6882-droidian-cloud-builder` | where to write the tree |
| `GIT_REMOTE` | unset | `origin` URL to add |
| `PUSH` | `0` | `1` pushes `main` after committing |
| `SKIP_PUSH` | `0` | `1` forces no push (used by the self-test) |
| `FORCE` | `0` | `1` allows writing into a non-empty directory |
| `GIT_NAME` / `GIT_EMAIL` | `X6882 Droidian CI` / `ci@x6882.invalid` | commit identity when none is configured |

The script is idempotent in the sense that it can be re-run with `FORCE=1` to
overwrite the tracked files; it never touches `dump-assets`.

## Running a build

Push to `main` runs **Mode A** only. Everything else is manual:

```bash
# Image.gz + AnyKernel3
gh workflow run build-droidian-kernel.yml -f mode=raw_gki_image

# Droidian debs + boot-droidian-base.img + vbmeta-disabled.img
gh workflow run build-droidian-kernel.yml -f mode=droidian_deb_package

# Mode A, Mode B, and the device-specific repack
gh workflow run build-droidian-kernel.yml -f mode=both

# Older kernel branch and Clang 14
gh workflow run build-droidian-kernel.yml \
  -f mode=both -f kernel_ref=android12-5.10 -f clang_version=14.0.0
```

Inputs:

| Input | Default | Values |
| --- | --- | --- |
| `mode` | `raw_gki_image` | `raw_gki_image`, `droidian_deb_package`, `both` |
| `kernel_ref` | `android12-5.10-rebased` | `android12-5.10-rebased`, `android12-5.10`, any branch |
| `clang_version` | `12.0.5` | `12.0.5` (`r416183b`), `14.0.0` (`r450784d`) |

Expect roughly **1–2 hours** for Mode A and **2–3 hours** for Mode B on a free
runner. The Clang download is cached across runs; the kernel build is not.
The job timeout is 6 hours.

## Artifacts

Every job keeps its artifact for 30 days.

### `mode-a-raw-gki-image`

| File | Contents |
| --- | --- |
| `Image.gz` | Raw arm64 GKI kernel |
| `x6882-droidian-anykernel3.zip` | AnyKernel3 package containing `Image.gz` and `anykernel/anykernel.sh` |
| `kernel.config` | Resolved `.config` |
| `manifest-mode-a.txt`, `SHA256SUMS-mode-a` | Provenance and checksums |

### `mode-b-droidian-debs`

| File | Contents |
| --- | --- |
| `debs/*.deb` | `linux-image`, `linux-bootimage`, etc. |
| `debs/*.changes`, `debs/*.buildinfo` | Debian build metadata |
| `boot-droidian-base.img` | Halium boot image produced by the packaging snippets (no MTK modules) |
| `boot.img` | Identical copy of `boot-droidian-base.img` |
| `vbmeta-disabled.img` | `avbtool make_vbmeta_image --flags 2 --set_hashtree_disabled_flag` |
| `Image.gz` | Same kernel as Mode A |
| `config-5.10.274-infinix-x6882`, `System.map-…` | Kernel build outputs |
| `manifest.txt`, `SHA256SUMS` | Provenance and checksums |

### `x6882-droidian-boot-images` (Mode B / `both` only)

| File | Contents |
| --- | --- |
| `boot-droidian.img` | Droidian kernel + Halium initrd + stock MTK modules, padded to 64 MiB |
| `vendor_boot-droidian.img` | Stock DTB and `bootopt=` cmdline, **empty** vendor ramdisk |
| `vbmeta-disabled.img` | AVB hashtree/verification disabled |
| `manifest.txt`, `SHA256SUMS` | Provenance and checksums |

## What the patch stage does

Android's stock `vendor_boot.img` is not a generic GKI image. It carries the
device DTB, the `bootopt=64S3,32N2,64N2` vendor cmdline, the vendor ramdisk
table, and 210 MTK kernel modules. None of that exists in the GKI source tree,
so the patch stage reuses the stock image instead of regenerating it:

1. Unpacks the stock `vendor_boot.img` with `magiskboot unpack -h`.
2. Extracts the 210 stock `.ko` files and the module metadata from the vendor
   ramdisk.
3. Unpacks the Droidian `boot-droidian-base.img`, then extracts the Halium
   initrd with **GNU cpio** so the 215-way busybox hardlink group survives
   (`magiskboot cpio` and toybox cpio do not preserve hardlinks).
4. Copies the stock modules into `/lib/modules` of the initrd, skipping eight
   debug/redundant modules that have no reverse dependencies:
   `mkp.ko`, `aee_hangdet.ko`, `aee_rs.ko`, `dbgtop-drm.ko`,
   `mtk_printk_ctrl.ko`, `pidmap.ko`, `cfg80211.ko`, `mac80211.ko`.
   (`cfg80211`/`mac80211` are built into the Droidian kernel.)
5. Writes `/override/modules.load` in dependency order, using
   `modules.dep` + `modules.softdep`, so `insmod` sees providers first.
6. Patches Halium's `scripts/halium` from `modprobe -a "$1"` to
   `insmod -f "$1"`, and replaces the zero-size `/sbin/insmod` hardlink with a
   symlink to `/bin/kmod`.
7. Writes the full Droidian cmdline into both the boot header and the
   vendor_boot header.
8. Replaces the stock vendor ramdisk with an empty cpio so Android's broken
   `/init -> /system/bin/ini` symlink cannot shadow Droidian's `/init`.
9. Repacks both images with `magiskboot`, sets `PATCHVBMETAFLAG=true`, pads
   `boot-droidian.img` to exactly 67,108,864 bytes, and verifies cmdline,
   kernel bytes, `/init`, `/bin/kmod`, the module list, the `insmod` symlink,
   the empty vendor ramdisk, and the unchanged DTB.

## Flashing

These images are **unsigned** and the phone must have an **unlocked
bootloader**. `selinux=0 enforcing=0` is a development configuration; do not
ship it as-is.

```bash
adb reboot bootloader
fastboot devices

# Flash the active slot (fastboot resolves boot -> boot_a/boot_b)
fastboot flash boot         boot-droidian.img
fastboot flash vendor_boot  vendor_boot-droidian.img
fastboot --disable-verity --disable-verification flash vbmeta vbmeta-disabled.img
fastboot reboot
```

To flash both slots explicitly:

```bash
for slot in a b; do
  fastboot flash boot_$slot         boot-droidian.img
  fastboot flash vendor_boot_$slot  vendor_boot-droidian.img
  fastboot --disable-verity --disable-verification flash vbmeta_$slot vbmeta-disabled.img
done
```

Notes:

* `boot-droidian.img` is exactly 64 MiB. Do not truncate or recompress it.
* `vendor_boot-droidian.img` keeps the stock 64 MiB size and DTB.
* If the bootloader keeps complaining about verification, also flash the
  disabled vbmeta into the chained partitions:
  `fastboot --disable-verity --disable-verification flash vbmeta_system vbmeta-disabled.img`
  and the same for `vbmeta_vendor`.
* `init_boot` is deliberately untouched. It is only 8 MiB and cannot hold the
  ~20 MB Halium initrd; this port boots the initrd from `boot`.
* The `AnyKernel3` zip is only for **updating the kernel after Droidian is
  already installed**. It reuses the existing Droidian ramdisk, replaces only
  `Image.gz`, and writes `boot`. It cannot turn a stock Android boot image
  into a Droidian one. Use a recovery or a root kernel-flasher app.
* This repository builds kernel/boot images and Debian packages. It does not
  build the Droidian rootfs; install the rootfs with the normal Halium /
  Droidian porting flow and then use these images.

## Recovery

Keep the stock dumps. If the phone does not boot:

```bash
adb reboot bootloader   # or hold the key combo for fastboot
fastboot flash boot        stock/boot.img
fastboot flash vendor_boot stock/vendor_boot.img
fastboot reboot
```

Flashing the stock images back does not require a stock `vbmeta` unless you
also flashed `vbmeta-disabled.img` and want verification back; in that case
restore your stock `vbmeta.img` too.

## Config and packaging details

* `configs/droidian_x6882.conf` starts from the GKI defconfig and
  - disables `CONFIG_KSU`, `CONFIG_KSU_SUSFS`, `CONFIG_SUSFS`,
    `CONFIG_MODVERSIONS`;
  - enables `CONFIG_MODULE_FORCE_LOAD`, VT/VT_CONSOLE, DEVTMPFS,
    DEVTMPFS_MOUNT, SYSVIPC, POSIX_MQUEUE, CGROUPS, NAMESPACES, USER_NS,
    NET_NS, USB_CONFIGFS_RNDIS, ANDROID_BINDER_IPC, SELinux develop mode;
  - sets AppArmor as the default LSM (`CONFIG_DEFAULT_SECURITY_APPARMOR=y`),
    with SELinux still available for Halium;
  - disables LTO/CFI/KASAN/UBSAN/DEBUG_INFO and clears `CONFIG_LOCALVERSION`
    and `CONFIG_CMDLINE`;
  - adds `CONFIG_RD_GZIP`, `CONFIG_RD_LZ4`, ZRAM/ZSMALLOC/ZPOOL/SWAP, and
    in-tree `CFG80211`/`MAC80211`.
* `scripts/prepare_kernel_cloud.sh` uses the Halium checker pinned at
  `Halium/halium-boot@499ea587183ea9407a0ccce64013b6cfa80d0efe`
  (SHA-256 `4859517985c5180b3686be2dd57dc3b5c83d31bc3e37db6657b09870dd8bdd61`).
  The checker's `-w` mode has known bugs (`CONFIG_DEFAULT_SECURITY` rewriting
  and duplicate symbols), so the fragment is re-applied afterwards, symbols
  are deduplicated with last-occurrence-wins, and a final read-only checker
  run must print `found no errors`. The checker exits 0 even when it reports
  errors, so its log is parsed explicitly.
* `debian/kernel-info.mk` sets `KERNEL_RELEASE = 5.10.274-infinix-x6882`,
  `KERNEL_BOOTIMAGE_VERSION = 4`, `KERNEL_INITRAMFS_COMPRESSION = lz4`,
  `DEVICE_HAS_INIT_BOOT = 0`, and the exact cmdline above.
* Mode B runs in `quay.io/droidian/build-essential:trixie-amd64`, adds
  `https://staging.repo.droidian.org/ trixie main`, installs
  `linux-packaging-snippets` and `linux-initramfs-halium-generic:arm64`,
  generates `debian/control`, and calls `releng-build-package` with
  `CI=true IS_CONTAINER=true RELENG_HOST_ARCH=arm64`.
* `debian/changelog` is created in the container from
  `debian/source/format` (`3.0 (native)`) and the `feature/x6882` branch, so
  `releng-build-package` produces a rolling `next`/trixie version such as
  `5.10.274+git<timestamp>.<sha>.x6882`.

## Known limitations

* **This is a pure GKI tree.** `XTENSEI/kernel_common_5.10` has no
  `drivers/misc/mediatek`. Several stock MTK modules reference symbols that
  the stock kernel exports from built-in MediaTek code (for example
  `__log_write_mmio` / `__log_read_mmio` / `__log_post_read_mmio` used by
  `mtk-smi.ko`). Those symbols do not exist in this kernel, so the affected
  modules fail `insmod` with `Unknown symbol` even with `insmod -f` and
  `CONFIG_MODULE_FORCE_LOAD=y`. UFS, display or other peripherals may be
  affected. The images are **best-effort**; a fully working device needs the
  vendor kernel tree, not pure GKI.
* The stock modules were built for `5.10.226-android12-…-dirty` with
  `modversions`. This kernel is 5.10.274 without `CONFIG_MODVERSIONS`.
  `insmod -f` forces the vermagic/modversion checks, but it cannot invent
  missing symbols or fix a real ABI mismatch. Keep the `kernel_ref` input on
  `android12-5.10-rebased`; the closer the version, the better the odds.
* `init_boot` is unused. Do not try to move the initrd there.
* The repacked images are not AVB-signed. An unlocked bootloader and
  `vbmeta-disabled.img` are required.
* Android will not boot with these images: the vendor ramdisk is emptied and
  the cmdline is Droidian-specific.
* The kernel and initrd are built for development (`selinux=0`, `enforcing=0`,
  no LTO/CFI). Do not use this as a hardened production configuration.

## Validation performed locally

* `configs/droidian_x6882.conf` was run through the pinned Halium checker
  together with the GKI defconfig and reports `found no errors`, with no
  duplicate symbols and the required symbols present.
* All shell scripts pass `bash -n`.
* The stock module graph was checked for dependency cycles (none) and for
  reverse dependencies of the skipped modules (only `cfg80211.ko` is used by
  `mac80211.ko`, and both are built in-tree).
* The stock `boot.img` / `vendor_boot.img` headers, AVB footers, ramdisk
  contents, DTB sizes and partition sizes were inspected and the repack logic
  was written against those exact values.
* The workflow itself has not been executed yet. The first CI run will
  validate the container paths, GNU cpio hardlink handling and the
  `releng-build-package` invocation.

## Local footprint

The tracked tree is a few hundred kilobytes of text. Building does not need
a local clone of the kernel, a local Docker image, a local toolchain, or a
local compiler. Only `git`/`gh` (to publish and trigger) and `fastboot` (to
flash) are needed on your machine.

## License

No license is declared. The files are porting glue for personal use; the
kernel source and the Droidian packaging snippets keep their own licenses.
X6882_FILE_02_fb5ddbeb

log "Writing .github/workflows/build-droidian-kernel.yml"
cat > "${TARGET_DIR}/.github/workflows/build-droidian-kernel.yml" <<'X6882_FILE_03_2de7ed6c'
name: Build Droidian kernel for X6882

on:
  push:
    branches:
      - main
  workflow_dispatch:
    inputs:
      mode:
        description: "Build mode"
        type: choice
        required: true
        default: raw_gki_image
        options:
          - raw_gki_image
          - droidian_deb_package
          - both
      kernel_ref:
        description: "kernel_common_5.10 branch"
        type: string
        required: false
        default: android12-5.10-rebased
      clang_version:
        description: "Clang toolchain"
        type: choice
        required: true
        default: "12.0.5"
        options:
          - "12.0.5"
          - "14.0.0"

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: false

permissions:
  contents: read

env:
  KERNEL_REPO: https://github.com/XTENSEI/kernel_common_5.10.git
  KERNEL_REF: ${{ github.event.inputs.kernel_ref || 'android12-5.10-rebased' }}
  CLANG_VERSION: ${{ github.event.inputs.clang_version || '12.0.5' }}
  CLANG_12_URL: https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/tags/android-12.0.0_r21/clang-r416183b.tar.gz
  CLANG_14_URL: https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/refs/tags/android-13.0.0_r1/clang-r450784d.tar.gz
  MAGISK_APK_URL: https://github.com/topjohnwu/Magisk/releases/download/v28.1/Magisk-v28.1.apk
  MAGISK_APK_SHA256: 8bfd3346b3da5814f82eff6f1b1b5fedd0ad585f39a25709b23eb54aac45691d
  MAGISKBOOT_SHA256: 1ef29846a363db25d3f277de5619e01878241ff3d9bf760bddda994419198dcc

jobs:
  # ---------------------------------------------------------------------
  # Mode A: raw GKI Image.gz + AnyKernel3 flashable zip
  # ---------------------------------------------------------------------
  build-image:
    name: Mode A - Image.gz + AnyKernel3
    if: >-
      github.event_name == 'push' ||
      github.event.inputs.mode == 'raw_gki_image' ||
      github.event.inputs.mode == 'both'
    runs-on: ubuntu-latest
    timeout-minutes: 360
    steps:
      - name: Checkout builder
        uses: actions/checkout@v4

      - name: Free disk space
        run: |
          set -x
          sudo rm -rf /usr/share/dotnet
          sudo rm -rf /usr/local/lib/android
          sudo rm -rf /opt/ghc
          sudo rm -rf /opt/hostedtoolcache/CodeQL
          sudo apt-get clean
          docker image prune -af || true
          df -h
          nproc
          free -h

      - name: Install host packages
        run: |
          sudo apt-get update -o Acquire::Retries=3
          sudo apt-get install -y --no-install-recommends \
            bc bison flex libssl-dev libelf-dev \
            rsync cpio lz4 zip unzip python3 perl \
            build-essential binutils-aarch64-linux-gnu

      - name: Restore Clang
        id: clang-cache
        uses: actions/cache@v4
        with:
          path: .toolchain
          key: clang-${{ env.CLANG_VERSION }}-${{ runner.os }}-v1

      - name: Download Clang
        run: |
          set -euo pipefail
          case "$CLANG_VERSION" in
            12.0.5) CLANG_DIR=clang-r416183b; CLANG_URL="$CLANG_12_URL" ;;
            14.0.0) CLANG_DIR=clang-r450784d; CLANG_URL="$CLANG_14_URL" ;;
            *) echo "::error::unknown Clang version $CLANG_VERSION"; exit 1 ;;
          esac
          echo "CLANG_DIR=$CLANG_DIR" >> "$GITHUB_ENV"
          mkdir -p ".toolchain/$CLANG_DIR"
          if [ ! -x ".toolchain/$CLANG_DIR/bin/clang" ]; then
            echo "Downloading $CLANG_URL"
            curl -fsSL --retry 4 --retry-delay 5 --max-time 600 "$CLANG_URL" \
              | tar -xz -C ".toolchain/$CLANG_DIR"
          fi
          ".toolchain/$CLANG_DIR/bin/clang" --version

      - name: Clone kernel
        run: |
          set -euo pipefail
          git clone --depth 1 --branch "$KERNEL_REF" "$KERNEL_REPO" kernel
          test -f kernel/arch/arm64/configs/gki_defconfig
          git -C kernel log --oneline -n 1

      - name: Prepare Droidian defconfig
        run: |
          set -euo pipefail
          bash scripts/prepare_kernel_cloud.sh kernel "$PWD/configs/droidian_x6882.conf"
          cp kernel/arch/arm64/configs/x6882_droidian_defconfig \
             "$RUNNER_TEMP/x6882_droidian_defconfig"

      - name: Build Image.gz
        run: |
          set -euo pipefail
          export PATH="$PWD/.toolchain/$CLANG_DIR/bin:$PATH"
          BUILD_DIR="$PWD/build"
          mkdir -p "$BUILD_DIR"
          COMMON_ARGS=(
            -C kernel
            O="$BUILD_DIR"
            ARCH=arm64
            LLVM=1
            LLVM_IAS=1
            CROSS_COMPILE=aarch64-linux-gnu-
            CLANG_TRIPLE=aarch64-linux-gnu-
          )
          make "${COMMON_ARGS[@]}" -j"$(nproc)" x6882_droidian_defconfig
          make "${COMMON_ARGS[@]}" -j"$(nproc)" Image.gz
          test -s "$BUILD_DIR/arch/arm64/boot/Image.gz"
          gzip -t "$BUILD_DIR/arch/arm64/boot/Image.gz"
          cp "$BUILD_DIR/arch/arm64/boot/Image.gz" "$PWD/Image.gz"
          cp "$BUILD_DIR/.config" "$PWD/kernel.config"
          ls -l Image.gz kernel.config

      - name: Package AnyKernel3
        run: |
          set -euo pipefail
          git clone --filter=blob:none https://github.com/osm0sis/AnyKernel3.git anykernel3
          git -C anykernel3 checkout 41f04bdb4ee30a44e429c2c1131d5e8bb32b15f1
          cp anykernel/anykernel.sh anykernel3/anykernel.sh
          cp Image.gz anykernel3/Image.gz
          rm -rf anykernel3/.git anykernel3/.github anykernel3/README.md
          find anykernel3 -name '*placeholder' -delete
          ( cd anykernel3 && zip -r9 "$PWD/../x6882-droidian-anykernel3.zip" . )
          unzip -l x6882-droidian-anykernel3.zip | sed -n '1,40p'
          unzip -p x6882-droidian-anykernel3.zip anykernel.sh | head -n 5

      - name: Write checksums
        run: |
          set -euo pipefail
          {
            printf 'kernel_ref=%s\n' "$KERNEL_REF"
            printf 'clang_version=%s\n' "$CLANG_VERSION"
            printf 'kernel_release=%s\n' "$(make -s -C kernel O="$PWD/build" ARCH=arm64 kernelrelease 2>/dev/null || true)"
            printf 'image_gz_sha256=%s\n' "$(sha256sum Image.gz | awk '{print $1}')"
            printf 'anykernel_sha256=%s\n' "$(sha256sum x6882-droidian-anykernel3.zip | awk '{print $1}')"
          } > manifest-mode-a.txt
          sha256sum Image.gz x6882-droidian-anykernel3.zip manifest-mode-a.txt > SHA256SUMS-mode-a
          cat manifest-mode-a.txt

      - name: Upload raw image and AnyKernel3 zip
        uses: actions/upload-artifact@v4
        with:
          name: mode-a-raw-gki-image
          if-no-files-found: error
          retention-days: 30
          path: |
            Image.gz
            x6882-droidian-anykernel3.zip
            kernel.config
            manifest-mode-a.txt
            SHA256SUMS-mode-a

  # ---------------------------------------------------------------------
  # Mode B: Droidian Debian packages + boot/vbmeta images
  # ---------------------------------------------------------------------
  build-debs:
    name: Mode B - Droidian Debian packages
    if: >-
      github.event_name == 'workflow_dispatch' &&
      (github.event.inputs.mode == 'droidian_deb_package' ||
       github.event.inputs.mode == 'both')
    runs-on: ubuntu-latest
    timeout-minutes: 360
    steps:
      - name: Checkout builder
        uses: actions/checkout@v4

      - name: Free disk space
        run: |
          set -x
          sudo rm -rf /usr/share/dotnet
          sudo rm -rf /usr/local/lib/android
          sudo rm -rf /opt/ghc
          sudo rm -rf /opt/hostedtoolcache/CodeQL
          sudo apt-get clean
          docker image prune -af || true
          df -h
          nproc
          free -h

      - name: Clone kernel
        run: |
          set -euo pipefail
          git clone --depth 1 --branch "$KERNEL_REF" "$KERNEL_REPO" kernel
          test -f kernel/arch/arm64/configs/gki_defconfig
          git -C kernel log --oneline -n 1
          git -C kernel remote get-url origin

      - name: Prepare Droidian defconfig
        run: |
          set -euo pipefail
          bash scripts/prepare_kernel_cloud.sh kernel "$PWD/configs/droidian_x6882.conf"
          cp kernel/arch/arm64/configs/x6882_droidian_defconfig \
             "$RUNNER_TEMP/x6882_droidian_defconfig"

      - name: Install packaging files into the kernel tree
        run: |
          set -euo pipefail
          cp -a debian kernel/debian
          chmod +x kernel/debian/rules kernel/debian/check-config.sh
          test -f kernel/debian/source/format
          ls -la kernel/debian

      - name: Pull Droidian build container
        run: |
          set -euo pipefail
          docker pull quay.io/droidian/build-essential:trixie-amd64
          docker image inspect quay.io/droidian/build-essential:trixie-amd64 \
            --format '{{.Id}} {{.Size}}'

      - name: Build packages in the container
        run: |
          set -euo pipefail
          mkdir -p out
          docker run --rm \
            -e KERNEL_SRC=/build/linux-android-infinix-x6882 \
            -e ARTIFACTS=/artifacts \
            -e JOBS="$(nproc)" \
            -v "$PWD/kernel:/build/linux-android-infinix-x6882" \
            -v "$PWD/out:/artifacts" \
            -v "$PWD/scripts:/scripts:ro" \
            quay.io/droidian/build-essential:trixie-amd64 \
            bash /scripts/build_deb_in_container.sh

      - name: Verify extracted images
        run: |
          set -euo pipefail
          test -s out/boot-droidian-base.img
          test -s out/vbmeta-disabled.img
          test -s out/Image.gz
          python3 - <<'PY'
          import glob
          import struct

          boot = open("out/boot-droidian-base.img", "rb").read(8)
          assert boot == b"ANDROID!", boot
          vbmeta = open("out/vbmeta-disabled.img", "rb").read(4)
          assert vbmeta == b"AVB0", vbmeta
          debs = glob.glob("out/debs/*.deb")
          assert debs, "no .deb files"
          print(f"boot image magic OK, vbmeta magic OK, {len(debs)} deb(s)")
          PY
          ls -l out out/debs
          cat out/manifest.txt

      - name: Upload Droidian debs and images
        uses: actions/upload-artifact@v4
        with:
          name: mode-b-droidian-debs
          if-no-files-found: error
          retention-days: 30
          path: |
            out/debs
            out/boot-droidian-base.img
            out/boot.img
            out/vbmeta-disabled.img
            out/Image.gz
            out/config-*
            out/System.map-*
            out/manifest.txt
            out/SHA256SUMS

  # ---------------------------------------------------------------------
  # Merge the stock MTK vendor modules and repack both images
  # ---------------------------------------------------------------------
  patch-images:
    name: Repack boot/vendor_boot for the device
    needs: build-debs
    runs-on: ubuntu-latest
    timeout-minutes: 60
    steps:
      - name: Checkout builder
        uses: actions/checkout@v4

      - name: Download Mode B artifacts
        uses: actions/download-artifact@v4
        with:
          name: mode-b-droidian-debs
          path: mode-b

      - name: Verify Mode B artifacts
        run: |
          set -euo pipefail
          test -s mode-b/boot-droidian-base.img
          test -s mode-b/vbmeta-disabled.img
          test -s mode-b/Image.gz
          ls -l mode-b

      - name: Check the dump-assets release
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          set -euo pipefail
          if ! gh release view dump-assets --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
            echo "::error::Release 'dump-assets' not found. Upload stock boot.img and vendor_boot.img to a release named dump-assets."
            exit 1
          fi
          gh release view dump-assets --repo "$GITHUB_REPOSITORY" --json assets \
            --jq '.assets[].name'

      - name: Download stock boot and vendor_boot
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          set -euo pipefail
          mkdir -p stock
          gh release download dump-assets --repo "$GITHUB_REPOSITORY" \
            --pattern boot.img --pattern vendor_boot.img --dir stock --clobber
          python3 - <<'PY'
          import os

          for name, magic in (("stock/boot.img", b"ANDROID!"),
                              ("stock/vendor_boot.img", b"VNDRBOOT")):
              size = os.path.getsize(name)
              with open(name, "rb") as fh:
                  head = fh.read(8)
              assert head == magic, f"{name}: unexpected magic {head!r}"
              assert size == 67108864, f"{name}: expected 64 MiB, got {size}"
              print(f"{name}: {size} bytes, magic OK")
          PY

      - name: Download Magisk v28.1 magiskboot
        run: |
          set -euo pipefail
          curl -fsSL --retry 4 --retry-delay 5 --max-time 300 \
            -o Magisk-v28.1.apk "$MAGISK_APK_URL"
          echo "$MAGISK_APK_SHA256  Magisk-v28.1.apk" | sha256sum -c -
          unzip -o Magisk-v28.1.apk lib/x86_64/libmagiskboot.so -d magisk
          cp magisk/lib/x86_64/libmagiskboot.so magiskboot
          chmod +x magiskboot
          echo "$MAGISKBOOT_SHA256  magiskboot" | sha256sum -c -
          ./magiskboot 2>&1 | head -n 5 || true

      - name: Repack images
        run: |
          set -euo pipefail
          bash scripts/patch_vendor_boot_cloud.sh \
            --magiskboot magiskboot \
            --droidian-boot mode-b/boot-droidian-base.img \
            --vendor-boot stock/vendor_boot.img \
            --image mode-b/Image.gz \
            --outdir out \
            --keep-work

      - name: Summarize
        run: |
          set -euo pipefail
          {
            echo "### X6882 Droidian images"
            echo
            echo '```'
            cat out/manifest.txt
            echo '```'
            echo
            echo '```'
            cat out/SHA256SUMS
            echo '```'
          } >> "$GITHUB_STEP_SUMMARY"
          ls -l out

      - name: Upload flashable images
        uses: actions/upload-artifact@v4
        with:
          name: x6882-droidian-boot-images
          if-no-files-found: error
          retention-days: 30
          path: |
            out/boot-droidian.img
            out/vendor_boot-droidian.img
            out/vbmeta-disabled.img
            out/manifest.txt
            out/SHA256SUMS
X6882_FILE_03_2de7ed6c

log "Writing anykernel/anykernel.sh"
cat > "${TARGET_DIR}/anykernel/anykernel.sh" <<'X6882_FILE_04_b8c3a973'
### AnyKernel3 Ramdisk Mod Script
## X6882 Droidian port
# shellcheck shell=bash
# This file is sourced by AnyKernel3's update-binary, not executed directly.
# shellcheck disable=SC2034,SC2289

### AnyKernel setup
properties() { '
kernel.string=Droidian 5.10 for Infinix Hot 50 4G (X6882)
do.devicecheck=0
do.modules=0
do.systemless=0
do.cleanup=1
do.cleanuponabort=0
device.name1=
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties

### AnyKernel install
## boot files attributes
boot_attributes() {
set_perm_recursive 0 0 755 644 $RAMDISK/*;
set_perm_recursive 0 0 750 750 $RAMDISK/init* $RAMDISK/sbin;
} # end attributes

# boot shell variables
BLOCK=/dev/block/by-name/boot;
IS_SLOT_DEVICE=1;
RAMDISK_COMPRESSION=auto;
PATCH_VBMETA_FLAG=1;

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh;

# Only split the image.  dump_boot would extract and rebuild the ramdisk with
# the device's cpio, which destroys the 215-way busybox hardlink group in the
# Halium initrd (the busybox data lives on sbin/fdisk).  split_boot keeps the
# decompressed cpio byte-for-byte.
split_boot;

[ -f $SPLITIMG/ramdisk.cpio ] || \
  abort "No ramdisk found in the boot image. Flash boot-droidian.img first!";

# Replace the kernel, keeping the Droidian initrd untouched.  ramdisk.cpio is
# left uncompressed: flash_boot runs "magiskboot cpio ... test" on it, and
# magiskboot repack forces LZ4-legacy for a v4 boot image by itself.
cp -f $AKHOME/Image.gz $SPLITIMG/kernel || abort "Failed to install Image.gz";
ui_print " " "Kernel: $(wc -c < $AKHOME/Image.gz) bytes";
ui_print " " "Initrd: $(wc -c < $SPLITIMG/ramdisk.cpio) bytes (uncompressed cpio)";

# flash_boot builds, signs (when the running image is signed) and writes the
# boot partition.  do.modules=0, so vendor_dlkm/system_dlkm/dtbo are untouched.
flash_boot;
X6882_FILE_04_b8c3a973

log "Writing configs/droidian_x6882.conf"
cat > "${TARGET_DIR}/configs/droidian_x6882.conf" <<'X6882_FILE_05_f220ec04'
# Droidian / Halium fragment for the Infinix Hot 50 4G (X6882, MediaTek MT6789).
#
# This file is appended to arch/arm64/configs/gki_defconfig by
# scripts/prepare_kernel_cloud.sh.  The Halium checker is then run with -w,
# and the result is written to arch/arm64/configs/x6882_droidian_defconfig.
#
# Keep this file declarative: one CONFIG_* assignment per line.  Lines are
# de-duplicated by the prepare script, last occurrence wins.

# ---------------------------------------------------------------------------
# Toolchain / build size
# ---------------------------------------------------------------------------
# The packaging tree is the kernel tree, so the version must come from the
# kernel Makefile alone (no vendor suffix, no local dirty marker).
CONFIG_LOCALVERSION=""
# Never inject Android debug arguments into every boot.
CONFIG_CMDLINE=""
# CONFIG_CMDLINE_FORCE is not set

# Keep the build within a normal CI runner and avoid a hard requirement on
# pahole / full LLVM LTO plugins.  The stock MTK modules were built without
# LTO/CFI as well.
# CONFIG_LTO_CLANG is not set
# CONFIG_LTO_CLANG_FULL is not set
# CONFIG_LTO_CLANG_THIN is not set
CONFIG_LTO_NONE=y
# CONFIG_CFI_CLANG is not set
# CONFIG_KASAN is not set
# CONFIG_KASAN_INLINE is not set
# CONFIG_KASAN_OUTLINE is not set
# CONFIG_KASAN_HW_TAGS is not set
# CONFIG_KASAN_SW_TAGS is not set
# CONFIG_UBSAN is not set
# CONFIG_UBSAN_TRAP is not set
# CONFIG_UBSAN_LOCAL_BOUNDS is not set
# CONFIG_DEBUG_INFO is not set
# CONFIG_DEBUG_INFO_DWARF4 is not set
# CONFIG_DEBUG_INFO_BTF is not set

# Never strip exports: the vendor modules are built against the vendor tree
# and need whatever symbols the GKI image can provide.
# CONFIG_TRIM_UNUSED_KSYMS is not set

# ---------------------------------------------------------------------------
# Kernel module ABI for the stock MTK vendor modules
# ---------------------------------------------------------------------------
# The stock modules carry vermagic 5.10.226...modversions and CRCs generated
# by the vendor build.  We cannot reproduce those CRCs, so turn MODVERSIONS
# off entirely and force-load with insmod -f.  WITH MODVERSIONS=n the kernel
# skips CRC checks completely; -f bypasses the remaining vermagic check.
# CONFIG_MODVERSIONS is not set
CONFIG_MODULE_FORCE_LOAD=y
CONFIG_MODULE_ALLOW_MISSING_NAMESPACE_IMPORTS=y
# CONFIG_MODULE_SIG is not set
# CONFIG_MODULE_SIG_FORCE is not set
# CONFIG_MODULE_COMPRESS is not set

# KernelSU / SUSFS are Android-root features and are not wanted here.
# CONFIG_KSU is not set
# CONFIG_KSU_SUSFS is not set
# CONFIG_SUSFS is not set

# ---------------------------------------------------------------------------
# Initramfs / root filesystem
# ---------------------------------------------------------------------------
CONFIG_BLK_DEV_INITRD=y
CONFIG_RD_GZIP=y
CONFIG_RD_LZ4=y
# CONFIG_RD_BZIP2 is not set
# CONFIG_RD_LZMA is not set
# CONFIG_RD_XZ is not set
# CONFIG_RD_LZO is not set
# CONFIG_RD_ZSTD is not set
# The Halium initramfs is supplied by the packaging snippet, not built in.
CONFIG_INITRAMFS_SOURCE=""
CONFIG_INITRAMFS_COMPRESSION_NONE=y

# ---------------------------------------------------------------------------
# Halium / Droidian userspace requirements
# ---------------------------------------------------------------------------
CONFIG_DEVTMPFS=y
CONFIG_DEVTMPFS_MOUNT=y
CONFIG_SYSVIPC=y
CONFIG_POSIX_MQUEUE=y
CONFIG_CGROUPS=y
CONFIG_CGROUP_DEVICE=y
CONFIG_CGROUP_FREEZER=y
CONFIG_CGROUP_PIDS=y
CONFIG_CGROUP_BPF=y
CONFIG_CGROUP_SCHED=y
CONFIG_MEMCG=y
CONFIG_BLK_CGROUP=y
CONFIG_CPUSETS=y
CONFIG_NAMESPACES=y
CONFIG_UTS_NS=y
CONFIG_IPC_NS=y
CONFIG_USER_NS=y
CONFIG_PID_NS=y
CONFIG_NET_NS=y
CONFIG_SECCOMP=y
CONFIG_SECCOMP_FILTER=y
CONFIG_IKCONFIG=y
CONFIG_IKCONFIG_PROC=y
CONFIG_AUTOFS4_FS=y
CONFIG_FSNOTIFY=y
CONFIG_DNOTIFY=y
CONFIG_INOTIFY_USER=y
CONFIG_FANOTIFY=y
CONFIG_FANOTIFY_ACCESS_PERMISSIONS=y
CONFIG_EPOLL=y
CONFIG_SIGNALFD=y
CONFIG_TIMERFD=y
CONFIG_EVENTFD=y
CONFIG_FHANDLE=y
CONFIG_AUDIT=y
CONFIG_AUDITSYSCALL=y
CONFIG_AUDIT_TREE=y
CONFIG_AUDIT_WATCH=y
CONFIG_KEYS=y
CONFIG_ENCRYPTED_KEYS=y
CONFIG_TRUSTED_KEYS=y
CONFIG_SWAP=y
CONFIG_SYN_COOKIES=y
CONFIG_STRICT_DEVMEM=y
CONFIG_CONSOLE_TRANSLATIONS=y
CONFIG_CORE_DUMP_DEFAULT_ELF_HEADERS=y
CONFIG_SUSPEND_TIME=y

# Virtual terminal.  tty0 is only a dummy console here; the Droidian session
# renders through DRM/KMS, and the Halium checker forbids fbcon.
CONFIG_VT=y
CONFIG_VT_CONSOLE=y
# CONFIG_VT_HW_CONSOLE_BINDING is not set
# CONFIG_FRAMEBUFFER_CONSOLE is not set
# CONFIG_SPEAKUP is not set

# Android inter-process plumbing used by libhybris / Halium.
CONFIG_ANDROID=y
CONFIG_ANDROID_BINDER_IPC=y
CONFIG_ANDROID_BINDER_DEVICES="binder,hwbinder,vndbinder"
CONFIG_ASHMEM=y
CONFIG_SYNC_FILE=y
CONFIG_DMABUF_HEAPS=y
CONFIG_DMABUF_HEAPS_SYSTEM=y
CONFIG_DMABUF_HEAPS_CMA=y
CONFIG_DMABUF_HEAPS_DEFERRED_FREE=y
CONFIG_DMABUF_HEAPS_PAGE_POOL=y
CONFIG_DMA_SHARED_BUFFER=y

# ---------------------------------------------------------------------------
# Storage: UFS for the internal flash, MMC for the SD tray, LVM/dm for root
# ---------------------------------------------------------------------------
CONFIG_BLOCK=y
CONFIG_SCSI=y
CONFIG_BLK_DEV_SD=y
CONFIG_SCSI_UFSHCD=y
CONFIG_SCSI_UFSHCD_PLATFORM=y
CONFIG_SCSI_UFS_BSG=y
CONFIG_SCSI_UFS_CRYPTO=y
CONFIG_MMC=y
CONFIG_MMC_BLOCK=y
CONFIG_BLK_DEV_LOOP=y
CONFIG_BLK_DEV_LOOP_MIN_COUNT=16
CONFIG_BLK_DEV_DM=y
CONFIG_DM_CRYPT=y
CONFIG_DM_SNAPSHOT=y
CONFIG_DM_THIN_PROVISIONING=y
CONFIG_DM_UEVENT=y
CONFIG_DM_VERITY=y
CONFIG_DM_VERITY_FEC=y
CONFIG_MD=y

# ---------------------------------------------------------------------------
# Filesystems used by Droidian, Android vendor partitions and SD cards
# ---------------------------------------------------------------------------
CONFIG_EXT4_FS=y
CONFIG_EXT4_FS_POSIX_ACL=y
CONFIG_EXT4_FS_SECURITY=y
CONFIG_F2FS_FS=y
CONFIG_F2FS_FS_XATTR=y
CONFIG_F2FS_FS_POSIX_ACL=y
CONFIG_F2FS_FS_SECURITY=y
CONFIG_EROFS_FS=y
CONFIG_OVERLAY_FS=y
CONFIG_SQUASHFS=y
CONFIG_SQUASHFS_XATTR=y
CONFIG_SQUASHFS_LZ4=y
CONFIG_SQUASHFS_ZLIB=y
CONFIG_VFAT_FS=y
CONFIG_EXFAT_FS=y
CONFIG_TMPFS=y
CONFIG_TMPFS_XATTR=y
CONFIG_TMPFS_POSIX_ACL=y
CONFIG_PROC_FS=y
CONFIG_SYSFS=y
CONFIG_CONFIGFS_FS=y
CONFIG_FUSE_FS=y
CONFIG_NLS_CODEPAGE_437=y
CONFIG_NLS_ISO8859_1=y
CONFIG_NLS_UTF8=y

# ---------------------------------------------------------------------------
# Memory: zram backed swap (the device has no swap partition)
# ---------------------------------------------------------------------------
CONFIG_ZPOOL=y
CONFIG_ZBUD=y
CONFIG_Z3FOLD=y
CONFIG_ZSMALLOC=y
CONFIG_ZRAM=y
CONFIG_ZRAM_DEF_COMP_LZORLE=y
CONFIG_CRYPTO_LZO=y
CONFIG_CRYPTO_LZO_RLE=y
CONFIG_CRYPTO_LZ4=y
CONFIG_CRYPTO_DEFLATE=y
CONFIG_CRYPTO_ZSTD=y

# ---------------------------------------------------------------------------
# USB gadget: Halium uses configfs + RNDIS for the USB network link
# ---------------------------------------------------------------------------
CONFIG_USB=y
CONFIG_USB_SUPPORT=y
CONFIG_USB_GADGET=y
CONFIG_USB_CONFIGFS=y
CONFIG_USB_CONFIGFS_F_FS=y
CONFIG_USB_CONFIGFS_RNDIS=y
CONFIG_USB_CONFIGFS_ECM=y
CONFIG_USB_CONFIGFS_NCM=y
CONFIG_USB_CONFIGFS_ACM=y
CONFIG_USB_CONFIGFS_MASS_STORAGE=y
CONFIG_USB_F_FS=y
CONFIG_USB_F_RNDIS=y
CONFIG_USB_F_ECM=y
CONFIG_USB_F_NCM=y
CONFIG_USB_F_ACM=y
CONFIG_USB_F_MASS_STORAGE=y
CONFIG_USB_LIBCOMPOSITE=y
CONFIG_USB_U_ETHER=y
CONFIG_USB_PHY=y
CONFIG_GENERIC_PHY=y
CONFIG_USB_ROLE_SWITCH=y
CONFIG_TYPEC=y
CONFIG_POWER_SUPPLY=y
CONFIG_EXTCON=y
CONFIG_REGULATOR=y

# ---------------------------------------------------------------------------
# MTK platform buses.  The actual MT6789 glue (clocks, pinctrl, PMIC,
# charger, display, touch, UFS glue) is supplied by the stock vendor modules,
# so only the generic cores are enabled in-tree here.
# ---------------------------------------------------------------------------
CONFIG_I2C=y
CONFIG_I2C_CHARDEV=y
CONFIG_SPI=y
CONFIG_SPMI=y
CONFIG_PINCTRL=y
CONFIG_GPIOLIB=y
CONFIG_GPIO_CDEV=y
CONFIG_COMMON_CLK=y
CONFIG_REGMAP=y
CONFIG_REGMAP_MMIO=y
CONFIG_REGMAP_I2C=y
CONFIG_REGMAP_SPI=y
CONFIG_MFD_CORE=y
CONFIG_MFD_SYSCON=y
CONFIG_NVMEM=y
CONFIG_NVMEM_SYSFS=y
CONFIG_PM_DEVFREQ=y
CONFIG_DEVFREQ_GOV_SIMPLE_ONDEMAND=y
CONFIG_DEVFREQ_GOV_PERFORMANCE=y
CONFIG_DEVFREQ_GOV_POWERSAVE=y
CONFIG_DEVFREQ_GOV_USERSPACE=y
CONFIG_THERMAL=y
CONFIG_CPU_THERMAL=y
CONFIG_DEVFREQ_THERMAL=y
CONFIG_WATCHDOG=y
CONFIG_RTC_CLASS=y
CONFIG_DMA_CMA=y
CONFIG_CMA=y
CONFIG_IOMMU_SUPPORT=y
CONFIG_IOMMU_DMA=y
CONFIG_IOMMU_IO_PGTABLE_LPAE=y

# ---------------------------------------------------------------------------
# Display / input.  medatek-drm and the panel drivers are vendor modules.
# ---------------------------------------------------------------------------
CONFIG_DRM=y
CONFIG_DRM_KMS_HELPER=y
CONFIG_DRM_GEM_CMA_HELPER=y
CONFIG_DRM_GEM_SHMEM_HELPER=y
CONFIG_DRM_MIPI_DSI=y
# CONFIG_DRM_FBDEV_EMULATION is not set
CONFIG_BACKLIGHT_CLASS_DEVICE=y
CONFIG_INPUT=y
CONFIG_INPUT_EVDEV=y
CONFIG_INPUT_UINPUT=y
CONFIG_INPUT_MISC=y
CONFIG_INPUT_TOUCHSCREEN=y
CONFIG_HID=y
CONFIG_HID_GENERIC=y
CONFIG_USB_HID=y
CONFIG_HIDRAW=y

# ---------------------------------------------------------------------------
# Networking: WiFi/BT cores are upstream, MTK drivers are vendor modules
# ---------------------------------------------------------------------------
CONFIG_NET=y
CONFIG_INET=y
CONFIG_IPV6=y
CONFIG_PACKET=y
CONFIG_UNIX=y
CONFIG_NETFILTER=y
CONFIG_CFG80211=y
CONFIG_MAC80211=y
CONFIG_RFKILL=y
CONFIG_BT=y
CONFIG_BT_RFCOMM=y
CONFIG_BT_RFCOMM_TTY=y
CONFIG_BT_BNEP=y
CONFIG_BT_HIDP=y
# CONFIG_BT_HCIBTUSB is not set
# CONFIG_BT_HCIBTSDIO is not set
# CONFIG_BT_HCIUART is not set
# CONFIG_BT_HCIBCM203X is not set
# CONFIG_BT_HCIBPA10X is not set
# CONFIG_BT_HCIBFUSB is not set
# CONFIG_BT_HCIVHCI is not set
# CONFIG_BT_MRVL is not set
CONFIG_NFC=y

# ---------------------------------------------------------------------------
# Security: AppArmor is the active LSM (Droidian default), SELinux is built
# in for compatibility but disabled on the command line.  The Halium checker
# also insists on SMACK/TOMOYO being compiled in; they are not in the LSM
# order ahead of AppArmor.
# ---------------------------------------------------------------------------
CONFIG_SECURITY=y
CONFIG_SECURITYFS=y
CONFIG_SECURITY_NETWORK=y
CONFIG_SECURITY_PATH=y
CONFIG_NETLABEL=y
CONFIG_SECURITY_SELINUX=y
CONFIG_SECURITY_SELINUX_BOOTPARAM=y
CONFIG_SECURITY_SELINUX_BOOTPARAM_VALUE=0
CONFIG_SECURITY_SELINUX_DISABLE=y
CONFIG_SECURITY_SELINUX_DEVELOP=y
CONFIG_SECURITY_SELINUX_AVC_STATS=y
CONFIG_SECURITY_SELINUX_CHECKREQPROT_VALUE=1
CONFIG_SECURITY_APPARMOR=y
CONFIG_SECURITY_APPARMOR_HASH=y
CONFIG_SECURITY_APPARMOR_UNCONFINED_INIT=y
CONFIG_SECURITY_APPARMOR_BOOTPARAM_VALUE=1
CONFIG_SECURITY_YAMA=y
CONFIG_SECURITY_YAMA_STACKED=y
CONFIG_SECURITY_SMACK=y
CONFIG_SECURITY_TOMOYO=y
CONFIG_SECURITY_TOMOYO_MAX_ACCEPT_ENTRY=2048
CONFIG_SECURITY_TOMOYO_MAX_AUDIT_LOG=1024
CONFIG_SECURITY_TOMOYO_POLICY_LOADER="/sbin/tomoyo-init"
CONFIG_SECURITY_TOMOYO_ACTIVATION_TRIGGER="/sbin/init"
CONFIG_DEFAULT_SECURITY="apparmor"
CONFIG_DEFAULT_SECURITY_APPARMOR=y
# CONFIG_DEFAULT_SECURITY_SELINUX is not set
# CONFIG_DEFAULT_SECURITY_SMACK is not set
# CONFIG_DEFAULT_SECURITY_TOMOYO is not set
# CONFIG_DEFAULT_SECURITY_YAMA is not set
# CONFIG_DEFAULT_SECURITY_DAC is not set

# Integrity / keys expected by the checker and by Android's keyctl users.
CONFIG_INTEGRITY=y
CONFIG_INTEGRITY_SIGNATURE=y
CONFIG_EVM=y

# ---------------------------------------------------------------------------
# Halium checker OFF list (kept explicit so the checker never has to guess)
# ---------------------------------------------------------------------------
# CONFIG_NETPRIO_CGROUP is not set
# CONFIG_NET_CLS_CGROUP is not set
# CONFIG_FW_LOADER_USER_HELPER is not set
# CONFIG_ANDROID_LOW_MEMORY_KILLER is not set
# CONFIG_ANDROID_PARANOID_NETWORK is not set
# CONFIG_SECURITY_APPARMOR_STATS is not set
# CONFIG_SECURITY_SELINUX_POLICYDB_VERSION_MAX is not set
# CONFIG_SECURITY_TOMOYO_OMIT_USERSPACE_LOADER is not set
# CONFIG_BT_HCIBTUSB is not set
# CONFIG_BT_HCIBTSDIO is not set
# CONFIG_BT_HCIUART is not set
# CONFIG_BT_HCIBCM203X is not set
# CONFIG_BT_HCIBPA10X is not set
# CONFIG_BT_HCIBFUSB is not set
# CONFIG_BT_HCIVHCI is not set
# CONFIG_BT_MRVL is not set
# CONFIG_AF_RXRPC is not set
# CONFIG_KEYS_DEBUG_PROC_KEYS is not set
# CONFIG_XFRM_MIGRATE is not set
# CONFIG_XFRM_STATISTICS is not set
# CONFIG_XFRM_SUB_POLICY is not set
# CONFIG_COMPAT_BRK is not set
# CONFIG_DEVKMEM is not set
# CONFIG_NETFILTER_DEBUG is not set
# CONFIG_IP_SET is not set
# CONFIG_IP_VS is not set
# CONFIG_RT_GROUP_SCHED is not set
# CONFIG_ARM_UNWIND is not set
# CONFIG_VT_HW_CONSOLE_BINDING is not set
# CONFIG_FRAMEBUFFER_CONSOLE is not set
# CONFIG_SPEAKUP is not set
# CONFIG_CIFS_UPCALL is not set
# CONFIG_CIFS_DFS_UPCALL is not set
# CONFIG_KGDB is not set
X6882_FILE_05_f220ec04

log "Writing debian/check-config.sh"
cat > "${TARGET_DIR}/debian/check-config.sh" <<'X6882_FILE_06_9680d49c'
#!/usr/bin/env bash
#
# Assert the critical options in the kernel .config that olddefconfig
# produced.  The prepared defconfig has already been validated by the Halium
# checker; this is the last line of defence before the (long) compile starts.
#
#   debian/check-config.sh [path-to-.config]
set -euo pipefail

CONFIG="${1:-out/KERNEL_OBJ/.config}"

fail() {
    printf '\n\033[31mcheck-config: %s\033[0m\n' "$*" >&2
    exit 1
}

[ -f "${CONFIG}" ] || fail "config not found: ${CONFIG}"

require() {
    if ! grep -qxF -- "$1" "${CONFIG}"; then
        printf '\nMissing expected line: %s\n' "$1" >&2
        printf 'Actual: ' >&2
        grep -E "^${1%%=*}=" "${CONFIG}" >&2 || echo '(not present)' >&2
        exit 1
    fi
}

forbid() {
    if grep -qE -- "$1" "${CONFIG}"; then
        printf '\nUnexpected line matching: %s\n' "$1" >&2
        grep -nE -- "$1" "${CONFIG}" >&2 || true
        exit 1
    fi
}

# Halium / Droidian userspace
require 'CONFIG_DEVTMPFS=y'
require 'CONFIG_DEVTMPFS_MOUNT=y'
require 'CONFIG_SYSVIPC=y'
require 'CONFIG_POSIX_MQUEUE=y'
require 'CONFIG_CGROUPS=y'
require 'CONFIG_NAMESPACES=y'
require 'CONFIG_USER_NS=y'
require 'CONFIG_NET_NS=y'
require 'CONFIG_VT=y'
require 'CONFIG_VT_CONSOLE=y'
require 'CONFIG_SECURITY=y'
require 'CONFIG_SECURITY_SELINUX=y'
require 'CONFIG_SECURITY_SELINUX_DEVELOP=y'
require 'CONFIG_SECURITY_APPARMOR=y'
require 'CONFIG_DEFAULT_SECURITY_APPARMOR=y'
require 'CONFIG_ANDROID_BINDER_IPC=y'
require 'CONFIG_USB_CONFIGFS_RNDIS=y'
require 'CONFIG_SWAP=y'
require 'CONFIG_ZRAM=y'
require 'CONFIG_ZSMALLOC=y'
require 'CONFIG_ZPOOL=y'
require 'CONFIG_CFG80211=y'
require 'CONFIG_MAC80211=y'
require 'CONFIG_RD_GZIP=y'
require 'CONFIG_RD_LZ4=y'

# Storage path for the internal UFS flash
require 'CONFIG_SCSI_UFSHCD=y'
require 'CONFIG_SCSI_UFSHCD_PLATFORM=y'
require 'CONFIG_EXT4_FS=y'
require 'CONFIG_DM_CRYPT=y'

# Stock MTK vendor modules are forced in with insmod -f
require 'CONFIG_MODULE_FORCE_LOAD=y'
forbid '^CONFIG_MODVERSIONS=y'
forbid '^CONFIG_(KSU|SUSFS)[A-Za-z0-9_]*='

# The GKI reference config must not drag in a costly or non-booting setup
forbid '^CONFIG_LTO_CLANG(=|_)'
forbid '^CONFIG_CFI_CLANG=y'
forbid '^CONFIG_KASAN(=|_)'
forbid '^CONFIG_UBSAN(=|_)'
forbid '^CONFIG_DEBUG_INFO=y'

# No vendor suffix and no hard-coded boot arguments in the image itself
forbid '^CONFIG_LOCALVERSION=".+"'
forbid '^CONFIG_CMDLINE=".+"'

printf 'check-config: OK (%s)\n' "${CONFIG}"
printf '  CONFIG_LOCALVERSION=%s\n' "$(grep '^CONFIG_LOCALVERSION=' "${CONFIG}" || echo '<unset>')"
printf '  CONFIG_CMDLINE=%s\n' "$(grep '^CONFIG_CMDLINE=' "${CONFIG}" || echo '<unset>')"
printf '  %s\n' "$(grep '^CONFIG_LSM=' "${CONFIG}" || echo 'CONFIG_LSM=<unset>')"
printf '  %s\n' "$(grep '^CONFIG_DEFAULT_SECURITY' "${CONFIG}" | tr '\n' ' ' || echo 'CONFIG_DEFAULT_SECURITY=<unset>')"
X6882_FILE_06_9680d49c

log "Writing debian/copyright"
cat > "${TARGET_DIR}/debian/copyright" <<'X6882_FILE_07_ead97536'
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: kernel_common_5.10
Source: https://github.com/XTENSEI/kernel_common_5.10

Files: *
Copyright: 2020-2026 MediaTek and Linux kernel contributors
License: GPL-2.0
 This kernel is distributed under the terms of the GNU General Public
 License, version 2.  On Debian systems the complete text of this licence
 is available in /usr/share/common-licenses/GPL-2.

Files: debian/*
Copyright: 2026 X6882 Droidian porters
License: GPL-2.0+
 This packaging is free software: you can redistribute it and/or modify it
 under the terms of the GNU General Public License as published by the Free
 Software Foundation, either version 2 of the License, or (at your option)
 any later version.
X6882_FILE_07_ead97536

log "Writing debian/kernel-info.mk"
cat > "${TARGET_DIR}/debian/kernel-info.mk" <<'X6882_FILE_08_562dacf3'
# Kernel package settings for the Infinix Hot 50 4G (X6882, MediaTek MT6789).
#
# This tree is the kernel tree itself: the CI checkout of
#   https://github.com/XTENSEI/kernel_common_5.10
# is used as the Debian source package root.  The only files carried by
# the builder repository are this one, debian/rules, debian/check-config.sh,
# debian/copyright and debian/source/format, plus the prepared defconfig.

########################################################################
# Kernel version
########################################################################

# Derive the base version from the kernel Makefile so the package name
# always matches the checked-out tree (5.10.274 on android12-5.10-rebased).
KERNEL_BASE_VERSION := $(shell \
	awk '/^VERSION =/ {v=$$3} /^PATCHLEVEL =/ {p=$$3} /^SUBLEVEL =/ {s=$$3} \
		END { if (v != "" && p != "" && s != "") print v"."p"."s }' \
		$(CURDIR)/Makefile 2>/dev/null)

ifeq ($(strip $(KERNEL_BASE_VERSION)),)
KERNEL_BASE_VERSION := 5.10.274
endif

# Source package is linux-android-infinix-x6882, matching debian/changelog.
VARIANT = android

########################################################################
# Device identity
########################################################################

DEVICE_VENDOR = infinix
DEVICE_MODEL = x6882
DEVICE_FULL_NAME = Infinix Hot 50 4G (X6882)

########################################################################
# Configuration
########################################################################

# scripts/prepare_kernel_cloud.sh writes this file next to gki_defconfig.
KERNEL_DEFCONFIG = x6882_droidian_defconfig

# The prepared defconfig is self-contained; no fragment merge is needed at
# build time.
KERNEL_CONFIG_USE_FRAGMENTS = 0
KERNEL_CONFIG_USE_DIFFCONFIG = 0

########################################################################
# Boot image
########################################################################

# Exact command line for the device.  The stock boot header has an empty
# cmdline and the stock vendor_boot header carries bootopt=; both images are
# repacked by scripts/patch_vendor_boot_cloud.sh with the full line below.
KERNEL_BOOTIMAGE_CMDLINE = bootopt=64S3,32N2,64N2 console=tty0 droidian.lvm.prefer systemd.unified_cgroup_hierarchy=0 selinux=0 enforcing=0

# Header v4: GKI split boot / vendor_boot.
KERNEL_BOOTIMAGE_VERSION = 4
KERNEL_BOOTIMAGE_PAGE_SIZE = 4096

# Match the stock boot header (Android 12, December 2024 security level).
KERNEL_BOOTIMAGE_OS_VERSION = 12.0.0
KERNEL_BOOTIMAGE_PATCH_LEVEL = 2024-12

# The Halium initrd is already LZ4-legacy compressed, which is what the v4
# boot header and the MTK bootloader expect for this device.
KERNEL_INITRAMFS_COMPRESSION = lz4

# Do not let the packaging build a vendor_boot image: the MTK vendor modules
# and the DTB are not part of the GKI source tree.  The CI patch stage repacks
# the stock vendor_boot instead.
KERNEL_BOOTIMAGE_GENERATE_VENDOR_BOOT = 0

# DTB / DTBO are supplied by the stock vendor_boot; do not merge them into
# the kernel image.
KERNEL_IMAGE_WITH_DTB = 0
KERNEL_IMAGE_WITH_DTB_OVERLAY = 0

# The resulting boot.img has no AVB hash footer.  KERNEL_BOOTIMAGE_PARTITION_SIZE
# is intentionally left unset.  The patch stage pads to the 64 MiB partition.
DEVICE_VBMETA_REQUIRED = 1
DEVICE_VBMETA_IS_SAMSUNG = 0

# init_boot is only 8 MiB on this device and cannot hold the ~20 MiB Halium
# initrd.  The Droidian initrd lives in the 64 MiB boot partition instead.
DEVICE_HAS_INIT_BOOT = 0

# Never auto-flash on package upgrades: the boot image needs the vendor
# modules merged by the CI patch stage, which the plain .deb does not contain.
FLASH_ENABLED = 0
FLASH_IS_AONLY = 0
FLASH_IS_LEGACY_DEVICE = 0
FLASH_IS_EXYNOS = 0

########################################################################
# Toolchain
########################################################################

BUILD_CROSS = 1
BUILD_TRIPLET = aarch64-linux-gnu-
BUILD_CLANG_TRIPLET = aarch64-linux-gnu
BUILD_CC = clang
BUILD_LLVM = 1

# clang-android-12.0-r416183b installs here.
BUILD_PATH = /usr/lib/llvm-android-12.0-r416183b/bin

# Do not let the snippet inject clang-android-$(CLANG_VERSION) or the
# gcc-4.9 Android cross compiler.  We only need binutils, clang and lz4.
CLANG_CUSTOM = 1
DEB_TOOLCHAIN = binutils-aarch64-linux-gnu, clang-android-12.0-r416183b, lz4

DEB_BUILD_ON = amd64
DEB_BUILD_FOR = arm64

KERNEL_ARCH = arm64
KERNEL_BUILD_TARGET = Image.gz
X6882_FILE_08_562dacf3

log "Writing debian/rules"
cat > "${TARGET_DIR}/debian/rules" <<'X6882_FILE_09_ddf587e7'
#!/usr/bin/make -f
#
# Debian packaging rules for the X6882 Droidian kernel.
#
# The kernel tree is the source package root.  linux-packaging-snippets
# provides kernel-snippet.mk, which builds the kernel, the modules, the
# Halium initrd based boot.img and the disabled vbmeta image.

include $(CURDIR)/debian/kernel-info.mk
include /usr/share/linux-packaging-snippets/kernel-snippet.mk

%:
	dh $@

# Generate debian/control.  Unlike the GKI reference rules we do NOT rename
# the source package with @KERNEL_BASE_VERSION@, because debian/changelog uses
# linux-android-infinix-x6882 as the source name.
debian/control:
	rm -f $(CURDIR)/debian/control
	sed -e "s|@KERNEL_BASE_VERSION@|$(KERNEL_BASE_VERSION)|g" \
		-e "s|@VARIANT@|$(VARIANT)|g" \
		-e "s|@DEVICE_VENDOR@|$(DEVICE_VENDOR)|g" \
		-e "s|@DEVICE_MODEL@|$(DEVICE_MODEL)|g" \
		-e "s|@DEVICE_FULL_NAME@|$(DEVICE_FULL_NAME)|g" \
		-e "s|@DEB_TOOLCHAIN@|$(DEB_TOOLCHAIN)|g" \
		-e "s|@DEB_BUILD_ON@|$(DEB_BUILD_ON)|g" \
		-e "s|@DEB_BUILD_FOR@|$(DEB_BUILD_FOR)|g" \
		/usr/share/linux-packaging-snippets/control.in > $(CURDIR)/debian/control
	# The initramfs package is an arm64 package; the build itself runs on
	# amd64.  Multi-Arch: same makes the qualified dependency installable.
	sed -i 's|linux-initramfs-halium-generic,|linux-initramfs-halium-generic:arm64,|' \
		$(CURDIR)/debian/control
	grep -n 'linux-initramfs-halium-generic' $(CURDIR)/debian/control

# Verify the resolved .config before compiling anything.  The prepared
# defconfig was already checked by the Halium checker, but olddefconfig can
# drop symbols and silently change values.
out/check-config.stamp: out/KERNEL_OBJ/.config debian/check-config.sh
	bash $(CURDIR)/debian/check-config.sh $(CURDIR)/out/KERNEL_OBJ/.config
	touch $@

# The snippet's override_dh_auto_configure has an empty recipe; adding a
# prerequisite here runs the config check after .config has been generated
# and before dh_auto_build starts compiling.
override_dh_auto_configure: out/check-config.stamp
X6882_FILE_09_ddf587e7

log "Writing debian/source/format"
cat > "${TARGET_DIR}/debian/source/format" <<'X6882_FILE_10_e8e18df4'
3.0 (native)
X6882_FILE_10_e8e18df4

log "Writing scripts/build_deb_in_container.sh"
cat > "${TARGET_DIR}/scripts/build_deb_in_container.sh" <<'X6882_FILE_11_5216400a'
#!/usr/bin/env bash
#
# Build the X6882 Droidian kernel packages inside the official Droidian
# build container:
#
#   quay.io/droidian/build-essential:trixie-amd64
#
# The kernel checkout is the Debian source package root.  It must already
# contain:
#
#   arch/arm64/configs/x6882_droidian_defconfig   (prepared defconfig)
#   debian/kernel-info.mk
#   debian/rules
#   debian/check-config.sh
#   debian/copyright
#   debian/source/format
#
# Environment:
#   KERNEL_SRC   kernel checkout        (default: /build/linux-android-infinix-x6882)
#   ARTIFACTS    output directory       (default: /artifacts)
#   JOBS         compile parallelism    (default: nproc)
#   SKIP_APT     set to 1 to skip the apt install step (for debugging)
#
# Produces in ${ARTIFACTS}:
#   debs/*.deb, debs/*.changes, debs/*.buildinfo
#   boot-droidian-base.img   the Halium initrd boot.img built by the snippets
#   vbmeta-disabled.img      avbtool vbmeta with the hashtree disabled
#   Image.gz                 the compressed arm64 kernel
#   config-<release>         the resolved .config
#   System.map-<release>
#   manifest.txt, SHA256SUMS
#
set -euo pipefail

KERNEL_SRC="${KERNEL_SRC:-/build/linux-android-infinix-x6882}"
ARTIFACTS="${ARTIFACTS:-/artifacts}"
JOBS="${JOBS:-$(nproc)}"
SKIP_APT="${SKIP_APT:-0}"

STAGING_REPO_LINE='deb [arch=amd64,arm64 signed-by=/etc/apt/trusted.gpg.d/droidian.gpg] https://staging.repo.droidian.org/ trixie main'
DROIDIAN_KEY='/etc/apt/trusted.gpg.d/droidian.gpg'

log()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
fail() { printf '\n\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "this script must run as root inside the build container"
[ -d "${KERNEL_SRC}" ] || fail "kernel tree not found: ${KERNEL_SRC}"
[ -f "${KERNEL_SRC}/Makefile" ] || fail "not a kernel tree (no Makefile): ${KERNEL_SRC}"
[ -f "${KERNEL_SRC}/arch/arm64/configs/x6882_droidian_defconfig" ] || \
    fail "prepared defconfig missing in ${KERNEL_SRC}"
[ -f "${KERNEL_SRC}/debian/rules" ] || fail "debian/rules missing in ${KERNEL_SRC}"
[ -f "${KERNEL_SRC}/debian/kernel-info.mk" ] || fail "debian/kernel-info.mk missing in ${KERNEL_SRC}"
[ -f "${KERNEL_SRC}/debian/source/format" ] || fail "debian/source/format missing in ${KERNEL_SRC}"

KERNEL_VERSION="$(awk '/^VERSION =/ {v=$3} /^PATCHLEVEL =/ {p=$3} /^SUBLEVEL =/ {s=$3} END { if (v != "" && p != "" && s != "") print v"."p"."s }' "${KERNEL_SRC}/Makefile")"
[ -n "${KERNEL_VERSION}" ] || fail "could not determine the kernel version from ${KERNEL_SRC}/Makefile"
KERNEL_RELEASE="${KERNEL_VERSION}-infinix-x6882"

log "Kernel ${KERNEL_VERSION} (package release ${KERNEL_RELEASE}), ${JOBS} jobs"

if [ "${SKIP_APT}" != "1" ]; then
    log "Configuring the Droidian repositories"

    if [ ! -e "${DROIDIAN_KEY}" ]; then
        fail "Droidian archive key not found at ${DROIDIAN_KEY}"
    fi
    printf '%s\n' "${STAGING_REPO_LINE}" \
        > /etc/apt/sources.list.d/droidian-staging.list

    # arm64 is needed for linux-initramfs-halium-generic:arm64.  The call is
    # idempotent: dpkg prints a warning if the architecture already exists.
    dpkg --add-architecture arm64

    # Some container revisions ship a stale bootstrap keyring; make sure the
    # keyring used by signed-by is readable before apt tries to use it.
    if [ -L "${DROIDIAN_KEY}" ]; then
        KEY_TARGET="$(readlink -f "${DROIDIAN_KEY}")"
        [ -r "${KEY_TARGET}" ] || fail "Droidian key symlink target is not readable: ${KEY_TARGET}"
        log "Droidian key: ${DROIDIAN_KEY} -> ${KEY_TARGET}"
    fi

    log "Refreshing APT metadata"
    apt-get update -o Acquire::Retries=5

    log "Installing packaging snippets and the arm64 Halium initramfs"
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        --no-install-recommends \
        -o Acquire::Retries=5 \
        -o Dpkg::Options::=--force-confnew \
        linux-packaging-snippets \
        linux-initramfs-halium-generic:arm64 \
        lz4 \
        cpio \
        kmod

    [ -f /usr/share/linux-packaging-snippets/kernel-snippet.mk ] || \
        fail "linux-packaging-snippets did not install kernel-snippet.mk"
    [ -f /usr/lib/aarch64-linux-gnu/halium-generic-initramfs/initrd.img-halium-generic.lz4 ] || \
        fail "the arm64 Halium LZ4 initramfs is missing (linux-initramfs-halium-generic:arm64)"
else
    log "SKIP_APT=1: using the packages already present in the container"
fi

cd "${KERNEL_SRC}"

log "Preparing the git branch and committing the packaging files"
git config --global --add safe.directory "${KERNEL_SRC}" || true
git config user.name "X6882 Droidian CI" || true
git config user.email "ci@x6882.invalid" || true

# A local feature branch makes releng-build-package use BUILD_TYPE=feature-branch
# (and therefore the "next"/trixie rolling release path).
git checkout -B feature/x6882

# Never commit a generated control file or stale build leftovers.
rm -f debian/control
rm -rf out debian/path-override

git add -A debian arch/arm64/configs/x6882_droidian_defconfig
git commit --allow-empty -m "x6882: Droidian packaging for kernel ${KERNEL_VERSION}"

# releng-build-package regenerates this file; it must exist and be committed
# so that "git checkout -- debian/changelog" restores a valid starting version.
cat > debian/changelog <<EOF
linux-android-infinix-x6882 (${KERNEL_VERSION}) unstable; urgency=medium

  * Automated Droidian kernel build for the Infinix Hot 50 4G (X6882).

 -- X6882 Droidian porters <info@droidian.org>  $(date -R)
EOF

git add debian/changelog
git commit --allow-empty -m "x6882: changelog for kernel ${KERNEL_VERSION}"

log "Generating debian/control"
rm -f debian/control
debian/rules debian/control

grep -q '^Source: linux-android-infinix-x6882$' debian/control || \
    fail "debian/control does not name the expected source package"
grep -q 'linux-initramfs-halium-generic:arm64' debian/control || \
    fail "debian/control does not carry the arm64 initramfs build dependency"

printf '\n----- debian/control (head) -----\n'
sed -n '1,30p' debian/control

log "Building the packages with releng-build-package"
export CI=true
export IS_CONTAINER=true
export RELENG_HOST_ARCH=arm64
export DEB_BUILD_OPTIONS="parallel=${JOBS}"
export DEBIAN_FRONTEND=noninteractive

releng-build-package

log "Collecting build results"
shopt -s nullglob
changes=(/build/*.changes)
debs=(/build/*.deb)
buildinfo=(/build/*.buildinfo)

[ "${#debs[@]}" -gt 0 ] || fail "no .deb files were produced in /build"
[ "${#changes[@]}" -gt 0 ] || fail "no .changes file was produced in /build"

mkdir -p "${ARTIFACTS}/debs"
cp -v "${debs[@]}" "${ARTIFACTS}/debs/"
if [ "${#changes[@]}" -gt 0 ]; then
    cp -v "${changes[@]}" "${ARTIFACTS}/debs/"
fi
if [ "${#buildinfo[@]}" -gt 0 ]; then
    cp -v "${buildinfo[@]}" "${ARTIFACTS}/debs/"
fi

log "Extracting boot.img, vbmeta.img, Image.gz and config"
EXTRACT="$(mktemp -d)"
trap 'rm -rf "${EXTRACT}"' EXIT

for deb in "${debs[@]}"; do
    dpkg-deb -x "${deb}" "${EXTRACT}"
done

first_match() {
    find "$1" -maxdepth 2 -name "$2" -type f -print -quit 2>/dev/null || true
}

BOOT_IMG="$(first_match "${EXTRACT}/boot" 'boot.img-*')"
[ -n "${BOOT_IMG}" ] || fail "boot.img-* not found in the built packages"
cp -v "${BOOT_IMG}" "${ARTIFACTS}/boot-droidian-base.img"

VBMETA_IMG="$(first_match "${EXTRACT}/boot" 'vbmeta.img-*')"
[ -n "${VBMETA_IMG}" ] || fail "vbmeta.img-* not found in the built packages"
cp -v "${VBMETA_IMG}" "${ARTIFACTS}/vbmeta-disabled.img"

IMAGE_GZ="$(first_match "${EXTRACT}/boot" 'Image.gz-*')"
[ -n "${IMAGE_GZ}" ] || fail "Image.gz-* not found in the built packages"
cp -v "${IMAGE_GZ}" "${ARTIFACTS}/Image.gz"

SYSTEM_MAP="$(first_match "${EXTRACT}/boot" 'System.map-*')"
if [ -n "${SYSTEM_MAP}" ]; then
    cp -v "${SYSTEM_MAP}" "${ARTIFACTS}/System.map-${KERNEL_RELEASE}"
fi

KCONFIG="$(first_match "${EXTRACT}/boot" 'config-*')"
if [ -n "${KCONFIG}" ]; then
    cp -v "${KCONFIG}" "${ARTIFACTS}/config-${KERNEL_RELEASE}"
fi

# A plain boot.img copy is handy for manual comparisons and for the docs.
cp -v "${ARTIFACTS}/boot-droidian-base.img" "${ARTIFACTS}/boot.img"

{
    printf 'kernel_version=%s\n' "${KERNEL_VERSION}"
    printf 'kernel_release=%s\n' "${KERNEL_RELEASE}"
    printf 'kernel_defconfig=%s\n' "x6882_droidian_defconfig"
    printf 'built_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'built_by=%s\n' "scripts/build_deb_in_container.sh"
    printf 'debs=%s\n' "$(cd "${ARTIFACTS}/debs" && printf '%s ' *.deb)"
    if [ -f "${ARTIFACTS}/Image.gz" ]; then
        printf 'image_gz_sha256=%s\n' "$(sha256sum "${ARTIFACTS}/Image.gz" | awk '{print $1}')"
    fi
    if [ -f "${ARTIFACTS}/boot-droidian-base.img" ]; then
        printf 'boot_img_sha256=%s\n' "$(sha256sum "${ARTIFACTS}/boot-droidian-base.img" | awk '{print $1}')"
    fi
    if [ -f "${ARTIFACTS}/vbmeta-disabled.img" ]; then
        printf 'vbmeta_sha256=%s\n' "$(sha256sum "${ARTIFACTS}/vbmeta-disabled.img" | awk '{print $1}')"
    fi
} > "${ARTIFACTS}/manifest.txt"

(
    cd "${ARTIFACTS}"
    find . -maxdepth 2 -type f ! -name SHA256SUMS -print0 \
        | sort -z \
        | xargs -0 sha256sum > SHA256SUMS
)

log "Done"
ls -l "${ARTIFACTS}"
printf '\n'
cat "${ARTIFACTS}/SHA256SUMS"
X6882_FILE_11_5216400a

log "Writing scripts/patch_vendor_boot_cloud.sh"
cat > "${TARGET_DIR}/scripts/patch_vendor_boot_cloud.sh" <<'X6882_FILE_12_d509dd46'
#!/usr/bin/env bash
#
# Merge the stock MTK vendor modules into the Droidian/Halium initrd and
# produce flashable boot.img / vendor_boot.img images for the Infinix Hot 50
# 4G (X6882, MT6789).
#
#   scripts/patch_vendor_boot_cloud.sh \
#       --magiskboot  tools/magiskboot \
#       --droidian-boot out/boot-droidian-base.img \
#       --vendor-boot  out/vendor_boot.img \
#       --image        out/Image.gz \
#       --outdir       out/patched
#
# The two stock images (boot.img and vendor_boot.img) come from the
# "dump-assets" GitHub release; they are never stored in git.
#
# What this does, and why:
#
#   * stock vendor_boot.img carries 210 MTK kernel modules in its vendor
#     ramdisk, plus the device DTB and the bootopt=... vendor cmdline;
#   * the Droidian boot.img carries the Halium initrd but no MTK modules;
#   * the vendor ramdisk is replaced with an empty cpio so Android's broken
#     /init -> /system/bin/ini symlink can not shadow Droidian's /init;
#   * the Halium initrd is unpacked with GNU cpio (preserving the 215-way
#     busybox hardlink group), the modules are added, /sbin/insmod is
#     replaced by a symlink to /bin/kmod, and scripts/halium is patched to
#     use "insmod -f" instead of "modprobe -a";
#   * /override/modules.load is generated in dependency order;
#   * both boot headers get the full Droidian cmdline;
#   * boot-droidian.img is padded to the 64 MiB boot partition.
#
# Note: magiskboot's cpio implementation destroys hardlinks, so the initrd is
# unpacked/repacked with GNU cpio and only repacked with magiskboot.
#
set -euo pipefail

MAGISKBOOT=""
DROIDIAN_BOOT=""
VENDOR_BOOT=""
IMAGE=""
OUTDIR=""
WORKDIR=""
KEEP_WORK=0
NO_VENDOR_MODULES=0

# Exact boot arguments for Droidian on this device.
CMDLINE="bootopt=64S3,32N2,64N2 console=tty0 droidian.lvm.prefer systemd.unified_cgroup_hierarchy=0 selinux=0 enforcing=0"

BOOT_PARTITION_SIZE=67108864   # 64 MiB, boot_a/boot_b
VENDOR_BOOT_SIZE=67108864      # 64 MiB, vendor_boot_a/vendor_boot_b

# Debug-only modules that are safe to drop.  Everything with a reverse
# dependency (aee_aed, mrdump, log_store, ...) must stay: UFS and display
# modules need their exported symbols.
#
# cfg80211/mac80211 are built into the Droidian kernel, so the stock copies
# are both redundant and incompatible.
SKIP_MODULES="mkp.ko aee_hangdet.ko aee_rs.ko dbgtop-drm.ko mtk_printk_ctrl.ko pidmap.ko cfg80211.ko mac80211.ko"

usage() {
    sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    cat >&2 <<'EOF'

Options:
  --magiskboot PATH       x86_64 magiskboot binary (required)
  --droidian-boot PATH    boot.img built by the Droidian kernel package (required)
  --vendor-boot PATH      stock vendor_boot.img from the dump-assets release (required)
  --image PATH            Image.gz produced by the kernel build (required)
  --outdir PATH           where to write the images (required)
  --workdir PATH          scratch directory (default: mktemp -d)
  --cmdline STRING        boot arguments (default: the X6882 Droidian line)
  --no-vendor-modules     do not merge the stock vendor modules
  --keep-work             keep the scratch directory
EOF
}

log()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
warn() { printf '\033[33mWARNING: %s\033[0m\n' "$*" >&2; }
fail() { printf '\n\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

need_value() {
    [ "$#" -ge 2 ] || fail "missing value for $1"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --magiskboot)      need_value "$@"; MAGISKBOOT="$2"; shift 2 ;;
        --droidian-boot)   need_value "$@"; DROIDIAN_BOOT="$2"; shift 2 ;;
        --vendor-boot)     need_value "$@"; VENDOR_BOOT="$2"; shift 2 ;;
        --image)           need_value "$@"; IMAGE="$2"; shift 2 ;;
        --outdir)          need_value "$@"; OUTDIR="$2"; shift 2 ;;
        --workdir)         need_value "$@"; WORKDIR="$2"; shift 2 ;;
        --cmdline)         need_value "$@"; CMDLINE="$2"; shift 2 ;;
        --no-vendor-modules) NO_VENDOR_MODULES=1; shift ;;
        --keep-work)       KEEP_WORK=1; shift ;;
        -h|--help)         usage; exit 0 ;;
        *) fail "unknown argument: $1" ;;
    esac
done

[ -n "${MAGISKBOOT}" ]    || { usage; fail "--magiskboot is required"; }
[ -n "${DROIDIAN_BOOT}" ] || { usage; fail "--droidian-boot is required"; }
[ -n "${VENDOR_BOOT}" ]   || { usage; fail "--vendor-boot is required"; }
[ -n "${IMAGE}" ]         || { usage; fail "--image is required"; }
[ -n "${OUTDIR}" ]        || { usage; fail "--outdir is required"; }

for tool in python3 cpio truncate sha256sum; do
    command -v "${tool}" >/dev/null || fail "${tool} is required"
done

MAGISKBOOT="$(readlink -f "${MAGISKBOOT}")"
DROIDIAN_BOOT="$(readlink -f "${DROIDIAN_BOOT}")"
VENDOR_BOOT="$(readlink -f "${VENDOR_BOOT}")"
IMAGE="$(readlink -f "${IMAGE}")"
mkdir -p "${OUTDIR}"
OUTDIR="$(readlink -f "${OUTDIR}")"

[ -f "${MAGISKBOOT}" ]    || fail "magiskboot not found: ${MAGISKBOOT}"
[ -f "${DROIDIAN_BOOT}" ] || fail "Droidian boot image not found: ${DROIDIAN_BOOT}"
[ -f "${VENDOR_BOOT}" ]   || fail "stock vendor_boot image not found: ${VENDOR_BOOT}"
[ -f "${IMAGE}" ]         || fail "Image.gz not found: ${IMAGE}"

# The verification and the manifest refer to ${OUTDIR}/Image.gz.  Keep a copy
# there so the output directory is self-contained.
if [ "${IMAGE}" != "${OUTDIR}/Image.gz" ]; then
    cp -f "${IMAGE}" "${OUTDIR}/Image.gz"
fi
IMAGE="${OUTDIR}/Image.gz"

# The APK stores libmagiskboot.so with mode 0644.
chmod +x "${MAGISKBOOT}"

if [ -z "${WORKDIR}" ]; then
    WORKDIR="$(mktemp -d)"
    CLEAN_WORK=1
else
    mkdir -p "${WORKDIR}"
    CLEAN_WORK=0
fi
WORKDIR="$(readlink -f "${WORKDIR}")"

cleanup() {
    if [ "${KEEP_WORK}" -eq 0 ] && [ "${CLEAN_WORK}" -eq 1 ]; then
        rm -rf "${WORKDIR}"
    fi
}
trap cleanup EXIT

log "Work directory: ${WORKDIR}"
log "magiskboot:     ${MAGISKBOOT}"

########################################################################
# 1. Unpack the stock vendor_boot.img
########################################################################
log "Unpacking stock vendor_boot ($(stat -c%s "${VENDOR_BOOT}") bytes)"
mkdir -p "${WORKDIR}/vendor"
(
    cd "${WORKDIR}/vendor"
    "${MAGISKBOOT}" unpack -h "${VENDOR_BOOT}"
)

[ -f "${WORKDIR}/vendor/header" ] || fail "magiskboot did not produce a vendor header"
[ -f "${WORKDIR}/vendor/dtb" ]    || fail "magiskboot did not extract the vendor DTB"

VENDOR_RAMDISK=""
for candidate in \
    "${WORKDIR}/vendor/vendor_ramdisk/ramdisk.cpio" \
    "${WORKDIR}/vendor/ramdisk.cpio"
do
    if [ -f "${candidate}" ]; then
        VENDOR_RAMDISK="${candidate}"
        break
    fi
done
[ -n "${VENDOR_RAMDISK}" ] || fail "could not find the unpacked vendor ramdisk"

VENDOR_MODDIR="${WORKDIR}/vendor_modules"
mkdir -p "${VENDOR_MODDIR}"
(
    cd "${VENDOR_MODDIR}"
    cpio -idm --quiet --no-preserve-owner < "${VENDOR_RAMDISK}"
) || fail "failed to extract the stock vendor ramdisk"

[ -d "${VENDOR_MODDIR}/lib/modules" ] || fail "the stock vendor ramdisk has no /lib/modules"
COMPILED_MODULES="$(find "${VENDOR_MODDIR}/lib/modules" -maxdepth 1 -name '*.ko' | wc -l)"
log "Stock vendor modules: ${COMPILED_MODULES}"

########################################################################
# 2. Unpack the Droidian boot image and its Halium initrd
########################################################################
log "Unpacking the Droidian boot image"
mkdir -p "${WORKDIR}/boot"
(
    cd "${WORKDIR}/boot"
    "${MAGISKBOOT}" unpack -h "${DROIDIAN_BOOT}"
)

[ -f "${WORKDIR}/boot/header" ]      || fail "magiskboot did not produce a boot header"
[ -f "${WORKDIR}/boot/ramdisk.cpio" ] || fail "magiskboot did not extract the boot ramdisk"

log "Extracting the Halium initrd with GNU cpio (hardlink safe)"
mkdir -p "${WORKDIR}/boot_root"
(
    cd "${WORKDIR}/boot_root"
    cpio -idm --quiet --no-preserve-owner < "${WORKDIR}/boot/ramdisk.cpio"
) || fail "failed to extract the Halium initrd"

[ -f "${WORKDIR}/boot_root/init" ]        || fail "the Halium initrd has no /init"
[ -f "${WORKDIR}/boot_root/scripts/halium" ] || fail "the Halium initrd has no scripts/halium"

########################################################################
# 3. Generate the ordered /override/modules.load
########################################################################
log "Generating the dependency-ordered module list"
MODULE_LIST="${WORKDIR}/modules.load.ordered"
python3 - "${VENDOR_MODDIR}/lib/modules" "${MODULE_LIST}" "${SKIP_MODULES}" <<'PY'
import os
import sys

moddir, out_path, skip_arg = sys.argv[1], sys.argv[2], sys.argv[3]
skip = set(skip_arg.split())

def basename(path):
    return os.path.basename(path.strip())

available = {name for name in os.listdir(moddir) if name.endswith(".ko")}
deps = {}
softdeps = {}

dep_file = os.path.join(moddir, "modules.dep")
if os.path.exists(dep_file):
    with open(dep_file, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line or ":" not in line:
                continue
            module, _, rest = line.partition(":")
            deps[basename(module)] = [basename(dep) for dep in rest.split()]

softdep_file = os.path.join(moddir, "modules.softdep")
if os.path.exists(softdep_file):
    with open(softdep_file, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            parts = line.split()
            if len(parts) < 2 or parts[0] != "softdep":
                continue
            module = basename(parts[1])
            for token in parts[2:]:
                if token.startswith("pre:"):
                    softdeps.setdefault(module, []).append(basename(token[4:]))

load_file = os.path.join(moddir, "modules.load")
if os.path.exists(load_file):
    with open(load_file, encoding="utf-8", errors="replace") as fh:
        load_order = [
            line.split()[0]
            for line in fh
            if line.strip() and not line.lstrip().startswith("#")
        ]
else:
    load_order = sorted(available)

usable = available - skip
ordered = []
state = {}
missing_deps = set()

def visit(module, stack):
    status = state.get(module)
    if status == "done":
        return
    if status == "active":
        # A dependency cycle: leave the current order, insmod will report it.
        return
    state[module] = "active"
    for dep in deps.get(module, []) + softdeps.get(module, []):
        if dep in skip or dep not in usable:
            if dep not in skip and dep not in available:
                missing_deps.add((module, dep))
            continue
        visit(dep, stack + [module])
    state[module] = "done"
    if module not in skip and module in usable:
        ordered.append(module)

for module in load_order:
    module = basename(module)
    if module in skip:
        continue
    if module not in available:
        missing_deps.add(("<modules.load>", module))
        continue
    visit(module, [])

with open(out_path, "w", encoding="utf-8") as fh:
    fh.write("\n".join(ordered))
    fh.write("\n")

print(f"modules available: {len(available)}")
print(f"modules skipped:   {len(available & skip)} ({', '.join(sorted(available & skip))})")
print(f"modules listed:    {len(ordered)}")
if missing_deps:
    print("WARNING: unresolved dependencies:")
    for module, dep in sorted(missing_deps):
        print(f"  {module} -> {dep}")
PY

MODULE_COUNT="$(wc -l < "${MODULE_LIST}")"
[ "${MODULE_COUNT}" -gt 0 ] || fail "the generated module list is empty"
log "modules.load entries: ${MODULE_COUNT}"

########################################################################
# 4. Merge modules into the Halium initrd
########################################################################
if [ "${NO_VENDOR_MODULES}" -eq 0 ]; then
    log "Copying stock vendor modules into /lib/modules"
    mkdir -p "${WORKDIR}/boot_root/lib/modules"

    copied=0
    while IFS= read -r module; do
        [ -f "${VENDOR_MODDIR}/lib/modules/${module}" ] || \
            fail "module listed but missing on disk: ${module}"
        cp -a "${VENDOR_MODDIR}/lib/modules/${module}" "${WORKDIR}/boot_root/lib/modules/"
        copied=$((copied + 1))
    done < "${MODULE_LIST}"
    log "Copied ${copied} modules"

    mkdir -p "${WORKDIR}/boot_root/override"
    cp "${MODULE_LIST}" "${WORKDIR}/boot_root/override/modules.load"
    chmod 0644 "${WORKDIR}/boot_root/override/modules.load"

    # modprobe metadata for later use by the initramfs (informational; the
    # main path is explicit insmod of the ordered list).
    for meta in modules.dep modules.alias modules.softdep modules.order modules.builtin; do
        if [ -f "${VENDOR_MODDIR}/lib/modules/${meta}" ]; then
            cp -a "${VENDOR_MODDIR}/lib/modules/${meta}" "${WORKDIR}/boot_root/lib/modules/"
        fi
    done
else
    log "Skipping the stock vendor modules (--no-vendor-modules)"
    MODULE_COUNT=0
fi

########################################################################
# 5. Patch the Halium module loader and /sbin/insmod
########################################################################
HALIUM_SCRIPT="${WORKDIR}/boot_root/scripts/halium"
if [ "${NO_VENDOR_MODULES}" -eq 0 ]; then
    log "Patching scripts/halium to force-load modules"
    python3 - "${HALIUM_SCRIPT}" <<'PY'
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8", errors="replace") as fh:
    text = fh.read()

if 'insmod -f "$1"' not in text:
    updated = text.replace('modprobe -a "$1"', 'insmod -f "$1"')
    if updated == text:
        raise SystemExit(
            "scripts/halium: could not find 'modprobe -a \"$1\"'; "
            "the Halium initramfs layout changed"
        )
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(updated)
    print("patched: modprobe -a -> insmod -f")
else:
    print("scripts/halium already patched")
PY

    log "Replacing /sbin/insmod with a symlink to /bin/kmod"
    rm -f "${WORKDIR}/boot_root/sbin/insmod"
    ln -s /bin/kmod "${WORKDIR}/boot_root/sbin/insmod"

    # Sanity check: /bin/kmod must exist for the symlink to be useful.
    [ -f "${WORKDIR}/boot_root/bin/kmod" ] || \
        fail "/bin/kmod is missing from the Halium initrd"
fi

########################################################################
# 6. Set the cmdline in both headers
########################################################################
set_cmdline() {
    local header="$1"
    python3 - "${header}" "${CMDLINE}" <<'PY'
import sys

path, cmdline = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8", errors="replace") as fh:
    lines = fh.read().splitlines()

lines = [line for line in lines if not line.startswith("cmdline=")]
lines.append("cmdline=" + cmdline)

with open(path, "w", encoding="utf-8", newline="\n") as fh:
    fh.write("\n".join(lines) + "\n")
PY
}

log "Setting cmdline: ${CMDLINE}"
set_cmdline "${WORKDIR}/boot/header"
set_cmdline "${WORKDIR}/vendor/header"

########################################################################
# 7. Repack the boot image
########################################################################
log "Repacking the initrd with GNU cpio"
(
    cd "${WORKDIR}/boot_root"
    find . | cpio -o -H newc -R 0:0 --quiet > "${WORKDIR}/boot/ramdisk.cpio"
)
NEW_INITRD_SIZE="$(stat -c%s "${WORKDIR}/boot/ramdisk.cpio")"
log "New uncompressed initrd: ${NEW_INITRD_SIZE} bytes"

# Replace the kernel with the freshly compiled Image.gz.  magiskboot stores
# the kernel bytes verbatim, so this is a byte-identical copy.
log "Installing Image.gz as the boot kernel"
cp "${IMAGE}" "${WORKDIR}/boot/kernel"

log "Repacking boot-droidian.img"
(
    cd "${WORKDIR}/boot"
    PATCHVBMETAFLAG=true "${MAGISKBOOT}" repack "${DROIDIAN_BOOT}" "${OUTDIR}/boot-droidian.img"
)

BOOT_SIZE="$(stat -c%s "${OUTDIR}/boot-droidian.img")"
if [ "${BOOT_SIZE}" -gt "${BOOT_PARTITION_SIZE}" ]; then
    fail "boot-droidian.img is ${BOOT_SIZE} bytes, larger than the 64 MiB boot partition"
fi
# Clear any stale AVB tail and make the image exactly partition-sized.
truncate -s "${BOOT_PARTITION_SIZE}" "${OUTDIR}/boot-droidian.img"
log "boot-droidian.img: ${BOOT_SIZE} -> $(stat -c%s "${OUTDIR}/boot-droidian.img") bytes"

########################################################################
# 8. Replace the vendor ramdisk with an empty cpio and repack
########################################################################
log "Building a minimal vendor ramdisk"
mkdir -p "${WORKDIR}/vendor_min"
(
    cd "${WORKDIR}/vendor_min"
    find . | cpio -o -H newc -R 0:0 --quiet > "${WORKDIR}/vendor/vendor_ramdisk/ramdisk.cpio"
)

if [ -f "${WORKDIR}/vendor/kernel" ]; then
    # A vendor_boot image normally has no kernel; remove any stale copy so
    # magiskboot does not accidentally embed one.
    rm -f "${WORKDIR}/vendor/kernel"
fi

log "Repacking vendor_boot-droidian.img"
(
    cd "${WORKDIR}/vendor"
    PATCHVBMETAFLAG=true "${MAGISKBOOT}" repack "${VENDOR_BOOT}" "${OUTDIR}/vendor_boot-droidian.img"
)

VENDOR_SIZE="$(stat -c%s "${OUTDIR}/vendor_boot-droidian.img")"
if [ "${VENDOR_SIZE}" -gt "${VENDOR_BOOT_SIZE}" ]; then
    fail "vendor_boot-droidian.img is ${VENDOR_SIZE} bytes, larger than the 64 MiB partition"
fi
log "vendor_boot-droidian.img: ${VENDOR_SIZE} bytes"

########################################################################
# 9. Verify the results
########################################################################
log "Verifying the repacked images"
mkdir -p "${WORKDIR}/verify_boot" "${WORKDIR}/verify_vendor" "${WORKDIR}/verify_raw"
(
    cd "${WORKDIR}/verify_boot"
    "${MAGISKBOOT}" unpack -h "${OUTDIR}/boot-droidian.img"
)
(
    cd "${WORKDIR}/verify_vendor"
    "${MAGISKBOOT}" unpack -h "${OUTDIR}/vendor_boot-droidian.img"
)
# -n keeps the kernel compressed, so the stored bytes can be compared with
# the exact Image.gz that was installed.
(
    cd "${WORKDIR}/verify_raw"
    "${MAGISKBOOT}" unpack -n -h "${OUTDIR}/boot-droidian.img"
)

python3 - "${WORKDIR}" "${OUTDIR}" "${CMDLINE}" "${MODULE_COUNT}" <<'PY'
import os
import sys

work, outdir, cmdline, module_count = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])

def read_header(path):
    props = {}
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if "=" in line:
                key, _, value = line.partition("=")
                props[key] = value
    return props

def parse_newc(path):
    with open(path, "rb") as fh:
        data = fh.read()
    entries = []
    pos = 0
    while pos + 110 <= len(data):
        if data[pos:pos + 6] not in (b"070701", b"070702"):
            break
        mode = int(data[pos + 14:pos + 22], 16)
        fsize = int(data[pos + 54:pos + 62], 16)
        nsize = int(data[pos + 94:pos + 102], 16)
        name = data[pos + 110:pos + 110 + nsize - 1].decode("utf-8", "replace")
        data_off = pos + 110 + nsize
        data_off = (data_off + 3) & ~3
        body = data[data_off:data_off + fsize]
        if name == "TRAILER!!!":
            break
        entries.append((name, mode, body))
        pos = data_off + fsize
        pos = (pos + 3) & ~3
    return entries

errors = []

boot_header = read_header(os.path.join(work, "verify_boot", "header"))
if boot_header.get("cmdline") != cmdline:
    errors.append("boot cmdline mismatch: %r" % boot_header.get("cmdline"))

vendor_header = read_header(os.path.join(work, "verify_vendor", "header"))
if vendor_header.get("cmdline") != cmdline:
    errors.append("vendor cmdline mismatch: %r" % vendor_header.get("cmdline"))

with open(os.path.join(work, "verify_raw", "kernel"), "rb") as fh:
    boot_kernel = fh.read()
with open(os.path.join(outdir, "Image.gz"), "rb") as fh:
    expected_kernel = fh.read()
if boot_kernel != expected_kernel:
    errors.append("the stored boot kernel does not match Image.gz")

def normalize(name):
    while name.startswith("./"):
        name = name[2:]
    return name

boot_entries = {
    normalize(name): (mode, body)
    for name, mode, body in parse_newc(os.path.join(work, "verify_boot", "ramdisk.cpio"))
}

if "init" not in boot_entries:
    errors.append("the repacked boot ramdisk has no /init")
if "bin/kmod" not in boot_entries:
    errors.append("the repacked boot ramdisk has no /bin/kmod")

if module_count:
    if "override/modules.load" not in boot_entries:
        errors.append("override/modules.load is missing from the boot ramdisk")
    else:
        listed = boot_entries["override/modules.load"][1].decode().split()
        ko = [name for name in boot_entries if name.endswith(".ko")]
        if len(listed) != module_count:
            errors.append("override/modules.load has %d entries, expected %d" % (len(listed), module_count))
        if len(ko) < module_count:
            errors.append("only %d .ko files in the initrd, expected at least %d" % (len(ko), module_count))
        missing = [name for name in listed if "lib/modules/" + name not in boot_entries]
        if missing:
            errors.append("listed modules missing from the initrd: %s" % ", ".join(missing[:10]))

    if "scripts/halium" in boot_entries:
        halium = boot_entries["scripts/halium"][1].decode("utf-8", "replace")
        if 'insmod -f "$1"' not in halium:
            errors.append("scripts/halium was not patched to insmod -f")
        if 'modprobe -a "$1"' in halium:
            errors.append("scripts/halium still contains modprobe -a")
    else:
        errors.append("scripts/halium is missing from the boot ramdisk")

    insmod = boot_entries.get("sbin/insmod")
    if insmod is None:
        errors.append("sbin/insmod is missing from the boot ramdisk")
    else:
        mode, body = insmod
        if (mode & 0o170000) != 0o120000:
            errors.append("sbin/insmod is not a symlink")
        elif body.decode("utf-8", "replace").rstrip("\x00") != "/bin/kmod":
            errors.append("sbin/insmod points to %r instead of /bin/kmod" % body)

vendor_cpio = os.path.join(work, "verify_vendor", "vendor_ramdisk", "ramdisk.cpio")
if not os.path.exists(vendor_cpio):
    vendor_cpio = os.path.join(work, "verify_vendor", "ramdisk.cpio")
vendor_entries = parse_newc(vendor_cpio)
vendor_files = [normalize(name) for name, _, _ in vendor_entries if normalize(name) not in ("", ".")]
if vendor_files:
    errors.append("the vendor ramdisk is not empty: %s" % ", ".join(vendor_files[:10]))

with open(os.path.join(work, "vendor", "dtb"), "rb") as fh:
    stock_dtb = fh.read()
with open(os.path.join(work, "verify_vendor", "dtb"), "rb") as fh:
    new_dtb = fh.read()
if stock_dtb != new_dtb:
    errors.append("the vendor DTB changed during repack")

print("boot cmdline:   %s" % boot_header.get("cmdline"))
print("vendor cmdline: %s" % vendor_header.get("cmdline"))
print("boot ramdisk entries: %d" % len(boot_entries))
print("vendor ramdisk entries: %d" % len(vendor_entries))

if errors:
    print("\nVERIFICATION FAILED:")
    for error in errors:
        print("  - " + error)
    raise SystemExit(1)

print("verification: OK")
PY

########################################################################
# 10. Manifest and checksums
########################################################################
log "Writing manifest and checksums"
{
    printf 'cmdline=%s\n' "${CMDLINE}"
    printf 'boot_partition_size=%s\n' "${BOOT_PARTITION_SIZE}"
    printf 'vendor_boot_partition_size=%s\n' "${VENDOR_BOOT_SIZE}"
    printf 'module_count=%s\n' "${MODULE_COUNT}"
    printf 'initrd_uncompressed_bytes=%s\n' "${NEW_INITRD_SIZE}"
    printf 'boot_image_bytes=%s\n' "$(stat -c%s "${OUTDIR}/boot-droidian.img")"
    printf 'vendor_boot_image_bytes=%s\n' "$(stat -c%s "${OUTDIR}/vendor_boot-droidian.img")"
    printf 'image_gz_sha256=%s\n' "$(sha256sum "${OUTDIR}/Image.gz" | awk '{print $1}')"
    printf 'boot_sha256=%s\n' "$(sha256sum "${OUTDIR}/boot-droidian.img" | awk '{print $1}')"
    printf 'vendor_boot_sha256=%s\n' "$(sha256sum "${OUTDIR}/vendor_boot-droidian.img" | awk '{print $1}')"
    printf 'patched_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'patched_by=%s\n' "scripts/patch_vendor_boot_cloud.sh"
} > "${OUTDIR}/manifest.txt"

(
    cd "${OUTDIR}"
    sha256sum boot-droidian.img vendor_boot-droidian.img manifest.txt > SHA256SUMS
)

log "Done"
ls -l "${OUTDIR}"
printf '\n'
cat "${OUTDIR}/SHA256SUMS"

if [ "${KEEP_WORK}" -eq 1 ]; then
    log "Work directory kept at ${WORKDIR}"
fi
X6882_FILE_12_d509dd46

log "Writing scripts/prepare_kernel_cloud.sh"
cat > "${TARGET_DIR}/scripts/prepare_kernel_cloud.sh" <<'X6882_FILE_13_c58bff20'
#!/usr/bin/env bash
#
# Prepare the X6882 Droidian kernel defconfig without a full kernel build.
#
#   scripts/prepare_kernel_cloud.sh <kernel-tree> [fragment]
#
# The kernel tree is expected to be a checkout of
#   https://github.com/XTENSEI/kernel_common_5.10.git
# with arch/arm64/configs/gki_defconfig available.
#
# Produces:
#   <kernel-tree>/arch/arm64/configs/x6882_droidian_defconfig
#   <workdir>/prepare-*.log
#
# The Halium checker is pinned by commit and SHA-256.  It is run with -w to
# bring the GKI defconfig up to the Halium requirements, then the fragment is
# re-applied (the checker's -w mode has known bugs around
# CONFIG_DEFAULT_SECURITY and duplicate symbols), duplicates are removed with
# last-occurrence-wins semantics, and a final read-only checker run proves the
# file is clean.
set -euo pipefail

KERNEL_DIR="${1:?usage: prepare_kernel_cloud.sh <kernel-tree> [fragment]}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRAGMENT="${2:-${SCRIPT_DIR}/../configs/droidian_x6882.conf}"

DEFCONFIG_NAME="x6882_droidian_defconfig"
DEFCONFIG="${KERNEL_DIR}/arch/arm64/configs/${DEFCONFIG_NAME}"
GKI_DEFCONFIG="${KERNEL_DIR}/arch/arm64/configs/gki_defconfig"

CHECKER_URL="https://raw.githubusercontent.com/Halium/halium-boot/499ea587183ea9407a0ccce64013b6cfa80d0efe/check-kernel-config"
CHECKER_SHA256="4859517985c5180b3686be2dd57dc3b5c83d31bc3e37db6657b09870dd8bdd61"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

log()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
fail() { printf '\n\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ -d "${KERNEL_DIR}" ]       || fail "kernel tree not found: ${KERNEL_DIR}"
[ -f "${GKI_DEFCONFIG}" ]    || fail "gki_defconfig not found: ${GKI_DEFCONFIG}"
[ -f "${FRAGMENT}" ]         || fail "fragment not found: ${FRAGMENT}"
command -v python3 >/dev/null || fail "python3 is required"
command -v curl >/dev/null    || fail "curl is required"

log "Copying gki_defconfig -> ${DEFCONFIG_NAME}"
cp "${GKI_DEFCONFIG}" "${DEFCONFIG}"

log "Stripping KernelSU / SUSFS lines"
grep -v -E 'CONFIG_(KSU|SUSFS)' "${DEFCONFIG}" > "${WORKDIR}/stripped" || true
mv "${WORKDIR}/stripped" "${DEFCONFIG}"

log "Applying Droidian fragment"
{
    printf '\n# ===== BEGIN droidian_x6882.conf =====\n'
    cat "${FRAGMENT}"
    printf '\n# ===== END droidian_x6882.conf =====\n'
} >> "${DEFCONFIG}"

log "Fetching pinned Halium check-kernel-config"
CHECKER="${WORKDIR}/check-kernel-config"
curl -fsSL --retry 3 --retry-delay 2 --max-time 120 "${CHECKER_URL}" -o "${CHECKER}"
ACTUAL_SHA256="$(sha256sum "${CHECKER}" | awk '{print $1}')"
[ "${ACTUAL_SHA256}" = "${CHECKER_SHA256}" ] || \
    fail "checker SHA-256 mismatch: expected ${CHECKER_SHA256}, got ${ACTUAL_SHA256}"
chmod +x "${CHECKER}"

log "Running Halium checker in write mode"
set +e
bash "${CHECKER}" "${DEFCONFIG}" -w > "${WORKDIR}/checker-write.log" 2>&1
CHECKER_WRITE_RC=$?
set -e
cat "${WORKDIR}/checker-write.log"
# The checker always exits 0; a non-zero exit is a script/environment error.
[ "${CHECKER_WRITE_RC}" -eq 0 ] || fail "checker -w exited ${CHECKER_WRITE_RC}"

# Re-apply the fragment after -w.  The checker's CONFIG_DEFAULT_SECURITY
# rewrite replaces every line starting with that prefix, which can delete
# CONFIG_DEFAULT_SECURITY_APPARMOR and the explicit "is not set" lines.
# Re-applying also restores any value the checker rewrote with a different
# intent (for example =m became =y).
log "Re-applying Droidian fragment after checker"
{
    printf '\n# ===== BEGIN droidian_x6882.conf (post-checker) =====\n'
    grep -E '^(# )?CONFIG_[A-Za-z0-9_]+' "${FRAGMENT}" || true
    printf '# ===== END droidian_x6882.conf (post-checker) =====\n'
} >> "${DEFCONFIG}"

log "De-duplicating symbols (last occurrence wins)"
python3 - "${DEFCONFIG}" <<'PY'
import re
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8", errors="replace") as fh:
    lines = fh.read().splitlines()

key_re = re.compile(r'^(?:#\s*)?(CONFIG_[A-Za-z0-9_]+)(?:=|\s|$)')

def key(line):
    match = key_re.match(line)
    return match.group(1) if match else None

last = {}
for index, line in enumerate(lines):
    symbol = key(line)
    if symbol is not None:
        last[symbol] = index

out = []
for index, line in enumerate(lines):
    symbol = key(line)
    if symbol is None or last[symbol] == index:
        out.append(line)

# Collapse the run of blank lines left by removed duplicates.
cleaned = []
for line in out:
    if line.strip() == "" and cleaned and cleaned[-1].strip() == "":
        continue
    cleaned.append(line)

while cleaned and cleaned[-1].strip() == "":
    cleaned.pop()

with open(path, "w", encoding="utf-8", newline="\n") as fh:
    fh.write("\n".join(cleaned))
    fh.write("\n")

print(f"de-duplicated: {len(lines)} -> {len(cleaned)} lines, {len(last)} symbols")
PY

log "Asserting critical values survived preparation"
assert_kv() {
    local expected="$1"
    if ! grep -qxF -- "${expected}" "${DEFCONFIG}"; then
        printf '\nMissing expected line: %s\n' "${expected}" >&2
        exit 1
    fi
}
assert_absent() {
    local pattern="$1"
    if grep -qE -- "${pattern}" "${DEFCONFIG}"; then
        printf '\nUnexpected line matching: %s\n' "${pattern}" >&2
        grep -nE -- "${pattern}" "${DEFCONFIG}" >&2 || true
        exit 1
    fi
}

assert_kv 'CONFIG_MODULE_FORCE_LOAD=y'
assert_kv 'CONFIG_VT=y'
assert_kv 'CONFIG_VT_CONSOLE=y'
assert_kv 'CONFIG_DEVTMPFS=y'
assert_kv 'CONFIG_DEVTMPFS_MOUNT=y'
assert_kv 'CONFIG_SECURITY_SELINUX_DEVELOP=y'
assert_kv 'CONFIG_SECURITY_APPARMOR=y'
assert_kv 'CONFIG_DEFAULT_SECURITY_APPARMOR=y'
assert_kv 'CONFIG_LOCALVERSION=""'
assert_kv 'CONFIG_CMDLINE=""'
assert_absent '^CONFIG_MODVERSIONS=y'
assert_absent '^CONFIG_(KSU|SUSFS)[A-Za-z0-9_]*='

log "Running final Halium checker (read-only)"
set +e
bash "${CHECKER}" "${DEFCONFIG}" > "${WORKDIR}/checker-final.log" 2>&1
CHECKER_FINAL_RC=$?
set -e
cat "${WORKDIR}/checker-final.log"
[ "${CHECKER_FINAL_RC}" -eq 0 ] || fail "final checker exited ${CHECKER_FINAL_RC}"

if grep -q 'found [1-9][0-9]* errors' "${WORKDIR}/checker-final.log"; then
    fail "Halium checker reported errors (see log above)"
fi
grep -q 'found no errors' "${WORKDIR}/checker-final.log" || \
    fail "could not confirm a clean Halium checker result"

log "Prepared ${DEFCONFIG}"
wc -l "${DEFCONFIG}"
ls -l "${DEFCONFIG}"
printf '\nKey settings:\n'
grep -E '^(CONFIG_(MODVERSIONS|MODULE_FORCE_LOAD|VT|VT_CONSOLE|DEVTMPFS|DEVTMPFS_MOUNT|SECURITY_APPARMOR|DEFAULT_SECURITY_APPARMOR|DEFAULT_SECURITY|LOCALVERSION|CMDLINE|SCSI_UFSHCD|ZRAM|SWAP|CFG80211|MAC80211|SECURITY_SELINUX)=|# CONFIG_MODVERSIONS is not set)' "${DEFCONFIG}" || true

printf '\nNext: make -C %s O=out ARCH=arm64 LLVM=1 LLVM_IAS=1 %s\n' \
    "${KERNEL_DIR}" "Image.gz"
X6882_FILE_13_c58bff20

log "Verifying SHA-256 checksums"
(
    cd "${TARGET_DIR}"
    sha256sum -c <<'X6882_CHECKSUMS_EOF'
64f4bfa67884028c796f4461a9237dd06fb374e4a33f0fc4f4d7f32c54c68e65  .gitignore
fb5ddbeb97a05afd73038960d48eb9b44dfd52de242f0ceae39ae4debd790559  README.md
2de7ed6c4011fa5c4b7f88a8bcdbe0a2a6314ac406c31b70bc1b416b8162b57b  .github/workflows/build-droidian-kernel.yml
b8c3a973a8cd3d6745bd251dd60d9b82aa18404efe3e86d93d617aac785f9d85  anykernel/anykernel.sh
f220ec04b816a7b8970a151d4e3e489a2e7853015240e9d7bcf1ff101e5bb651  configs/droidian_x6882.conf
9680d49cfd0be5974e3490017603577433bf4289c8075d2d2d406d716162eb56  debian/check-config.sh
ead97536b7fe6d7cd2ec2ac8873f733592e68bd1c558b9798c3a12a272f2001c  debian/copyright
562dacf36daebf5e5f2d6ada484754b76f5b36b0b2e1a56d94e65fd8a0406ad6  debian/kernel-info.mk
ddf587e7e15f4324c55e4328de0fd49f5046bb599b28a202682c8eaf49058dd3  debian/rules
e8e18df40bcd69d6aa404282679186d9b8256ac63a5b4e80d7f081e8a0095a2e  debian/source/format
5216400ad1c9ab492ab7c806111a8d0bf6964ca5d71e5ef565828fdf2e62a45e  scripts/build_deb_in_container.sh
d509dd46a33797d82be9a77a725c4fe156330655e701168d604cd7c919f4d17c  scripts/patch_vendor_boot_cloud.sh
c58bff20fddfe23d3b5760fff589818ecdc009229b8d842c4e637e88243148d5  scripts/prepare_kernel_cloud.sh
X6882_CHECKSUMS_EOF
)

if [ "${INCLUDE_SELF}" = "1" ] && [ "${SCRIPT_PATH}" != "${TARGET_DIR}/setup_repo.sh" ]; then
    cp -f "${SCRIPT_PATH}" "${TARGET_DIR}/setup_repo.sh"
    log "Copied setup_repo.sh into the repository"
fi

# The /sdcard FUSE mount cannot store executable bits, so also record the
# modes in the git index after staging.  This is what a Linux CI checkout uses.
for path in \
    anykernel/anykernel.sh \
    debian/check-config.sh \
    debian/rules \
    scripts/build_deb_in_container.sh \
    scripts/patch_vendor_boot_cloud.sh \
    scripts/prepare_kernel_cloud.sh \
    setup_repo.sh
do
    if [ -f "${TARGET_DIR}/${path}" ]; then
        chmod +x "${TARGET_DIR}/${path}" 2>/dev/null || true
    fi
done

log "Initialising git"
if [ ! -d "${TARGET_DIR}/.git" ]; then
    git -C "${TARGET_DIR}" init -b main >/dev/null
fi

if ! git -C "${TARGET_DIR}" config user.name >/dev/null 2>&1; then
    git -C "${TARGET_DIR}" config user.name "${GIT_NAME}"
fi
if ! git -C "${TARGET_DIR}" config user.email >/dev/null 2>&1; then
    git -C "${TARGET_DIR}" config user.email "${GIT_EMAIL}"
fi

git -C "${TARGET_DIR}" add -A
for path in \
    anykernel/anykernel.sh \
    debian/check-config.sh \
    debian/rules \
    scripts/build_deb_in_container.sh \
    scripts/patch_vendor_boot_cloud.sh \
    scripts/prepare_kernel_cloud.sh \
    setup_repo.sh
do
    if [ -f "${TARGET_DIR}/${path}" ]; then
        git -C "${TARGET_DIR}" update-index --chmod=+x "${path}"
    fi
done

if git -C "${TARGET_DIR}" diff --cached --quiet; then
    log "No changes to commit"
else
    git -C "${TARGET_DIR}" commit -m "Initial X6882 Droidian cloud builder" >/dev/null
    log "Committed"
fi

if [ -n "${GIT_REMOTE}" ]; then
    if git -C "${TARGET_DIR}" remote get-url origin >/dev/null 2>&1; then
        git -C "${TARGET_DIR}" remote set-url origin "${GIT_REMOTE}"
    else
        git -C "${TARGET_DIR}" remote add origin "${GIT_REMOTE}"
    fi
    log "origin -> ${GIT_REMOTE}"
fi

if [ "${PUSH}" = "1" ] && [ "${SKIP_PUSH}" != "1" ]; then
    [ -n "${GIT_REMOTE}" ] || fail "PUSH=1 requires GIT_REMOTE"
    BRANCH="$(git -C "${TARGET_DIR}" symbolic-ref --short HEAD)"
    log "Pushing ${BRANCH} to origin/main"
    git -C "${TARGET_DIR}" push -u origin "${BRANCH}:main"
fi

log "Repository ready: ${TARGET_DIR}"
printf '  files: %s\n' "$(git -C "${TARGET_DIR}" ls-files | wc -l)"
printf '  size:  %s\n' "$(du -sh "${TARGET_DIR}" | awk '{print $1}')"
printf '  HEAD:  %s\n' "$(git -C "${TARGET_DIR}" log -1 --oneline 2>/dev/null || echo '(no commit)')"
cat <<'NEXT_STEPS_EOF'

Next steps:
  1. Create a release named "dump-assets" in the GitHub repository and upload
     the stock boot.img and vendor_boot.img:
       gh release create dump-assets --title "X6882 stock dumps" \
         --notes "Stock boot.img and vendor_boot.img" boot.img vendor_boot.img
  2. Push to main for Mode A, or trigger the workflow manually:
       gh workflow run build-droidian-kernel.yml -f mode=both
  3. Download the "x6882-droidian-boot-images" artifact and flash it with
     fastboot.  See README.md for the exact commands and the limitations.
NEXT_STEPS_EOF
