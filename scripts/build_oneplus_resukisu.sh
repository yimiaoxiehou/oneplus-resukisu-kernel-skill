#!/usr/bin/env bash
# Build a ReSukiSU-rooted GKI kernel for an OnePlus device and pack it as an
# AnyKernel3 zip.
#
# SOURCE TREE LAYOUT (required): the OnePlus manifest tree
#   <workdir>/kernel_platform/common        (GKI common tree)
#   <workdir>/kernel_platform/prebuilts/... (prebuilt clang + kernel-build-tools)
# Direct `make` flow (clang + ThinLTO + kCFI), avoiding the brittle oplus CI wrapper.
#
# *** CRITICAL 1 — VERSION MUST MATCH THE DEVICE EXACTLY (INCLUDING -g<hash>-dirty) ***
# The built kernel version MUST equal the device's `uname -r` (e.g.
# 5.15.207-g80a299579459-dirty) INCLUDING the `-g<hash>` and `-dirty` suffix.
# A mismatch makes every vendor_dlkm module refuse to load and the device WILL NOT
# BOOT. The script auto-detects the exact string from the device and hard-pins it
# (CONFIG_LOCALVERSION = the exact suffix, LOCALVERSION_AUTO=n) so the banner can
# never drift. Do NOT use a vanity LOCALVERSION like "-ReSukiSU" — that produces
# 5.15.207-ReSukiSU which does NOT match and will not boot.
#
# *** CRITICAL 2 — TOOLCHAIN / CFI MUST MATCH THE VENDOR MODULES ***
# The device's vendor modules are built by the OEM with a specific clang + kCFI
# configuration. A kernel built with a DIFFERENT clang (e.g. the tree's prebuilt
# clang-14) and/or CFI disabled will "boot" but its modules fail to load (CFI
# type-hash / vermagic mismatch) and it silently falls back to the other slot.
# Fix: build with a modern real clang behind a *version-faking wrapper* that
# reports the OEM's exact `clang version ...` string (so mkcompile_h embeds a
# vermagic/version that matches the modules), and ENABLE kCFI
# (CONFIG_CFI_CLANG=y). The proven real compiler for Ace 3 / Lunaris / stock
# OnePlus Android 16 is Neutron clang-23 behind such a wrapper (OEM ROM string =
# Android clang 21.0.0 r563880c). The REAL compiler version only needs to emit a
# kCFI scheme compatible with the modules; clang-23 was verified working.
#
# Usage:
#   bash build_oneplus_resukisu.sh \
#       [--workdir $HOME/kernel-build] \
#       [--target-version 5.15.207-g80a299579459-dirty] \  # FULL uname -r; gate
#       [--device-serial <serial>] \                        # alt: auto-detect target + clang str
#       [--clang-real /path/to/clang] \                     # real compiler (exec'd by wrapper)
#       [--clang-version-string "clang version 21.0.0 (...)"] \ # override OEM clang string
#       [--sync --branch oneplus/sm8550 --manifest oneplus_ace3_b.xml] \
#       [--hook manual|susfs] [--keep-opts] [--no-reset]
set -euo pipefail

WORKDIR="$HOME/kernel-build"
HOOK="manual"
KEEP_OPTS=0
RESET=1
SYNC=0
BRANCH=""
MANIFEST=""
TARGET_VERSION=""
SERIAL=""
CLANG_REAL=""
CLANG_VERSION_STRING=""
WRAPPER_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --workdir) WORKDIR="$2"; shift 2 ;;
    --hook) HOOK="$2"; shift 2 ;;
    --keep-opts) KEEP_OPTS=1; shift ;;
    --no-reset) RESET=0; shift ;;
    --reset) RESET=1; shift ;;
    --sync) SYNC=1; shift ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --manifest) MANIFEST="$2"; shift 2 ;;
    --target-version) TARGET_VERSION="$2"; shift 2 ;;
    --device-serial) SERIAL="$2"; shift 2 ;;
    --clang-real) CLANG_REAL="$2"; shift 2 ;;
    --clang-version-string) CLANG_VERSION_STRING="$2"; shift 2 ;;
    --wrapper-dir) WRAPPER_DIR="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

KP="$WORKDIR/kernel_platform"
COMMON="$KP/common"
AK3="$WORKDIR/AnyKernel3"
OUT="$COMMON/out"
AK3_REPO="https://github.com/osm0sis/AnyKernel3.git"
LOG="$WORKDIR/ReSukiSU-build.log"
WRAPPER_DIR="${WRAPPER_DIR:-$WORKDIR/clang-wrappers}"
mkdir -p "$WORKDIR"
exec > >(tee -a "$LOG") 2>&1

