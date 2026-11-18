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
