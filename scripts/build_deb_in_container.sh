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
# The build-essential image can ship the 2024 keyring, which no longer
# verifies the current archive (signed by 5E775B2A27AB0C94).  The 2025
# keyring package is fetched over HTTPS and pinned by SHA-256; gpgv was used
# to confirm that this keyring verifies the current Release.gpg.
DROIDIAN_KEYRING_URL='https://production.repo.droidian.org/pool/main/d/droidian-archive-keyring/droidian-archive-keyring_2025.01.06+git20250106145953.b4c3a11.next.production_all.deb'
DROIDIAN_KEYRING_SHA256='c0ecf8aa8ab0dc198fca30748d50e0ccea1671e22ffcd651cf925dd7e48993cf'

log()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
fail() { printf '\n\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

download_file() {
    local url="$1" out="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 5 --retry-delay 5 --max-time 300 -o "${out}" "${url}"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "${out}" "${url}"
    elif command -v python3 >/dev/null 2>&1; then
        python3 - "${url}" "${out}" <<'PY'
import sys
import urllib.request

with urllib.request.urlopen(sys.argv[1], timeout=300) as response:
    with open(sys.argv[2], "wb") as handle:
        handle.write(response.read())
PY
    else
        fail "curl, wget and python3 are all missing; cannot fetch the Droidian keyring"
    fi
}

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

    log "Refreshing the Droidian archive keyring"
    KEYRING_DEB="/tmp/droidian-archive-keyring.deb"
    KEYRING_DIR="$(mktemp -d)"
    download_file "${DROIDIAN_KEYRING_URL}" "${KEYRING_DEB}"
    echo "${DROIDIAN_KEYRING_SHA256}  ${KEYRING_DEB}" | sha256sum -c -
    dpkg-deb -x "${KEYRING_DEB}" "${KEYRING_DIR}"
    install -m 0644 "${KEYRING_DIR}/usr/share/archive-keyrings/droidian.gpg" \
        /usr/share/archive-keyrings/droidian.gpg
    rm -rf "${KEYRING_DEB}" "${KEYRING_DIR}"

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
        kmod \
        patch

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

git add -A
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