ADB="adb"
[ -n "$SERIAL" ] && ADB="adb -s $SERIAL"

echo "============================================================"
echo " ReSukiSU build — OnePlus GKI (kernel_platform/common layout)"
echo " workdir : $WORKDIR"
echo " hook    : $HOOK   keep-opts: $KEEP_OPTS"
echo " target  : ${TARGET_VERSION:-<unset>}"
echo "============================================================"

# ---------- optional repo sync ----------
if [ "$SYNC" = "1" ]; then
  [ -n "$MANIFEST" ] && [ -n "$BRANCH" ] || { echo "ERROR: --sync requires --branch and --manifest"; exit 1; }
  if [ ! -d "$WORKDIR/.repo" ]; then
    mkdir -p "$WORKDIR"; cd "$WORKDIR"
    repo init -u https://github.com/OnePlusOSS/kernel_manifest.git -b "$BRANCH" -m "$MANIFEST" --depth=1
  fi
  cd "$WORKDIR"
  repo sync -c -j"$(nproc)" --no-clone-bundle --no-tags --force-sync
  echo "  NOTE: verify the synced version with: head -4 $COMMON/Makefile"
fi

[ -d "$COMMON" ] || { echo "ERROR: $COMMON missing — sync the OnePlus GKI source first (or use --sync)"; exit 1; }

# ---------- version gate (compare BASE version X.Y.Z) ----------
TREE_VER=$(awk '/^VERSION = /{v=$3} /^PATCHLEVEL = /{p=$3} /^SUBLEVEL = /{s=$3} END{print v"."p"."s}' "$COMMON/Makefile")
echo "  tree kernel base version : $TREE_VER"

# auto-detect full uname -r from device when possible
if [ -z "$TARGET_VERSION" ] && [ -n "$SERIAL" ]; then
  if command -v adb >/dev/null 2>&1 && $ADB devices 2>/dev/null | grep -q "device$"; then
    TARGET_VERSION=$($ADB shell uname -r 2>/dev/null | tr -d '\r' | sed 's/[[:space:]].*//')
    echo "  auto target (device): $TARGET_VERSION"
  fi
fi

if [ -n "$TARGET_VERSION" ]; then
  TARGET_BASE=$(echo "$TARGET_VERSION" | sed -E 's/-.*//')
  if [ "$TREE_VER" != "$TARGET_BASE" ]; then
    echo "ERROR: version gate FAILED — tree base=$TREE_VER but target base=$TARGET_BASE (full: $TARGET_VERSION)"
    echo "The device runs $TARGET_VERSION. A $TREE_VER kernel will NOT boot (vendor_dlkm vermagic mismatch)."
    echo "Sync the correct source tree (see references/oneplus_resukisu.md, 'Source tree selection')."
    exit 1
  fi
  echo "  [OK] tree base version matches target $TARGET_VERSION"
else
  echo "  [warn] no --target-version / --device-serial given — SKIPPING version gate."
  echo "  You MUST confirm $TREE_VER equals the device's 'uname -r' base before flashing."
fi

# ---------- toolchain: real clang + version-faking wrapper ----------
# Real compiler (exec'd). Prefer --clang-real, else auto-detect a modern clang.
if [ -z "$CLANG_REAL" ]; then
  # prefer a Neutron / recent clang already on disk; fall back to system clang
  CLANG_REAL=$(command -v clang-23 clang-22 clang-21 clang 2>/dev/null | head -1)
fi
[ -x "$CLANG_REAL" ] || { echo "ERROR: real clang not found (--clang-real)."; exit 1; }
echo "  real clang : $($CLANG_REAL --version | head -1)"

# OEM clang version string (faked by wrapper so vermagic/CFI-env matches modules)
if [ -z "$CLANG_VERSION_STRING" ] && [ -n "$SERIAL" ]; then
  if $ADB devices 2>/dev/null | grep -q "device$"; then
    CLANG_VERSION_STRING=$($ADB shell cat /proc/version 2>/dev/null | grep -oE "clang version [^,]+" | head -1)
    LLD_VERSION_STRING=$($ADB shell cat /proc/version 2>/dev/null | grep -oE "LLD [0-9.]+[^)]*\)" | head -1)
  fi
