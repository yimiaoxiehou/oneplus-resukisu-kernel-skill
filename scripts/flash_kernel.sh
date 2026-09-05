#!/usr/bin/env bash
# Flash a ReSukiSU kernel to a OnePlus device.
# VERIFIED END-TO-END ONLY ON THE ONEPLUS ACE 3; other models may use different
# partition names / slot rules.
#
# Modes:
#   - raw boot.img  -> fastboot flash boot  (slot-aware; default = active slot)
#   - *.zip (AK3)   -> cannot be flashed by fastboot; instructs recovery/ksud instead
#   - --verify      -> after flashing, confirm `uname -r` matches the built banner
#
# WARNING: `fastboot boot <img>` (RAM test) is NON-FUNCTIONAL on this bootloader: it
#   reports "Booting OKAY" but then boots the slot's existing kernel, ignoring the temp
#   image. There is therefore NO reliable RAM test via fastboot. To validate a build,
#   flash it to a slot (keep the other slot as fallback) and check `uname -r` after reboot.
#
# Slot safety (Ace 3 / Lunaris / stock OnePlus Android 16): prefer flashing `boot_a`
# and keep `_b` as a fresh-stock fallback. Refusing to flash `_b` unless the user opts
# in with a matching init_boot/vendor_boot already on that slot.
#
# Usage:
#   bash flash_kernel.sh [<device-serial>] <boot.img|ak3.zip> [--slot a] [--verify]
set -uo pipefail

SERIAL=""
IMG=""
SLOT=""
VERIFY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --slot) SLOT="$2"; shift 2 ;;
    --verify) VERIFY=1; shift ;;
    *.img|*.zip) IMG="$1"; shift ;;
    *) [ -z "$SERIAL" ] && SERIAL="$1"; shift ;;
  esac
done

[ -n "$IMG" ] || { echo "Usage: $0 [serial] <boot.img|ak3.zip> [--slot a] [--verify]"; exit 1; }
[ -f "$IMG" ] || { echo "ERROR: image not found: $IMG"; exit 1; }

FB="fastboot"
[ -n "$SERIAL" ] && FB="fastboot -s $SERIAL"
ADB="adb"
[ -n "$SERIAL" ] && ADB="adb -s $SERIAL"

# ensure device is in fastboot
if ! $FB devices 2>/dev/null | grep -q "fastboot$"; then
  echo "==> device not in fastboot; rebooting to bootloader"
  $ADB devices 2>/dev/null | grep -q "device$" || { echo "ERROR: device not in fastboot and no adb device online"; exit 1; }
  $ADB reboot bootloader || { echo "ERROR: cannot reboot to bootloader"; exit 1; }
  sleep 3
fi

# Default to the current active slot if none given. On A/B, prefer _a as the
# known-good (matching init_boot/vendor_boot) slot for this device.
if [ -z "$SLOT" ]; then
  SLOT=$($FB getvar current-slot 2>/dev/null | tr -d '\r' | sed -n 's/.*current-slot: //p' | tr -d '_')
  SLOT="${SLOT:-a}"
fi

if [ "$SLOT" = "b" ]; then
  echo "WARNING: flashing the _b slot. On Ace 3 / Lunaris / stock OnePlus Android 16 the _b"
  echo "  init_boot/vendor_boot may be stale (do not match the 5.15.207 kernel) and a correct"
  echo "  kernel can bootloop. Only proceed if you have ALREADY flashed matching"
  echo "  init_boot+vendor_boot to _b, OR intend to overwrite the daily slot anyway."
  read -r -p "Type 'YES' to continue flashing _b: " ANS
  [ "$ANS" = "YES" ] || { echo "aborted"; exit 1; }
fi
SLOTARG="--slot $SLOT"

if [[ "$IMG" == *.zip ]]; then
  echo "ERROR: $IMG is an AnyKernel3 zip - fastboot cannot flash zips."
  echo "Flash it via custom recovery (OrangeFox/TWRP) or:  ksud install $IMG"
  exit 1
fi

echo "==> $FB $SLOTARG flash boot $IMG"
$FB $SLOTARG flash boot "$IMG" || { echo "ERROR: flash failed"; exit 1; }

# Helpful for A/B rollback if it fails to boot on a non-default slot.
if [ "$SLOT" = "a" ]; then
  echo "==> set active slot to _a (so a failed boot falls back to _b rather than looping)"
  $FB --slot b set_active b >/dev/null 2>&1 || true
  $FB --slot a set_active a
fi

echo "==> reboot"
$FB reboot

if [ "$VERIFY" = "1" ]; then
  echo "==> waiting for device to boot, then reading uname -r"
  sleep 20
  for i in $(seq 1 10); do
    if $ADB devices 2>/dev/null | grep -q "device$"; then break; fi
    sleep 5
  done
  UNR=$($ADB shell uname -r 2>/dev/null | tr -d '\r' | sed 's/[[:space:]].*//')
  echo "  device uname -r now: $UNR"
  echo "  Compare against the built banner; root shows via 'su -c id -Z' -> u:r:ksu:s0"
  echo "  after a compatible manager is installed and opened once."
fi

echo
echo "Then: install a compatible manager (Official KernelSU me.weishu.kernelsu is simplest),"
echo "open it once, and run verify_resukisu.sh."
echo
echo "Rollback if it fails to boot:"
echo "  fastboot flash boot <stock_boot.img>   (or)   fastboot set_active <other_slot>"
