#!/usr/bin/env bash
# Build a ReSukiSU-rooted GKI kernel for an OnePlus device and pack it as an
# AnyKernel3 zip.
#
# SOURCE TREE LAYOUT (required): the OnePlus manifest tree
#   <workdir>/kernel_platform/common        (GKI common tree)
#   <workdir>/kernel_platform/prebuilts/... (prebuilt clang + kernel-build-tools)
# The build itself is the WildKernels-style direct `make` flow (clang + thinLTO),
# which avoids the brittle oplus CI wrapper and its out-of-CI assumptions.
#
# *** CRITICAL — VERSION GATE ***
# The built kernel version MUST equal the device's running kernel (e.g. 5.15.207).
# The official Ace 3 manifest (oneplus_ace3_b.xml) yields 5.15.180 — a mismatch
# makes every vendor_dlkm module refuse to load and the device WILL NOT BOOT.
# Pass --target-version (or --device-serial to auto-detect from uname -r); the
# script refuses to build when the tree version != target.
#
# Usage:
#   bash build_oneplus_resukisu.sh \
#       [--workdir $HOME/kernel-build] \
#       [--target-version 5.15.207] \      # gate: tree must match this
#       [--device-serial <serial>] \       # alt: auto-detect target from uname -r
#       [--sync --branch oneplus/sm8550 --manifest oneplus_ace3_b.xml] \
#       [--hook manual]            # manual | susfs
#       [--keep-opts]              # optional BBR/TTL/IPSET/NTSYNC patches
#       [--no-reset]               # do not git-clean common before integrate
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
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

KP="$WORKDIR/kernel_platform"
COMMON="$KP/common"
AK3="$WORKDIR/AnyKernel3"
OUT="$COMMON/out"
AK3_REPO="https://github.com/osm0sis/AnyKernel3.git"
LOG="$WORKDIR/ReSukiSU-build.log"
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

# ---------- version gate ----------
TREE_VER=$(awk '/^VERSION = /{v=$3} /^PATCHLEVEL = /{p=$3} /^SUBLEVEL = /{s=$3} END{print v"."p"."s}' "$COMMON/Makefile")
echo "  tree kernel version : $TREE_VER"

if [ -z "$TARGET_VERSION" ] && [ -n "$SERIAL" ]; then
  if command -v adb >/dev/null 2>&1 && $ADB devices 2>/dev/null | grep -q "device$"; then
    TARGET_VERSION=$($ADB shell uname -r 2>/dev/null | tr -d '\r' | sed 's/-.*//') || true
    echo "  auto target (device): $TARGET_VERSION"
  fi
fi

if [ -n "$TARGET_VERSION" ]; then
  if [ "$TREE_VER" != "$TARGET_VERSION" ]; then
    echo "ERROR: version gate FAILED — tree=$TREE_VER but target=$TARGET_VERSION"
    echo "The device runs $TARGET_VERSION. A $TREE_VER kernel will NOT boot"
    echo "(vendor_dlkm vermagic mismatch). Sync the correct source tree"
    echo "(see references/oneplus_resukisu.md, 'Source tree selection')."
    exit 1
  fi
  echo "  [OK] tree version matches target $TARGET_VERSION"
else
  echo "  [warn] no --target-version / --device-serial given — SKIPPING version gate."
  echo "  You MUST confirm $TREE_VER equals the device's 'uname -r' before flashing."
fi

# ---------- toolchain (auto-detect prebuilt clang) ----------
CLANG=$(ls -d "$KP"/prebuilts/clang/host/linux-x86/clang-* 2>/dev/null | head -1)/bin
BTOOLS="$KP/prebuilts/kernel-build-tools/linux-x86/bin"
[ -d "$CLANG" ] || { echo "ERROR: clang not found under $KP/prebuilts/clang"; exit 1; }
[ -d "$BTOOLS" ] || { echo "ERROR: kernel-build-tools not found under $KP/prebuilts"; exit 1; }

