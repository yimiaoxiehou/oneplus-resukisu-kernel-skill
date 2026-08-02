---
name: oneplus-resukisu-kernel
description: >-
  Build, integrate, flash, and verify a ReSukiSU (KernelSU-family) rooted kernel for OnePlus
  devices. Use this skill when the user wants to compile or recompile a ReSukiSU kernel, integrate
  ReSukiSU into a OnePlus / Oplus GKI kernel source tree, or flash a ReSukiSU-enabled kernel to test
  it. Correct framing: start from a NO-ROOT device — gather kernel/device info with a non-root
  `adb shell` plus a manual Settings check, then sync the matching source tree (the kernel version
  MUST equal the device's running kernel), integrate ReSukiSU, compile with the prebuilt clang via a
  direct `make` flow, and flash via fastboot or a custom recovery to test. Root only becomes
  available AFTER the ReSukiSU kernel is flashed and a compatible manager (Official KernelSU
  `me.weishu.kernelsu`, RKSU, MKSU, or the ReSukiSU manager) is installed and opened once. Encodes
  the hard-won pitfalls: ReSukiSU is manager-agnostic, the kernel VERSION MUST match the device or
  it will not boot, LTO=thin is required when RAM < 24GB, and you must match the device's SoC
  platform AND the Android `_v_`/`_b_` line. NOTE: the concrete device values (manifest, branch,
  build layout, slot rules) were verified against the OnePlus Ace 3 (PJE110 / sm8550 / kernel
  5.15.207 / Android 16, running Lunaris-AOSP). The build path (sync + integrate + compile + pack)
  and the verify/flash tooling are scripted and validated; full flash+root requires a version-matched
  tree (see the version gate below).
---

# OnePlus — ReSukiSU Root Kernel Build & Flash (generic, no-root first)

Procedural knowledge for producing a working **ReSukiSU**-rooted OnePlus device, written around the
realistic starting point: a **stock, no-root OnePlus**. Device facts, the source-tree selection
rules, and pitfalls live in `references/oneplus_resukisu.md`; the reusable helpers live in
`scripts/`.

> ⚠️ **Tested-device disclaimer:** This skill is written to be OnePlus-GKI-generic (any Oplus GKI 2.0
> OnePlus that ships a `kernel_manifest` XML should follow the same principles), but the concrete
> device numbers (manifest `oneplus_ace3_b.xml`, branch `oneplus/sm8550`, build platform `waipio`,
> kernel `5.15.207`, model `PJE110`) come from the **OnePlus Ace 3 (global: OnePlus 12R)** running
> Lunaris-AOSP. For other OnePlus models, re-confirm the kernel version, manifest file, branch,
> `_v_`/`_b_` Android line, and A/B slot device paths before flashing.

## What is ReSukiSU

ReSukiSU is a **KernelSU-family** root solution — the `su` implementation lives in the kernel, not in
a boot ramdisk patch (no Magisk involved). Key facts that drive this skill:

- It is a **kernel** root (like KernelSU / KSU Next): a small kernel driver + a userspace manager.
- **Manager-agnostic**: a ReSukiSU kernel is "crowned" by, and works with, several managers —
  Official KernelSU (`me.weishu.kernelsu`), RKSU, MKSU, and the ReSukiSU manager. Install any
  compatible manager APK and open it once; the kernel crowns it and root becomes available. This is
  the main difference from KSU Next (`com.rifsxd.ksunext`).
- Integration is via a `setup.sh` (same pattern as KernelSU), plus defconfig flags.
- Supports **Manual Hook** and **SUSFS** modes; supports a wide kernel range (GKI and non-GKI).

## Mental model (important)

The realistic default flow, starting from a phone with NO root:

1. **Before flashing** — the device has NO root. Read partial info via a non-root `adb shell` and by
   manually opening **Settings → About phone**. You cannot use `su`.
2. **Sync the source tree** whose kernel version equals the device's `uname -r` exactly.
3. **Integrate ReSukiSU** into the GKI common tree (`setup.sh` + defconfig flags).
4. **Compile** the GKI `Image` with the prebuilt clang via a direct `make` flow (the WildKernels
   style, not the brittle oplus CI wrapper).
5. **Pack + flash** it (AnyKernel3 zip via recovery/`ksud`, or repacked `boot.img` via fastboot) and
   reboot into it.
6. **After it boots**, install a compatible manager (Official KernelSU `me.weishu.kernelsu` is the
   simplest), open it once, the kernel crowns it → root becomes available.

## Workflow

### 0. Prerequisites (host)

- Linux host with: `repo`, `git`, `curl`, `python3`, `bison`, `flex`, `bc`, `cpio`, `lz4`, `unzip`,
  `zip`, and enough disk (>= 60 GB free) and RAM. **If RAM < 24 GB you MUST build with `LTO=thin`**
  (the build script does this by default).
- For backup extraction: `payload-dumper-go` (`go install github.com/ssut/payload-dumper-go@latest`).
- `adb` + `fastboot`, bootloader unlocked.
- No system Clang needed — the OnePlus manifest tree ships its own prebuilt Clang under
  `kernel_platform/prebuilts/clang/...`; the build uses that toolchain.

### 1. Gather device / kernel info — NO ROOT required

```bash
bash scripts/gather_device_info.sh [<device-serial>] [--target-version 5.15.207]
```

Prints non-root `adb` values (model, codename, Android version, `uname -r`, active slot) plus a
manual **Settings → About phone** checklist. Use `--target-version` to immediately see whether the
device's running kernel matches what you intend to build.

> 🚨 **Gate — the source tree MUST equal the device's kernel version.** `uname -r` is the
> requirement; the manifest is only one way to satisfy it, and often the wrong one:
>
> | Device runs | Correct tree | Kernel |
> |---|---|---|
> | Stock OxygenOS | manifest `oneplus_ace3_b.xml` @ `oneplus/sm8550` | `5.15.180` |
> | Custom ROM (Lunaris-AOSP …) | the ROM's own kernel tree, e.g. `OnePlus12R-development/android_kernel_oneplus_sm8550` @ `sixteen-qpr2` | `5.15.207` |
>
> After syncing, `head -4 <tree>/Makefile` and confirm `SUBLEVEL` equals the device's. If it does
> not match, **stop** — a mismatched `UTS_RELEASE` makes every `vendor_dlkm` module refuse to load
> and the device will not boot. See "Source tree selection" in the reference.

### 2. Sync the source tree (version-matched)

The build script expects the **OnePlus manifest tree layout**:

```
<workdir>/kernel_platform/common        # GKI common tree (where ReSukiSU is integrated)
<workdir>/kernel_platform/prebuilts/... # prebuilt clang + kernel-build-tools
```

You can let the build script sync for you (with the version gate protecting you):

```bash
bash scripts/build_oneplus_resukisu.sh \
  --sync --branch oneplus/sm8550 --manifest oneplus_ace3_b.xml \
  --target-version 5.15.207        # gate: aborts if the synced tree is NOT 5.15.207
```

Or sync manually (commands in `references/oneplus_resukisu.md`), then run the build without `--sync`.
**If your device runs a custom ROM with a kernel the official manifest does not provide** (e.g.
5.15.207 on Lunaris-AOSP), the official manifest will NOT help — obtain that ROM's own kernel tree
and ensure it exposes the `kernel_platform/common` + `kernel_platform/prebuilts` layout (or adapt the
paths in the build script).

### 3. Integrate ReSukiSU + build (one automated script)

```bash
bash scripts/build_oneplus_resukisu.sh \
  --workdir $HOME/kernel-build \
  --target-version 5.15.207 \      # mandatory gate unless you pass --device-serial
  --hook manual            # or: susfs
```

What the script does:
- Optional `repo init`/`repo sync` (only with `--sync`).
- **Version gate**: parses `Makefile` `VERSION.PATCHLEVEL.SUBLEVEL` and refuses to build if it does
  not equal `--target-version` (or the auto-detected device `uname -r`).
- Auto-detects the prebuilt clang under `kernel_platform/prebuilts/clang/...`.
- Resets `common`, runs the ReSukiSU `setup.sh`, appends `CONFIG_KSU=y` to `gki_defconfig`
  (default GKI hook — no manual core-kernel patches needed), applies thinLTO + `-dirty`/scmversion
  neutralization, builds `Image`, and packs an **AnyKernel3 zip**.
- Prints the built `Linux version` banner — **compare it to `adb shell uname -r` before flashing.**

Manual integration reference (what the script automates):

```bash
cd <kernel-source-root>/kernel_platform/common
# 1) integrate ReSukiSU
curl -LSs "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh" | bash
# 2) enable in the GKI base defconfig (arch/arm64/configs/gki_defconfig):
#      CONFIG_KSU=y                       # default GKI hook; no manual patches needed
#      # CONFIG_KSU_MANUAL_HOOK=y         # only if you ALSO hand-apply core-kernel hook patches
# 3) build with the prebuilt clang (WildKernels-style direct make):
export PATH="<tree>/kernel_platform/prebuilts/clang/host/linux-x86/clang-*/bin:$PATH"
export ARCH=arm64 SUBARCH=arm64 LLVM=1 LLVM_IAS=1 LTO=thin
make O=out ARCH=arm64 LLVM=1 gki_defconfig
make O=out -j"$(nproc)" Image
```

Build with `CONFIG_KSU=y` (built-in) — this avoids the LKM `vermagic` trap entirely.

### 4. (Recommended) Back up the stock boot / vendor_boot

```bash
bash scripts/extract_stock_img.sh "<rom.zip>" ./stock-imgs -p boot -p vendor_boot
```

Keeps known-good images to `fastboot flash boot` back to stock if the custom kernel fails to boot.
(If you only have the running device and no OTA zip, skip this and rely on the other slot for
rollback.)

### 5. Flash

```bash
# RAM-test first (no flash) — validates kernel + ReSukiSU without touching partitions:
bash scripts/flash_kernel.sh [<device-serial>] <boot.img> --boot-test

# Flash for real (raw boot.img):
bash scripts/flash_kernel.sh [<device-serial>] <boot.img>

# AnyKernel3 zip -> custom recovery (OrangeFox/TWRP) or `ksud install <zip>`
# (fastboot cannot flash a zip):
ksud install ReSukiSU-Ace3.zip
```

On A/B, flashing the active slot's boot; if it fails to boot, restore the stock `boot.img` or
`fastboot set_active <other_slot>`.

> 🚨 **Ace 3 / Lunaris slot rule (verified):** do NOT `fastboot --slot b flash boot` + `set_active b`
> on this device — the `_b` slot's `init_boot`/`vendor_boot` are stale and a correct kernel
> bootloops. Use `fastboot boot <img>` (RAM test) first, then flash `_a` only. The flash script
> refuses `_b` unless you type `YES`.

### 6. Install & crown the manager (after the ReSukiSU kernel boots)

Install **Official KernelSU** (`me.weishu.kernelsu`) — or the ReSukiSU manager — as a normal APK,
open it once so the kernel crowns it:

```
dmesg: KernelSU: Crowning manager: me.weishu.kernelsu(uid=...)
```

### 7. Verify

```bash
bash scripts/verify_resukisu.sh [<device-serial>]
```

Auto-detects state: still no-root → reports pre-flash info; rooted → checks `su -c id -Z` →
`u:r:ksu:s0`, the Crowning line, and `/data/adb/ksud`.

### 8. Rollback

Keep a stock `boot.img` before flashing. Restore with `fastboot flash boot <stock_boot.img>` (or
`fastboot set_active <other_slot>`).

## Hard rules (do not violate)

- **Pin the kernel version, then prove it — twice.** (1) After sync: `head -4 <tree>/Makefile` must
  match `adb shell uname -r`. (2) After build, **before** packing:
  `strings -a <Image> | grep -m1 "Linux version"` must match `uname -r` exactly. The build script
  enforces (1) via its version gate and prints (2) before packing. Never trust the manifest name,
  the branch name, or build-script intent — a build shipped `5.15.180-ReSukiSU` for a `5.15.207`
  device precisely because only the intent was checked.
- **Pin the version string explicitly**, do not rely on scmversion:
  `CONFIG_LOCALVERSION="-ReSukiSU"` + `# CONFIG_LOCALVERSION_AUTO is not set` +
  the build script neutralizes `scripts/setlocalversion` so no `-dirty`/`+` is appended.
  Confirm via `out/include/generated/utsrelease.h` before the link step (the script prints it).
- ReSukiSU is a **KernelSU-family kernel root**; the default flow is **no-root → flash**; root
  appears only after the ReSukiSU kernel boots and a compatible manager is crowned.
- ReSukiSU is **manager-agnostic** — Official KernelSU, RKSU, MKSU, and the ReSukiSU manager all
  work. Do NOT assume a single fixed manager package is required.
- Prefer **built-in** `CONFIG_KSU=y`. If you ever build an LKM, its `vermagic` MUST equal the exact
  device kernel version (e.g. `5.15.207`); a mismatch bootloops / fails to load.
- **Do NOT enable `CONFIG_KSU_MANUAL_HOOK` unless you also hand-apply the core-kernel hook patches**
  (`ksu_handle_execveat` etc. into `fs/exec.c` / `kernel/cred.c`). Without them the build fails at
  `manual_hook_check.mk`. The **default GKI hook** (just `CONFIG_KSU=y`) works on GKI 2.0 with no
  extra patching — that is what this skill builds by default.
- **`LTO=thin` is mandatory when host RAM < 24 GB** (full LTO OOMs on the OnePlus GKI build).
- The OnePlus GKI build needs out-of-CI tweaks (disable `-dirty`/scmversion git checks) or the
  version drifts; `build_oneplus_resukisu.sh` applies them.
- **Match BOTH the SoC platform AND the Android `_v_`/`_b_` line** of the source to the device, or
  the built kernel will not boot.
- Verify by the `u:r:ksu:s0` SELinux context, not by presence of `/proc/ksu` (it may be absent on
  ReSukiSU).

## Ace 3 / Lunaris-AOSP slot & bootloop rules (verified 2026-08-01)

- **Do NOT `fastboot --slot b flash boot` + `set_active b` on this device.** The `_b` slot's
  `init_boot` / `vendor_boot` are stale (dtb / early-ramdisk do not match the `5.15.207` kernel),
  so even a correct custom boot image bootloops back to fastboot. (The `_a` slot is fine because
  its `init_boot`/`vendor_boot` already match.)
- **Verify a custom kernel with `fastboot boot <img>` (RAM test, no flash) first.** It boots once
  using the running slot's `init_boot`/`vendor_boot`, so it validates the kernel + ReSukiSU without
  touching any partition. Confirm `uname -r`, `su -c id -Z` → `u:r:ksu:s0`, and the Crowning dmesg.
- **To deploy ReSukiSU onto a slot for real**, flash `_a` (the slot whose `init_boot`/`vendor_boot`
  match), NOT `_b`. Doing so replaces the current daily kernel (KSU Next on `_a`) — only do this when
  the user explicitly agrees to overwrite the daily system. If `_b` must ever be used, first flash
  ROM-matched `init_boot` + `vendor_boot` to `_b` so its early userspace matches the kernel.
- `vbmeta` is a **single** (non-A/B) partition here; `fastboot --slot b flash vbmeta` errors with
  `vbmeta does not support slots`. AVB is already disabled (ROM `vbmeta Flags:3`), so unsigned custom
  boot images boot — the bootloop was an `init_boot`/`vendor_boot` mismatch, not AVB.

See `references/oneplus_resukisu.md` for the full device/manifest mapping, the exact build recipe,
SUSFS notes, and pitfalls.
