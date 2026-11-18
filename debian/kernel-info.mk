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