export PATH="$CLANG:$BTOOLS:$PATH"
export ARCH=arm64 SUBARCH=arm64
export LLVM=1 LLVM_IAS=1
export CROSS_COMPILE=aarch64-linux-gnu-
export LD=ld.lld HOSTLD=ld.lld AR=llvm-ar NM=llvm-nm
export OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip
export PAHOLE="$BTOOLS/pahole"
export CC="clang" CXX="clang++" HOSTCC="clang" HOSTCXX="clang++"
export KCFLAGS="-no-canonical-prefixes -fdiagnostics-color=never -Qunused-arguments -Wno-unused-command-line-argument -D__ANDROID_COMMON_KERNEL__"
export KCPPFLAGS=""
# thin LTO is mandatory on <24GB hosts; default to it.
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
# Default GKI syscall/tracepoint hook (works on GKI 2.0, no core-kernel patches).
# Manual Hook mode needs hand-applied ksu_handle_* patches — we don't apply those.
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
echo "==> [4] build kernel (clang + thinLTO)"
cd "$COMMON"
: > .scmversion
# ld-wrapper: force thinlto parallelism
cat > "$COMMON/ld-wrapper" <<'EOF'
#!/bin/bash
ld.lld "$@" --thinlto-jobs=$(nproc --all)
EOF
chmod +x "$COMMON/ld-wrapper"
export KBUILD_BUILD_USER=kernel
export KBUILD_BUILD_HOST=kleaf
export KBUILD_BUILD_VERSION=1
mkdir -p "$OUT"
make LD="$COMMON/ld-wrapper" HOSTLD="$COMMON/ld-wrapper" O="$OUT" gki_defconfig
scripts/config --file "$OUT/.config" --set-str LOCALVERSION "-ReSukiSU"
scripts/config --file "$OUT/.config" -d LOCALVERSION_AUTO || true
sed -i 's/scm_version="$(scm_version --short)"/scm_version=""/' scripts/setlocalversion
scripts/config --file "$OUT/.config" -e CC_OPTIMIZE_FOR_PERFORMANCE -d CC_OPTIMIZE_FOR_PERFORMANCE_O3
scripts/config --file "$OUT/.config" -e LTO_CLANG -d LTO_CLANG_NONE -d LTO_CLANG_THIN -d LTO_CLANG_FULL
scripts/config --file "$OUT/.config" -e LTO_CLANG_THIN
scripts/config --file "$OUT/.config" -d LTO_CLANG_FULL
# confirm utsrelease before linking
UTS=$(grep UTS_RELEASE "$OUT/include/generated/utsrelease.h" 2>/dev/null | tr -d '"#' | awk '{print $3}')
echo "  utsrelease: ${UTS:-<unknown>}"
make LD="$COMMON/ld-wrapper" HOSTLD="$COMMON/ld-wrapper" O="$OUT" -j"$(nproc)" KCFLAGS="$KCFLAGS" KCPPFLAGS="$KCPPFLAGS" Image 2>&1 | tee "$WORKDIR/build-run.log"

# ---------- 5. package ----------
echo "==> [5] locate Image + pack AnyKernel3"
IMAGE="$OUT/arch/arm64/boot/Image"
if [ ! -f "$IMAGE" ]; then
  echo "ERROR: build did not produce $IMAGE. Inspect $WORKDIR/build-run.log"
  exit 1
fi
# banner check before packing
BANNER=$(strings -a "$IMAGE" | grep -m1 "Linux version" || true)
echo "  built banner: $BANNER"
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
echo "Compare the banner above to 'adb shell uname -r' BEFORE flashing."
echo "Flash ReSukiSU-Ace3.zip via custom recovery (OrangeFox/TWRP) or ksud."
echo "Then install a compatible manager (e.g. Official KernelSU me.weishu.kernelsu) and open it once."
