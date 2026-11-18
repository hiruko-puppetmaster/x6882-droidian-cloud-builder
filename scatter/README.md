# X6882 storage layout and SP Flash Tool scatters

The Infinix Hot 50 4G (`X6882`, MediaTek Helio G100 / `MT6789`) uses **UFS
2.2**, not eMMC. Every scatter that has been circulating for this phone was
written for eMMC or was derived from a GPT table with a 12 KiB error. Flashing
one of those can at best fail and at worst write the preloader in the wrong
place.

This directory contains a validated dual-section (EMMC + UFS) scatter for the
real layout, two boot-recovery variants that touch only the `boot`/`vbmeta`
chain, the GPT table it was built from, and a validator.

> The phone is UFS 2.2, so SP Flash Tool uses the **UFS** section of these
> files. The EMMC section mirrors the same GPT purely so the file has the
> layout MediaTek tools expect; it does not describe real eMMC hardware.
>
> Do not use the copies in `/sdcard/mtk` or `/sdcard/Download`; they are
> eMMC-only or carry the 12 KiB offset error described below. The old
> eMMC-only scatter from the firmware folder is kept as
> `MT6789_Android_scatter_eMMC_only_OLD.txt`.

## Evidence

| Fact | Source |
| --- | --- |
| UFS 2.2, FORESEE `C2G074` (`F30240585B54`) | `CHIP CONFIG/UFS_FORESEE_C2G074_F30240585B54_config.ini` |
| Logical block size 4096 B | same file, `bLogicalBlockSize=12` (2^12) |
| LU0 = Boot A, LU1 = Boot B, LU2 = user area | same file, `bBootLunID=1/2/0` |
| LU0 4 MiB, LU1 4 MiB | `Lun_0_P00_BootA.bin`, `Lun_1_P01_BootB.bin` |
| LU2 = 62,480,384 × 4096 B = `0x3B96000000` | backup GPT header at LBA 62,480,383 |
| 68 GPT partitions | primary GPT at LU2 offset `0x1000` |

The primary GPT header and the partition-entry array both pass their CRC32
checks (`0x919B1A46` and `0x8F94FCC1`), so the table below is the authoritative
one. The GPT is a standard 128-bit-entry table:

```
protective MBR        LBA 0           0x0
primary header        LBA 1           0x1000
entry array           LBA 2..3        0x2000   (68 × 128 B = 8704 B)
first partition       LBA 8           0x8000   (boot_para)
last usable LBA       62,480,375
backup entry array    LBA 62,480,380  0x3B95FFC000
backup header         LBA 62,480,383  0x3B95FFF000
```

MediaTek starts `boot_para` at LBA 8, inside the area a stock GPT header calls
reserved (its `first usable LBA` is 34). That is normal here: only LBAs 2–3 of
the entry array are actually used, and the partitions are contiguous without
overlap. Do not "repair" `boot_para` to `0x22000`.

## LUN map

| LUN | Role | Size | Scatter region | Notes |
| --- | --- | --- | --- | --- |
| LU0 | Boot A | 4 MiB | `UFS_LU0_LU1` (with LU1) | bootloader A; contains a `UFS_BOOT` header at 0 and the preloader at `0x1000` |
| LU1 | Boot B | 4 MiB | `UFS_LU1` | bootloader B |
| LU2 | User area | 238.34 GiB | `UFS_LU2` | GPT, all 68 partitions |

The scatter's `block_size` for UFS is `0x80000` (512 KiB), `boot_channel` is
`UFSHCI_0`, and every partition uses `storage: HW_STORAGE_UFS`.

## File format

The file follows the MediaTek dual-layout convention: one
`- storage_type: EMMC` block followed by one `- storage_type: UFS` block. Both
carry the same 72 entries with the same offsets and sizes; only the region and
storage names differ:

| Field | EMMC section | UFS section |
| --- | --- | --- |
| `storage` | `HW_STORAGE_EMMC` | `HW_STORAGE_UFS` |
| `boot_channel` | `MSDC_0` | `UFSHCI_0` |
| `block_size` | `0x20000` | `0x80000` |
| preloader region | `EMMC_BOOT1_BOOT2` | `UFS_LU0_LU1` |
| preloader backup region | `EMMC_BOOT2` | `UFS_LU1` |
| GPT partitions region | `EMMC_USER` | `UFS_LU2` |
| `flashinfo` marker | `0xFFFF0080` | `0xFFFF0020` |
| `sgpt` marker | `0xFFFF0000` | `0xFFFF0000` |