fi
[ -n "$CLANG_VERSION_STRING" ] || { echo "ERROR: cannot determine OEM clang version string; pass --clang-version-string (from 'adb shell cat /proc/version')."; exit 1; }
LLD_VERSION_STRING="${LLD_VERSION_STRING:-LLD 21.0.0}"
echo "  faked clang : $CLANG_VERSION_STRING"
echo "  faked lld   : $LLD_VERSION_STRING"

mkdir -p "$WRAPPER_DIR"
cat > "$WRAPPER_DIR/clang" <<EOF
#!/bin/sh
# Wrapper: real clang for compilation, but '--version'/'-v' return the OEM's
# exact clang string so mkcompile_h embeds a vermagic that matches vendor modules.
case " \$* " in
  *" --version "*|*" -v "*|*" --version"|"--version "*)
    echo "$CLANG_VERSION_STRING"
    exit 0
    ;;
esac
exec $CLANG_REAL "\$@"
EOF
cat > "$WRAPPER_DIR/ld.lld" <<EOF
#!/bin/sh
case " \$* " in
  *" --version "*|*" -v "*|*" --version"|"--version "*)
    echo "$LLD_VERSION_STRING"
    exit 0
    ;;
esac
exec $($CLANG_REAL --print-prog-name=ld.lld) "\$@"
EOF
chmod +x "$WRAPPER_DIR/clang" "$WRAPPER_DIR/ld.lld"
echo "  wrappers   : $WRAPPER_DIR/clang , $WRAPPER_DIR/ld.lld"

BTOOLS="$KP/prebuilts/kernel-build-tools/linux-x86/bin"
[ -d "$BTOOLS" ] || { echo "ERROR: kernel-build-tools not found under $KP/prebuilts"; exit 1; }
export PATH="$WRAPPER_DIR:$BTOOLS:$PATH"
export ARCH=arm64 SUBARCH=arm64
export LLVM=1 LLVM_IAS=1
export CROSS_COMPILE=aarch64-linux-gnu-
export LD=ld.lld HOSTLD=ld.lld AR=llvm-ar NM=llvm-nm
export OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip
export CC=clang CXX=clang++ HOSTCC=gcc HOSTCXX=g++
export KCFLAGS="-no-canonical-prefixes -fdiagnostics-color=never -Qunused-arguments -Wno-unused-command-line-argument -D__ANDROID_COMMON_KERNEL__"
export KCPPFLAGS=""
export KBUILD_BUILD_USER=build-user KBUILD_BUILD_HOST=build-host
# ThinLTO is mandatory on <24GB hosts; default to it.
export LTO=thin

# ---------- (optional) reset common to a clean synced state ----------
if [ "$RESET" = "1" ]; then
  echo "==> [0] reset common tree to clean synced state"
  git -C "$COMMON" checkout -f -- .
  git -C "$COMMON" clean -fdx
fi

# ---------- 1. integrate ReSukiSU ----------
echo "==> [1] integrate ReSukiSU into $COMMON"
cd "$COMMON"
if [ -d KernelSU ] || [ -d ReSukiSU ]; then
  echo "    (ReSukiSU dir already present — removing for a clean re-integrate)"
  rm -rf KernelSU ReSukiSU
fi
curl -LSs "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh" | bash

# ---------- 2. defconfig flags ----------
echo "==> [2] enable ReSukiSU in gki_defconfig"
DEF="$COMMON/arch/arm64/configs/gki_defconfig"
grep -q "CONFIG_KSU=y" "$DEF" || echo "CONFIG_KSU=y" >> "$DEF"
sed -i '/CONFIG_KSU_MANUAL_HOOK/d' "$DEF"
if [ "$HOOK" = "susfs" ]; then
  grep -q "CONFIG_KSU_SUSFS=y" "$DEF" || echo "CONFIG_KSU_SUSFS=y" >> "$DEF"
fi

# ---------- 3. optional optimization patches ----------
if [ "$KEEP_OPTS" = "1" ]; then
  echo "==> [3] apply optimization patches (BBR/TTL/IPSET/NTSYNC...)"
  KP_PATCHES="$KP/kernel_patches"
  [ -d "$KP_PATCHES" ] || git clone --depth 1 https://github.com/WildKernels/kernel_patches.git "$KP_PATCHES"
  cat >> "$DEF" <<'EOF'
