#!/usr/bin/env bash
# Verify ReSukiSU status on a OnePlus device. Auto-detects state:
#   - If su works (ReSukiSU kernel already booted & manager crowned): full verification.
#   - If still no-root (pre-flash or stock): reports gathered uname/build info instead of failing.
# /proc/ksu may be ABSENT on ReSukiSU (normal) — verification relies on the u:r:ksu:s0 context.
#
# Usage: verify_resukisu.sh [<device-serial>]
# VERIFIED END-TO-END ONLY ON THE ONEPLUS ACE 3; logic is model-generic.
set -uo pipefail

SERIAL=""
[ "${1:-}" ] && SERIAL="$1"
ADB="adb"
[ -n "$SERIAL" ] && ADB="adb -s $SERIAL"

$ADB devices 2>/dev/null | grep -q "device$" || { echo "ERROR: no adb device online"; exit 1; }

echo "==> ReSukiSU verification (device: ${SERIAL:-default})"

# Try su; if it fails, we're still no-root (expected before/without a ReSukiSU kernel).
if $ADB shell su -c 'id -Z' >/dev/null 2>&1; then
  echo "  [state] device is ROOTED via su -> running full ReSukiSU check"
  pass=0; fail=0
  check(){ if [ "$2" = "0" ]; then echo "  [PASS] $1"; pass=$((pass+1)); else echo "  [FAIL] $1"; fail=$((fail+1)); fi; }

  CTX=$($ADB shell su -c 'id -Z' 2>/dev/null | tr -d '\r')
  if echo "$CTX" | grep -q "u:r:ksu:s0"; then check "su context is KSU ($CTX)" 0; else check "su context is KSU (got: $CTX)" 1; fi

  CR=$($ADB shell su -c 'dmesg 2>/dev/null | grep -i "Crowning manager"' 2>/dev/null | tr -d '\r' | head -1)
  if echo "$CR" | grep -qi "Crowning manager"; then check "Manager crowned ($CR)" 0; else check "Manager crowned (got: $CR)" 1; fi

  KV=$($ADB shell su -c '/data/adb/ksud --version 2>&1' 2>/dev/null | tr -d '\r' | head -1)
  if echo "$KV" | grep -q "ksud"; then check "ksud present ($KV)" 0; else check "ksud present (got: $KV)" 1; fi

  echo "==> Result: $pass passed, $fail failed"
  [ "$fail" = "0" ] && { echo "ReSukiSU OK"; exit 0; } || { echo "ReSukiSU issues detected"; exit 1; }
else
  echo "  [state] device is NOT rooted (su unavailable) -> reporting pre/ReSukiSU info only"
  echo "  (expected before flashing a ReSukiSU kernel, or on a clean stock device)"
  echo "  --- uname ---"; $ADB shell uname -a 2>/dev/null | tr -d '\r'
  echo "  --- build display id ---"; $ADB shell getprop ro.build.display.id 2>/dev/null | tr -d '\r'
  echo "  --- active slot ---"; $ADB shell getprop ro.boot.slot_suffix 2>/dev/null | tr -d '\r'
  echo "  Next: flash a ReSukiSU boot.img (or AK3 zip), install a compatible manager, then re-run this to verify root."
  exit 0
fi
