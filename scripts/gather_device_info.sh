#!/usr/bin/env bash
# Gather non-root device / kernel info for an OnePlus device. No root required.
# Prints adb-readable values + a manual "Settings -> About phone" checklist.
# Optionally compares the device's running kernel to a target version.
# Works on any OnePlus (generic); VERIFIED END-TO-END ONLY ON THE ONEPLUS ACE 3.
#
# Usage:
#   bash gather_device_info.sh [<device-serial>] [--target-version 5.15.207]
set -uo pipefail

SERIAL=""
TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --target-version) TARGET="$2"; shift 2 ;;
    *) SERIAL="${1:-}"; shift ;;
  esac
done

ADB="adb"
[ -n "$SERIAL" ] && ADB="adb -s $SERIAL"

if ! $ADB devices 2>/dev/null | grep -q "device$"; then
  echo "ERROR: no adb device online (serial=${SERIAL:-default})"
  exit 1
fi

echo "============================================================"
echo " OnePlus device info (non-root)"
echo "============================================================"
echo "  model            : $($ADB shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
echo "  device           : $($ADB shell getprop ro.product.device 2>/dev/null | tr -d '\r')"
echo "  codename         : $($ADB shell getprop ro.product.vendor.device 2>/dev/null | tr -d '\r')"
echo "  Android          : $($ADB shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')"
echo "  build id         : $($ADB shell getprop ro.build.display.id 2>/dev/null | tr -d '\r')"
echo "  kernel (uname -r): $($ADB shell uname -r 2>/dev/null | tr -d '\r')"
echo "  uname -a         : $($ADB shell uname -a 2>/dev/null | tr -d '\r')"
echo "  active slot      : $($ADB shell getprop ro.boot.slot_suffix 2>/dev/null | tr -d '\r')"
echo "  bootloader       : $($ADB shell getprop ro.bootloader 2>/dev/null | tr -d '\r')"

RUNNING=$($ADB shell uname -r 2>/dev/null | tr -d '\r' | sed 's/-.*//')
echo
echo "  >>> running kernel base version: $RUNNING"

if [ -n "$TARGET" ]; then
  if [ "$RUNNING" = "$TARGET" ]; then
    echo "  [OK] device kernel ($RUNNING) matches target ($TARGET)"
  else
    echo "  [MISMATCH] device kernel ($RUNNING) != target ($TARGET) -> you MUST sync a $TARGET source tree"
  fi
fi

echo
echo "------------------------------------------------------------"
echo " Manual checklist (Settings -> About phone) — confirm these:"
echo "   - Model number  (e.g. PJE110 / OP5CF9L1)"
echo "   - Android version (e.g. 16)"
echo "   - Kernel version string (must equal the source tree you sync)"
echo "   - Build number"
echo "------------------------------------------------------------"
echo
echo "Next: pick the source tree whose kernel version == $RUNNING"
echo "      (see references/oneplus_resukisu.md, 'Source tree selection')."
