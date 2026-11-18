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
| Storage | UFS 2.2 (FORESEE `C2G074`), 4096-byte blocks, LU0/LU1 boot LUNs, LU2 user area |
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
| `patches/0001-fanotify-fionread-fixed-metadata-len.patch` | Restores the 5.10.226 fixed FIONREAD length; the rebased HEAD carries only part of a newer fanotify series |
| `scripts/apply_kernel_patches.sh` | Applies `patches/*.patch` idempotently before the defconfig is prepared |
| `scripts/prepare_kernel_cloud.sh` | Copies `gki_defconfig`, applies the fragment, runs the Halium checker, dedupes symbols, produces `x6882_droidian_defconfig` |
| `debian/kernel-info.mk` | Droidian packaging settings: device identity, cmdline, boot header v4, toolchain |
| `debian/rules` | Includes `linux-packaging-snippets/kernel-snippet.mk`, generates `debian/control`, checks the resolved `.config` |
| `debian/check-config.sh` | Last-line assertions on the `.config` that `olddefconfig` actually produced |
| `debian/copyright`, `debian/source/format` | Debian source package metadata (`3.0 (native)`) |
| `scripts/build_deb_in_container.sh` | Runs inside `quay.io/droidian/build-essential:trixie-amd64`; generates control, builds debs, extracts images |
| `scripts/patch_vendor_boot_cloud.sh` | Merges the stock MTK modules into the Halium initrd, repacks `boot` and `vendor_boot` |
| `anykernel/anykernel.sh` | Hardlink-safe AnyKernel3 script (kernel-only update, `split_boot` + `flash_boot`) |
| `.github/workflows/build-droidian-kernel.yml` | The three CI jobs |
| `scatter/` | dual-section EMMC+UFS 2.2 scatter, boot-recovery variants, GPT table and validator; see `scatter/README.md` |
| `tools/verify-stock-avb.py` | `avbtool` pre-flight check for the stock boot chain |
| `setup_repo.sh` | Self-contained bootstrap that recreates every file above and initialises/pushes the git repo |

The kernel tree itself is **not** committed. The workflow clones
`kernel_common_5.10` shallowly, writes the prepared defconfig into it, and for
Mode B uses the checkout as the Debian source package root.

`scatter/` was added after the initial bootstrap, so `setup_repo.sh` does not
recreate it; those files are maintained directly.

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

### What AVB sees

`avbtool` was run on both the stock and the built images. The stock chain is
consistent: `vbmeta.img`, `vbmeta_system.img` and `vbmeta_vendor.img` all carry
valid `SHA256_RSA2048` signatures, their `system`/`vendor` hashtrees verify,
the `dtbo` and `vendor_boot` digests match the descriptors in `vbmeta.img`, and
`boot.img` carries a chained footer signed by the key named in the `boot`
chain descriptor.

The built images do not fit that chain:

* `boot-droidian.img` contains **no vbmeta footer at all**, so the `boot` chain
  descriptor has nothing to verify.
* `vendor_boot-droidian.img` keeps the stock footer but it is stale: `Flags: 3`,
  `Algorithm: NONE`, and the hash descriptor still declares the stock
  27,799,552-byte image and stock digest while the partition holds a 225,280-byte
  vendor image.

Both partitions are rejected before the kernel runs. `vbmeta-disabled.img` is
therefore mandatory, not optional. Restoring the stock `boot.img` and
`vendor_boot.img` is enough to undo it; the stock `vbmeta` does not need to be
reflashed.

## Recovery

Keep the stock dumps. If the phone does not boot after flashing the Droidian
images:

1. **Try the other slot first.** If only slot A was flashed, slot B still has
   stock images:

   ```bash
   fastboot --set-active=b
   fastboot reboot
   ```

   This writes only the boot-control slot marker and is reversible with
   `fastboot --set-active=a`.

2. **Restore the stock boot chain** on the active slot. First confirm the stock
   images are consistent:

   ```bash
   python3 tools/verify-stock-avb.py /path/to/stock
   ```

   It prints `PASS` when the stock `boot`/`vendor_boot`/`vbmeta` chain matches
   its AVB descriptors. Then flash:

   ```bash
   fastboot flash boot          stock/boot.img
   fastboot flash vendor_boot   stock/vendor_boot.img
   fastboot flash vbmeta        stock/vbmeta.img
   fastboot flash vbmeta_system stock/vbmeta_system.img
   fastboot flash vbmeta_vendor stock/vbmeta_vendor.img
   fastboot reboot
   ```

   `init_boot` and `dtbo` were never modified and should be left alone.
   Restoring `vbmeta` is only required if `vbmeta-disabled.img` was flashed,
   but doing it anyway is harmless: the stock images are AVB-signed and match
   the stock vbmeta.

3. **If fastboot is unavailable**, use SP Flash Tool with
   `scatter/MT6789_Android_scatter_boot_recovery.txt` in *Download Only* mode.
   This phone is **UFS 2.2**, not eMMC; every `MT6789_Android_scatter.txt`
   circulating for this model is eMMC-only or has a 12 KiB offset error, and
   would write the preloader and GPT tail in the wrong place. The scatters in
   `scatter/` carry both an EMMC and a UFS section, like MediaTek's
   dual-layout files; SPFT uses the UFS section on this phone.
   `scatter/README.md` has the verified partition table and the full procedure.

