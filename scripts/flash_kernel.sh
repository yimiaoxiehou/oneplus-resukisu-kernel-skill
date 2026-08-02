#!/usr/bin/env bash
# Flash a ReSukiSU kernel to a OnePlus device.
#
# Modes:
#   - raw boot.img  -> fastboot flash boot  (slot-aware)
#   - --boot-test   -> fastboot boot <img>  (RAM test, no flash; validates kernel+ReSukiSU)
#   - *.zip (AK3)   -> cannot be flashed by fastboot; instructs recovery/ksud instead
#
# Slot safety: refuses to flash _b on devices whose _b init_boot/vendor_boot are stale
# (verified on Ace 3 / Lunaris-AOSP). Provides rollback hints.
#
# Usage:
#   bash flash_kernel.sh [<device-serial>] <boot.img|ak3.zip> [--boot-test] [--slot a]
set -uo pipefail

SERIAL=""
IMG=""
BOOT_TEST=0
SLOT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --boot-test) BOOT_TEST=1; shift ;;
    --slot) SLOT="$2"; shift 2 ;;
    *.img|*.zip) IMG="$1"; shift ;;
    *) [ -z "$SERIAL" ] && SERIAL="$1"; shift ;;
  esac
done

[ -n "$IMG" ] || { echo "Usage: $0 [serial] <boot.img|ak3.zip> [--boot-test] [--slot a]"; exit 1; }
[ -f "$IMG" ] || { echo "ERROR: image not found: $IMG"; exit 1; }

FB="fastboot"
[ -n "$SERIAL" ] && FB="fastboot -s $SERIAL"

# ensure device is in fastboot
if ! $FB devices 2>/dev/null | grep -q "fastboot$"; then
  echo "==> device not in fastboot; rebooting to bootloader"
  ADB="adb"; [ -n "$SERIAL" ] && ADB="adb -s $SERIAL"
  $ADB reboot bootloader || { echo "ERROR: device not in fastboot and cannot reboot (no adb?)"; exit 1; }
  sleep 3
fi

SLOTARG=""
if [ -n "$SLOT" ]; then
  if [ "$SLOT" = "b" ]; then
    echo "⚠️  WARNING: flashing the _b slot. On Ace 3 / Lunaris the _b init_boot/vendor_boot"
    echo "    are stale (do not match the 5.15.207 kernel) and a correct kernel bootloops."
    echo "    Only proceed if you have already flashed matching init_boot+vendor_boot to _b."
    read -r -p "Type 'YES' to continue flashing _b: " ANS
    [ "$ANS" = "YES" ] || { echo "aborted"; exit 1; }
  fi
  SLOTARG="--slot $SLOT"
fi

if [ "$BOOT_TEST" = "1" ]; then
  echo "==> fastboot boot (RAM test, no flash): $IMG"
  $FB boot "$IMG"
  echo "If it booted: run verify_resukisu.sh, then flash for real (drop --boot-test)."
  exit 0
fi

if [[ "$IMG" == *.zip ]]; then
  echo "ERROR: $IMG is an AnyKernel3 zip — fastboot cannot flash zips."
  echo "Flash it via custom recovery (OrangeFox/TWRP) or:  ksud install $IMG"
  exit 1
fi

echo "==> $FB $SLOTARG flash boot $IMG"
$FB $SLOTARG flash boot "$IMG"
echo "==> reboot"
$FB reboot
echo
echo "Then: install a compatible manager (Official KernelSU me.weishu.kernelsu is simplest),"
echo "open it once, and run verify_resukisu.sh."
echo
echo "Rollback if it fails to boot:"
echo "  fastboot flash boot <stock_boot.img>   (or)   fastboot set_active <other_slot>"