SP Flash Tool selects the section that matches the storage it detects; on this
phone that is always UFS. The EMMC block is a compatibility mirror — there is
no eMMC dump for X6882, so those entries exist only for tools that expect the
two-section form. `verify_scatter.py` checks that both sections describe the
same geometry and enable the same images.

## Partition table (LUN2)

| Partition | Offset | Size |
| --- | --- | --- |
| `boot_para` | `0x8000` | `0x100000` |
| `proinfo` | `0x108000` | `0x300000` |
| `misc` | `0x408000` | `0x80000` |
| `para` | `0x488000` | `0x80000` |
| `expdb` | `0x508000` | `0x8000000` |
| `frp` | `0x8508000` | `0x100000` |
| `nvcfg` | `0x8608000` | `0x2000000` |
| `nvdata` | `0xa608000` | `0x4000000` |
| `vbmeta_a` | `0xe608000` | `0x800000` |
| `vbmeta_system_a` | `0xee08000` | `0x800000` |
| `vbmeta_vendor_a` | `0xf608000` | `0x800000` |
| `vbmeta_b` | `0xfe08000` | `0x800000` |
| `vbmeta_system_b` | `0x10608000` | `0x800000` |
| `vbmeta_vendor_b` | `0x10e08000` | `0x800000` |
| `metadata` | `0x11608000` | `0x2000000` |
| `persist` | `0x13608000` | `0x31f8000` |
| `protect1` | `0x16800000` | `0x800000` |
| `protect2` | `0x17000000` | `0x800000` |
| `seccfg` | `0x17800000` | `0x800000` |
| `otp` | `0x18000000` | `0x3000000` |
| `md1img_a` | `0x1b000000` | `0xc800000` |
| `tdfs` | `0x27800000` | `0x3800000` |
| `transec` | `0x2b000000` | `0x3800000` |
| `spmfw_a` | `0x2e800000` | `0x100000` |
| `pi_img_a` | `0x2e900000` | `0x100000` |
| `dpm_a` | `0x2ea00000` | `0x400000` |
| `scp_a` | `0x2ee00000` | `0x600000` |
| `sspm_a` | `0x2f400000` | `0x100000` |
| `mcupm_a` | `0x2f500000` | `0x100000` |
| `gz_a` | `0x2f600000` | `0x2000000` |
| `lk_a` | `0x31600000` | `0x400000` |
| `logo_a` | `0x31a00000` | `0x1800000` |
| `boot_a` | `0x33200000` | `0x4000000` |
| `vendor_boot_a` | `0x37200000` | `0x4000000` |
| `init_boot_a` | `0x3b200000` | `0x800000` |
| `dtbo_a` | `0x3ba00000` | `0x800000` |
| `tee_a` | `0x3c200000` | `0x500000` |
| `sec1` | `0x3c700000` | `0x200000` |
| `efuse` | `0x3c900000` | `0x80000` |
| `nvram` | `0x3c980000` | `0x4000000` |
| `dram_para` | `0x40980000` | `0x1900000` |
| `connsys_bt_a` | `0x42280000` | `0x800000` |
| `connsys_wifi_a` | `0x42a80000` | `0x800000` |
| `connsys_gnss_a` | `0x43280000` | `0xd80000` |
| `md1img_b` | `0x44000000` | `0xc800000` |
| `spmfw_b` | `0x50800000` | `0x100000` |
| `pi_img_b` | `0x50900000` | `0x100000` |
| `dpm_b` | `0x50a00000` | `0x400000` |
| `scp_b` | `0x50e00000` | `0x600000` |
| `sspm_b` | `0x51400000` | `0x100000` |
| `mcupm_b` | `0x51500000` | `0x100000` |
| `gz_b` | `0x51600000` | `0x2000000` |
| `lk_b` | `0x53600000` | `0x400000` |
| `logo_b` | `0x53a00000` | `0x1800000` |
| `boot_b` | `0x55200000` | `0x4000000` |
| `vendor_boot_b` | `0x59200000` | `0x4000000` |
| `init_boot_b` | `0x5d200000` | `0x800000` |
| `connsys_bt_b` | `0x5da00000` | `0x800000` |
| `connsys_wifi_b` | `0x5e200000` | `0x800000` |
| `connsys_gnss_b` | `0x5ea00000` | `0x800000` |
| `dtbo_b` | `0x5f200000` | `0x800000` |
| `tee_b` | `0x5fa00000` | `0x600000` |
| `super` | `0x60000000` | `0x2a3448000` |
| `tkv_a` | `0x303448000` | `0x100000` |
| `tkv_b` | `0x303548000` | `0x100000` |
| `tranfs` | `0x303648000` | `0x131b8000` |
| `userdata` | `0x316800000` | `0x387e7f8000` |
| `flashinfo` | `0x3b94ff8000` | `0x1000000` |