Never flash or format `userdata` unless the data is expendable.

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
* `patches/0001-fanotify-fionread-fixed-metadata-len.patch` repairs the
  `android12-5.10-rebased` HEAD: its `fanotify_ioctl()` was updated to call
  `fanotify_event_len()` and `FANOTIFY_INFO_MODES`, but neither exists in the
  tree. The patch restores the Linux 5.10.226 behavior (fixed metadata length)
  so `CONFIG_FANOTIFY`, which the Halium checker requires, still builds.
  `scripts/apply_kernel_patches.sh` applies it idempotently and fails loudly
  if a future kernel update changes the context.
* `debian/kernel-info.mk` sets `KERNEL_RELEASE = 5.10.274-infinix-x6882`,
  `KERNEL_BOOTIMAGE_VERSION = 4`, `KERNEL_INITRAMFS_COMPRESSION = lz4`,
  `DEVICE_HAS_INIT_BOOT = 0`, and the exact cmdline above.
* Mode B runs in `quay.io/droidian/build-essential:trixie-amd64`, adds
  `https://staging.repo.droidian.org/ trixie main`, installs
  `linux-packaging-snippets` and `linux-initramfs-halium-generic:arm64`,
  generates `debian/control`, and calls `releng-build-package` with
  `CI=true IS_CONTAINER=true RELENG_HOST_ARCH=arm64`.
  The image can carry the 2024 archive keyring, which no longer verifies the
  current archive; the script fetches the 2025 keyring package over HTTPS,
  checks its pinned SHA-256 and installs `droidian.gpg` before `apt-get update`.
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
* The stock AVB chain was verified end to end with `avbtool`: `vbmeta`,
  `vbmeta_system` and `vbmeta_vendor` signatures, the `system`/`vendor`
  hashtrees, the `dtbo`/`vendor_boot` hash descriptors, and the chained `boot`
  footer. The built images were checked the same way, which is how the
  bootloop cause (`boot-droidian.img` has no footer; `vendor_boot-droidian.img`
  has a stale one) was identified.
* The workflow has since been executed end-to-end; see the next section.

## CI validation

Both modes were run on the GitHub-hosted runner with builder commit `62e76da`
(Clang 12.0.5, `android12-5.10-rebased`, kernel 5.10.274).

* **Mode A** - run
  [44262796584](https://github.com/hiruko-puppetmaster/x6882-droidian-cloud-builder/actions/runs/44262796584):
  compile finished in 13m18s. `Image.gz` is 15,861,671 bytes with SHA-256
  `6bc408338d7600f6b38da26da5d46f45f433a99a97049a7f3ac6b43707c61dc2`;
  the AnyKernel3 zip is SHA-256
  `b3147d83bb7000f506ee81840456bc605d6c895213926645c781638b17a7424e`.
* **Mode B** - run
  [44262916297](https://github.com/hiruko-puppetmaster/x6882-droidian-cloud-builder/actions/runs/44262916297):
  six arm64 packages built through `releng-build-package`, version
  `5.10.274+git20261118081318.5e9b89c.x6882`. The base boot image is
  36,114,432 bytes, `Image.gz` is 15,861,671 bytes and the disabled vbmeta
  image is 4,096 bytes.
* **Repack** - the same run merged 210 stock modules, skipped 8 and copied and
  listed 179 in dependency order. The uncompressed initrd is 71,902,208 bytes
  and the boot header carries a 26,294,927-byte LZ4 ramdisk. Both output
  images are exactly 67,108,864 bytes:
  * `boot-droidian.img` SHA-256
    `fd2809f69c42b4cd735c45ff88ec236447ecf32bda47bcbb7c01d5a994c69e26`
  * `vendor_boot-droidian.img` SHA-256
    `1ba6296fa556f515de4d9bccdf8ed6f22e4148ce7fa1ec8e141340e4619aba38`
  * both headers carry the exact required cmdline; the vendor DTB is
    preserved at 212,093 bytes; the boot initrd contains 1,093 entries; the
    built-in verifier prints `verification: OK`.
* **Artifact re-inspection** - the uploaded `x6882-droidian-boot-images`
  artifact was downloaded again and checked independently: both image hashes
  and the manifest verify, the 15,861,671-byte kernel blob at offset 4096
  hashes to the manifest's `image_gz_sha256` and decompresses to a valid
  arm64 `Image`, the busybox hardlink group keeps 214 names with a matching
  `nlink` (the 215th was `/sbin/insmod`, now the intentional `/bin/kmod`
  symlink), all 179 `modules.load` entries match the 179 copied `.ko` files,
  and the vendor DTB is still 212,093 bytes.

## Local footprint

The tracked tree is a few hundred kilobytes of text. Building does not need
a local clone of the kernel, a local Docker image, a local toolchain, or a
local compiler. Only `git`/`gh` (to publish and trigger) and `fastboot` (to
flash) are needed on your machine.

## License

No license is declared. The files are porting glue for personal use; the
kernel source and the Droidian packaging snippets keep their own licenses.
