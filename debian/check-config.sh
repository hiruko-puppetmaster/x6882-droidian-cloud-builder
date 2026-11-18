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
