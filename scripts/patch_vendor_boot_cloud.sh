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
