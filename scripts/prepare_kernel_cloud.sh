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

log "Applying kernel source patches"
bash "${SCRIPT_DIR}/apply_kernel_patches.sh" "${KERNEL_DIR}"

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