`GPT_PARTITION_TABLE_UFS.csv` has the same data in machine-readable form,
including first/last LBA and decimal sizes.

## Reserved tail

`userdata` ends exactly at `0x3B94FF8000`. The last 16 MiB before the backup
GPT is `flashinfo`, and the last 32 KiB is the backup GPT:

```
0x3B94FF8000  flashinfo   0x1000000
0x3B95FF8000  backup GPT entries + header + last sector   0x8000
0x3B96000000  end of LU2
```

SP Flash Tool does not store those two absolute addresses in the scatter. It
uses sentinel values that it resolves against the LU2 capacity:

| Partition | Scatter address | Scatter size | Flags |
| --- | --- | --- | --- |
| `flashinfo` | `0xFFFF0020` | `0x1000000` | `boundary_check: false`, `is_reserved: true`, `operation_type: RESERVED` |
| `sgpt` | `0xFFFF0000` | `0x8000` | `boundary_check: false`, `is_reserved: true`, `operation_type: RESERVED` |

The `0xFFFF...` values are markers, not addresses, and the offset echoes MediaTek's
own MT6789 UFS scatters. Resolving them against `0x3B96000000` reproduces the
GPT positions exactly, which is the consistency check used here. Do not replace
them with absolute addresses; SPFT would treat `0x3B94FF8000` as a *low* address
and the write would land in the wrong place.

Note that `pgpt` at `0x0` and `preloader` at `0x0` are not an overlap: they live
on different LUNs (`UFS_LU2` vs `UFS_LU0_LU1`).

## What was wrong with the other scatters

The old `MT6789_Android_scatter.txt` from the firmware folder (71 entries,
30,903 B, now kept as `MT6789_Android_scatter_eMMC_only_OLD.txt`) was eMMC
only:

| Field | That file | Reality |
| --- | --- | --- |
| `storage_type` | `EMMC` | `UFS` |
| `boot_channel` | `MSDC_0` | `UFSHCI_0` |
| `block_size` | `0x20000` | `0x80000` |
| `preloader` region | `EMMC_BOOT1_BOOT2` | `UFS_LU0_LU1` |
| all GPT partitions | `EMMC_USER` | `UFS_LU2` |
| `preloader_backup` | absent | `UFS_LU1`, `0x100000` |
| `flashinfo` | `0x3B94FFB000` (absolute) | `0xFFFF0020` (sentinel) |
| `sgpt` | `0xFFFF0000`, `0x8000` | same sentinel |
| `userdata` size | `0x387E7FB000` | `0x387E7F8000` |

The `userdata` size and the `flashinfo` offset are both 12 KiB (3 × 4096 B)
too large. That error comes from `GPT_PARTITION_TABLE.csv` in the firmware
folder, whose `userdata` row claims 59,238,395 sectors instead of 59,238,392
and whose `flashinfo` row starts at LBA 62,476,283 instead of 62,476,280. The
old scatter copied those numbers, so `userdata` overlapped `flashinfo` by three
blocks.

The other two scatters on the phone have the same 12 KiB error:

| File | Problems |
| --- | --- |
| `/sdcard/mtk/MT6789_Android_scatter.txt` | dual EMMC+UFS sections; UFS section still uses `0x3B94FFB000`, `sgpt 0x3B95FFB000/0x5000`, no `preloader_backup` |
| `/sdcard/Download/MT6789_Android_scatter.txt` | `boot_channel: UFS_LU0` (not `UFSHCI_0`), `block_size: 0x1000`, preloader in `UFS_LU0` at 4 MiB, same 12 KiB error |

## Files in this directory

| File | Enabled per section | Use |
| --- | --- | --- |
| `MT6789_Android_scatter.txt` | 39 | complete map: preloader, preloader backup, both slots' firmware, `super` |
| `MT6789_Android_scatter_boot_recovery.txt` | 5 | slot A boot chain only: `boot_a`, `vendor_boot_a`, `vbmeta_a`, `vbmeta_system_a`, `vbmeta_vendor_a` |
| `MT6789_Android_scatter_boot_recovery_ab.txt` | 10 | same for slots A and B |
| `GPT_PARTITION_TABLE_UFS.csv` | – | GPT table parsed from the dump |
| `verify_scatter.py` | – | checks a scatter against the CSV |

Each file has 72 entries in the EMMC section and the same 72 in the UFS
section, with identical geometry. The variants differ only in
`is_download`/`file_name`, and the choice is mirrored in both sections.
`preloader`, `preloader_backup`, `super` and `userdata` are disabled in both
recovery variants.