CONFIG_TCP_CONG_ADVANCED=y
CONFIG_TCP_CONG_BBR=y
CONFIG_TCP_CONG_BBR3=y
CONFIG_NET_SCH_FQ=y
CONFIG_IP_NF_TARGET_TTL=y
CONFIG_IP6_NF_TARGET_HL=y
CONFIG_IP_SET=y
EOF
  patch -p1 < "$KP_PATCHES/common/bbrv3/0001-net-tcp-backport-BBRv3-to-android13-5.15.patch" || echo "BBRv3 patch non-fatal"
  patch -p1 < "$KP_PATCHES/common/ntsync/0001-ntsync.patch" || echo "ntsync patch non-fatal"
fi

# ---------- 4. build ----------
echo "==> [4] build kernel (clang wrapper + ThinLTO + kCFI)"
cd "$COMMON"
# vermagic = EXACT device uname -r suffix (incl -g<hash>-dirty); AUTO off
SUFFIX=""
if [ -n "$TARGET_VERSION" ]; then
  SUFFIX="-${TARGET_VERSION#*-}"   # keep everything after the first '-' (e.g. -g80a299579459-dirty)
fi
make O="$OUT" ARCH=arm64 LLVM=1 gki_defconfig
if [ -n "$SUFFIX" ]; then
  scripts/config --file "$OUT/.config" --set-str LOCALVERSION "$SUFFIX"
else
  scripts/config --file "$OUT/.config" --set-str LOCALVERSION ""
fi
scripts/config --file "$OUT/.config" -d LOCALVERSION_AUTO
sed -i 's/scm_version="$(scm_version --short)"/scm_version=""/' scripts/setlocalversion
# kCFI ON + ThinLTO (required to match the OEM's clang/CFI vendor modules)
scripts/config --file "$OUT/.config" -e CONFIG_CFI_CLANG
scripts/config --file "$OUT/.config" -e LTO_CLANG -d LTO_CLANG_NONE -d LTO_CLANG_FULL
scripts/config --file "$OUT/.config" -e LTO_CLANG_THIN
UTS=$(grep UTS_RELEASE "$OUT/include/generated/utsrelease.h" 2>/dev/null | tr -d '"#' | awk '{print $3}')
echo "  utsrelease: ${UTS:-<unknown>}"
make O="$OUT" -j"$(nproc)" KCFLAGS="$KCFLAGS" KCPPFLAGS="$KCPPFLAGS" Image 2>&1 | tee "$WORKDIR/build-run.log"

# ---------- 5. package ----------
echo "==> [5] locate Image + pack AnyKernel3"
IMAGE="$OUT/arch/arm64/boot/Image"
if [ ! -f "$IMAGE" ]; then
  echo "ERROR: build did not produce $IMAGE. Inspect $WORKDIR/build-run.log"
  exit 1
fi
BANNER=$(strings -a "$IMAGE" | grep -m1 "Linux version" || true)
echo "  built banner: $BANNER"
# banner MUST equal device uname -r exactly
if [ -n "$TARGET_VERSION" ]; then
  echo "$BANNER" | grep -q "$TARGET_VERSION" || { echo "ERROR: banner vermagic '$TARGET_VERSION' mismatch — abort (modules will not load)."; exit 1; }
  echo "  [OK] banner vermagic matches device uname -r"
fi
cp "$IMAGE" "$WORKDIR/Image_ReSukiSU"
echo "    Image: $WORKDIR/Image_ReSukiSU ($(du -h "$WORKDIR/Image_ReSukiSU" | cut -f1))"

if [ ! -d "$AK3/.git" ]; then
  rm -rf "$AK3"; git clone --depth 1 "$AK3_REPO" "$AK3"
fi
cp -f "$IMAGE" "$AK3/Image"
rm -f "$AK3"/*.dtb "$AK3"/dtb* 2>/dev/null || true
( cd "$AK3" && rm -f ../ReSukiSU-Ace3.zip && zip -r ../ReSukiSU-Ace3.zip . -x '.git/*' )
echo
echo "============================================================"
echo " DONE."
echo "   Flashable AK3 : $WORKDIR/ReSukiSU-Ace3.zip"
echo "   Raw Image     : $WORKDIR/Image_ReSukiSU"
echo "   Built banner  : $BANNER"
echo "============================================================"
echo "The banner above MUST equal 'adb shell uname -r' exactly (incl -dirty)."
echo "Flash ReSukiSU-Ace3.zip via custom recovery (OrangeFox/TWRP) or ksud, or"
echo "repack into boot.img and 'fastboot flash boot_a' (keep _b as fallback)."
echo "Then install a compatible manager (e.g. Official KernelSU me.weishu.kernelsu) and open it once."