```
67d54d4156959b52286aa9610a34ea5830fe18662f7216be671de8ec05d32db8  MT6789_Android_scatter.txt
4a6eaa5997bd09ce24b26bfb43e50a17790721d5a40927cf16a093de6f250f06  MT6789_Android_scatter_boot_recovery.txt
f5d80c09ea7ddf52772790891f1cc4c9b6bccb80a960b6fb51abb5de837a9f28  MT6789_Android_scatter_boot_recovery_ab.txt
95c3975782efe9c14d2f7bb7b3252f3cd1eedff07742062af5c5ca8a77d8feca  GPT_PARTITION_TABLE_UFS.csv
```

## Recovery procedure

Try these in order. The first two write nothing to the flash.

### 1. Boot the untouched slot

If only slot A was flashed, slot B still has stock images. Switching the slot
is a single boot-control write and is reversible:

```bash
fastboot devices
fastboot --set-active=b
fastboot reboot          # or: fastboot continue
```

If Android boots, switch back with `fastboot --set-active=a` once slot A is
repaired.

### 2. Restore the stock boot chain with fastboot

```bash
fastboot flash boot            boot.img
fastboot flash vendor_boot     vendor_boot.img
fastboot flash vbmeta          vbmeta.img
fastboot flash vbmeta_system   vbmeta_system.img
fastboot flash vbmeta_vendor   vbmeta_vendor.img
fastboot reboot
```

These are the stock images from the same firmware build. `fastboot` resolves
`boot` to `boot_a` when slot A is active. Add `_b` suffixes to repair slot B
too. `init_boot` and `dtbo` were never modified and should be left alone.

If the bootloader refuses the writes (`FAILED (remote: 'not allowed in locked
state')`), the device is still locked; unlock it first (`fastboot flashing
unlock`).

### 3. SP Flash Tool, only if fastboot is gone

Use `MT6789_Android_scatter_boot_recovery.txt` and **Download Only** mode.
Only the five `boot`/`vbmeta` entries are checked; leave everything else
unchecked. Do **not** select *Format All + Download* and do **not** tick
`userdata`.

1. Load the scatter, confirm the file names resolve to the stock images.
2. Connect the phone powered off; SPFT needs the BROM/Preloader VCOM port.
   Hold the relevant key combination while plugging in if the port does not
   appear by itself.
3. Start. Only the image bytes are written (~128 MiB for the two 64 MiB boot
   images), so this takes seconds.
4. Disconnect, boot normally.

If the phone needs slot B as well, use `..._boot_recovery_ab.txt` instead.

## Open risks

* **Preloader offset is unverified.** `Lun_0_P00_BootA.bin` starts with a
  `UFS_BOOT` structure (magic at `0x0`, a `BRLYT` table at `0x200`) and the
  actual `MMM\x01` preloader at `0x1000`. The scatter says `preloader` lives at
  `0x0` of `UFS_LU0_LU1`. Whether SPFT writes the bare image at `0x0` and
  builds its own header, or expects the image to include it, cannot be
  determined from the dump. Keep `preloader` disabled unless the phone is
  already dead and a full dump/backup exists.
* The scatters have **not been executed on this hardware**. Everything here is
  derived from the dump and from MediaTek's own MT6789 UFS scatters, and passes
  the structural checks below, but the first real write is still the first.
* `super` is 11,329,110,016 bytes and takes a long time over BROM. It is only
  enabled in the complete scatter, which is meant for a full restore.
* Writing `userdata` destroys the user's data. It is disabled everywhere here.
* `init_boot_a/b` and `connsys_*_a/b` are all zero in the MIPI dump. Leave them
  disabled; flashing a zero image over a live partition is not an improvement.

## Validating

`verify_scatter.py` needs only Python 3 and the CSV in this directory:

```bash
python3 verify_scatter.py                       # all three scatters
python3 verify_scatter.py --images /path/to/fw  # also check image sizes
```

It checks both sections: the header of each (`UFS`/`UFSHCI_0`/`0x80000` and
`EMMC`/`MSDC_0`/`0x20000`), that every entry carries the matching storage tag
and a known region, that the preloader and `pgpt` geometry is right, that the
68 GPT partitions match the CSV offset and size exactly, that the sentinels
resolve into the reserved tail, that `userdata` ends where `flashinfo` begins,
and that no two user-area ranges overlap. When both sections are present it
also checks that they describe the same geometry and enable the same images.
The old eMMC scatter fails on the first checks.
