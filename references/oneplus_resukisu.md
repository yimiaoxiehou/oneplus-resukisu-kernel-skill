# OnePlus + ReSukiSU — Verified Fact Sheet (OnePlus GKI generic, Ace 3 tested)

> ⚠️ **Tested-device disclaimer.** Written to be OnePlus-GKI-generic, but every concrete value
> below (manifest, branch, kernel version, model, build layout) was confirmed against the
> **OnePlus Ace 3 (PJE110 / OP5CF9L1 / sm8550 / kernel 5.15.207 / Android 16, running
> Lunaris-AOSP)**. Other OnePlus models must have their manifest, branch, kernel version, and slot
> device paths re-confirmed before flashing.

## What ReSukiSU is

- A **KernelSU-family** root solution: the `su` implementation lives in the kernel, not in a
  boot-ramdisk patch (no Magisk involved). Repo: <https://github.com/ReSukiSU/ReSukiSU>.
  Docs: <https://resukisu.github.io/zh-Hans/>.
- Supports **GKI and non-GKI**, down to kernel **3.4** (SUSFS backport only 4.3+).
- **Manager-agnostic**: a ReSukiSU kernel is "crowned" by — and works with — several managers,
  including Official KernelSU (`me.weishu.kernelsu`), RKSU, MKSU, and the ReSukiSU manager.
  Install any compatible manager APK and open it once; the kernel crowns it and root becomes
  available. (This is the main behavioral difference from KSU Next, which is locked to
  `com.rifsxd.ksunext`.)
- Hook modes: **Manual Hook** (`CONFIG_KSU_MANUAL_HOOK=y`) and **SUSFS** (`CONFIG_KSU_SUSFS=y`,
  plus the SUSFS kernel-side patch). SUSFS Inline Hook is provided by the SUSFS project.

## Integration (setup.sh)

Run from the **GKI common** source root (`kernel_platform/common`); the script drops a KernelSU-style
driver dir and wires it into the build:

```bash
cd kernel_platform/common
curl -LSs "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh" | bash
```

Then add to the GKI base defconfig (`kernel_platform/common/arch/arm64/configs/gki_defconfig`):

```
# Default GKI hook mode (recommended — no manual core-kernel patches needed)
CONFIG_KSU=y
# CONFIG_KSU_MANUAL_HOOK=y   # only if you ALSO hand-apply the core-kernel hook patches
```

or, for SUSFS mode (also apply the SUSFS kernel patch matching your kernel version/branch):

```
# SUSFS mode
CONFIG_KSU=y
CONFIG_KSU_SUSFS=y
```

`CONFIG_KSU=y` enables (built-in). Built-in avoids the LKM `vermagic` trap entirely — prefer it.

## Source tree selection — stock OOS vs custom ROM (DO THIS FIRST)

The single most expensive mistake in this workflow is syncing a source tree whose kernel version
does not equal the version the device is actually running. **The device's running kernel version is
the requirement; the manifest is only one possible way to satisfy it.**

Why it is fatal, not cosmetic: on GKI 2.0 the vendor modules in `vendor_dlkm` / `vendor_boot` are
pre-built against a specific `vermagic` (which embeds `UTS_RELEASE`). Flash a kernel whose
`UTS_RELEASE` differs and **every vendor module refuses to load → the device does not boot.**

Decision procedure:

1. `adb shell uname -r` → the exact target, e.g. `5.15.207-g80a299579459`.
2. Determine what the device is running:
   - **Stock OxygenOS** → use the OnePlus manifest (next section).
   - **Custom ROM** (Lunaris-AOSP, crDroid, ...) → the ROM ships its **own** kernel tree, which is
     usually newer than OnePlus's. You MUST build from *that* tree, not the manifest.
3. After sync, **verify before building** (this is the check that was missing):

```bash
head -4 <tree>/Makefile        # VERSION / PATCHLEVEL / SUBLEVEL must equal the device's
git -C <tree> log --oneline -1 # short SHA should match the -g<sha> suffix on the device
```

If `SUBLEVEL` does not match the device, **stop** — do not build.

### Verified mapping for the Ace 3 (`fc10d23c`)

| Device is running | Source tree | Kernel |
|---|---|---|
| Stock OxygenOS | `OnePlusOSS/kernel_manifest` @ `oneplus/sm8550`, `oneplus_ace3_b.xml` | `5.15.180` |
| **Lunaris-AOSP (this device)** | **`OnePlus12R-development/android_kernel_oneplus_sm8550` @ `sixteen-qpr2`** | **`5.15.207` @ `80a299579`** |

> The custom-ROM tree for 5.15.207 is a plain kernel tree in the `OnePlus12R-development` repo.
> `build_oneplus_resukisu.sh` expects the **`kernel_platform/common` + `kernel_platform/prebuilts`
> layout** that the official OnePlus manifest provides. If your 5.15.207 source does not expose that
> layout, either (a) arrange the tree so `kernel_platform/common` and
> `kernel_platform/prebuilts/{clang,kernel-build-tools}` exist, or (b) adapt the `KP`/`CLANG`/`BTOOLS`
> paths in the script. The version gate protects you either way: build aborts if `Makefile` SUBLEVEL
> ≠ `--target-version`.

### Pinning the version string (mandatory)

Do not rely on `CONFIG_LOCALVERSION_AUTO` — a locally patched tree is `dirty`, which appends
`-dirty` and breaks the match. Pin it explicitly:

```
# in .config
CONFIG_LOCALVERSION="-ReSukiSU"       # fixed tag; the -g<sha> suffix is dropped
# CONFIG_LOCALVERSION_AUTO is not set
```

`build_oneplus_resukisu.sh` does this via `scripts/config` and additionally neutralizes
`scripts/setlocalversion` (replacing the `scm_version` body with empty) so no `-dirty` or bare `+`
is appended. Confirm **before** linking:

```bash
cat out/include/generated/utsrelease.h   # -> #define UTS_RELEASE "5.15.207-ReSukiSU"
```

Then confirm the **built artifact** banner before packing:

```bash
strings -a out/arch/arm64/boot/Image | grep -m1 "Linux version"
# must equal adb shell uname -r (modulo the -ReSukiSU tag)
```

## OnePlus GKI source: manifest + branch mapping

OnePlus publishes a `repo` manifest per SoC family:
`https://github.com/OnePlusOSS/kernel_manifest` (branch = `oneplus/<platform>`), with a per-device
manifest XML inside. The XML pins:
- `android_kernel_common_oneplus_<plat>`  → `kernel_platform/common`  (GKI/ACK)
- `android_kernel_oneplus_<plat>`         → `kernel_platform/msm-kernel`
- `android_kernel_modules_and_devicetree_oneplus_<plat>` → `./` (device trees + vendor modules)
- prebuilt clang / build-tools / bazel from clo-la (`git.codelinaro.org/clo/la`)

There are usually two Android lines per device: a `_v_` line (older Android) and a `_b_` line
(newer Android). **Pick the line matching the device's running Android version** so the kernel
matches the vendor partition.

### Verified: OnePlus Ace 3 (this device, `fc10d23c`)

| Field | Value |
|---|---|
| Model | `PJE110` (global: OnePlus 12R) |
| Codename (`ro.product.device`) | `OP5CF9L1` |
| SoC / platform | Snapdragon 8 Gen 2 → `sm8550` (codename `waipio`) |
| Android | 16 |
| Kernel | `5.15.207-g80a299579459` (GKI 2.0) |
| Active slot | `_a` |
| Manifest branch | `oneplus/sm8550` |
| Manifest file | `oneplus_ace3_b.xml`  (the `_b_` = Android 16 line) |
| **Kernel version this manifest actually yields** | **`5.15.180`** — NOT 5.15.207 (see below) |

> 🚨 **STOP — read "Source tree selection" above before running `repo init`.** The official
> OnePlus manifest above produces a **5.15.180** tree. It matches a device running **stock
> OxygenOS**. It does **NOT** match this device, which runs Lunaris-AOSP with kernel
> **5.15.207**. Building from the manifest for a 5.15.207 device yields an unflashable kernel
> (the build script's version gate will refuse to build it when `--target-version 5.15.207`).

`repo init` (only use this for a stock-OOS / 5.15.180 device):

```bash
repo init -u https://github.com/OnePlusOSS/kernel_manifest.git \
  -b oneplus/sm8550 -m oneplus_ace3_b.xml --depth=1
repo sync -c -j"$(nproc)" --no-clone-bundle --no-tags --force-sync
```

> Other families: sm8750 (SD 8 Elite, kernel 6.6), sm8650 (SD 8 Gen 3), sm8550 (SD 8 Gen 2),
> etc. — pick the branch matching the device's kernel version, then the device's manifest XML.
> List available XMLs: `git ls-tree --name-only -r origin/oneplus/<platform>` on the manifest repo.

## Build recipe (direct `make` flow — what `build_oneplus_resukisu.sh` does)

The skill does **NOT** use the oplus CI wrapper (`oplus_build_kernel.sh`). Instead it builds the GKI
`Image` with a direct `make` invocation using the manifest tree's **prebuilt clang** — this sidesteps
the wrapper's brittle out-of-CI assumptions (strict `check_defconfig`, KMI/ABI monitoring, forced
`-dirty` scmversion). The tree still ships its own toolchain under `kernel_platform/prebuilts/`,
so no system Clang is needed.

```bash
cd <workdir>/kernel_platform/common
export PATH="$PWD/../prebuilts/clang/host/linux-x86/clang-*/bin:$PATH"
export PATH="$PWD/../prebuilts/kernel-build-tools/linux-x86/bin:$PATH"
export ARCH=arm64 SUBARCH=arm64 LLVM=1 LLVM_IAS=1
export CROSS_COMPILE=aarch64-linux-gnu- LTO=thin
# neutralize -dirty / scmversion (the script does this automatically):
sed -i 's/scm_version="$(scm_version --short)"/scm_version=""/' scripts/setlocalversion
make O=out ARCH=arm64 LLVM=1 gki_defconfig
scripts/config --file out/.config --set-str LOCALVERSION "-ReSukiSU"
scripts/config --file out/.config -d LOCALVERSION_AUTO
make O=out -j"$(nproc)" Image
```

Output `Image` lands at `<workdir>/kernel_platform/common/out/arch/arm64/boot/Image`.

### Why thinLTO / memory

- **Full LTO needs ~24 GB+ RAM**; on less, the linker OOMs. Use `LTO=thin` (the script sets it by
  default). Thin LTO builds fine on ~16 GB + swap.
- Use `ccache` to speed up re-builds if available.

### Out-of-CI tweaks (REQUIRED, else the version drifts)

When building locally you must stop `-dirty` / scmversion stamping. Local edits make
`scripts/setlocalversion` append `-dirty`, flipping the version off `5.15.207`. `build_oneplus_resukisu.sh`
neutralizes `setlocalversion` and pins `LOCALVERSION` so the banner stays exactly
`5.15.207-ReSukiSU`. (When using the oplus wrapper instead, you would additionally need to disable
`check_defconfig` / KMI `ABI_DEFINITION` / `TRIM_NONLISTED_KMI` and strip `-Werror` — but this skill
uses the direct-make flow, which avoids those.)

## Pack & flash

### Option A — AnyKernel3 zip (recommended, recovery or ksud)
Clone the AnyKernel3 template, drop `Image` into it, zip. Flash via custom recovery (OrangeFox/
TWRP) or `ksud`. AK3 only swaps the kernel in `boot`, leaving `vendor_boot` (dtb/mods) intact.

### Option B — repack boot.img for fastboot
Pull the **stock** `boot.img` (from an OTA `payload.bin`, or `adb pull` if rooted), unpack with
`magiskboot`/`unmkbootimg`, replace `kernel`/`Image` with the built one, repack, then
`fastboot flash boot boot.img`. Keep the stock `boot.img` for rollback.

### Stock image extraction (from OTA payload, for backup)

```bash
unzip -o "<rom.zip>" payload.bin -d <workdir>
payload-dumper-go -p boot -o <workdir>/out <workdir>/payload.bin   # -> boot.img
```

`scripts/extract_stock_img.sh` wraps this.

## Manager & crowning (after the ReSukiSU kernel boots)

Install **any compatible manager** (Official KernelSU `me.weishu.kernelsu` is the simplest choice,
or the ReSukiSU manager) as a normal APK and open it once:

```
dmesg: KernelSU: Crowning manager: <manager-package>(uid=...)
```

The manager installs its `ksud` into `/data/adb/ksud` on first boot after crowning.

## Verification (PASS criteria, after the kernel boots)

- `adb shell su -c 'id -Z'` → `u:r:ksu:s0`.
- `dmesg | grep "Crowning manager"` → the crowned manager package.
- `/data/adb/ksud` present.
- `/proc/ksu` may be **absent** — do not treat its absence as failure; rely on the SELinux context.

## Pitfalls (learned)

- **[2026-08-01] The manifest tree is 5.15.180, not 5.15.207.** A build was completed and packed
  before anyone checked the banner: it was `5.15.180-ReSukiSU` while the device ran `5.15.207`. Root
  cause: `repo sync` of `oneplus_ace3_b.xml` lands on `oneplus/sm8550_b_16.0.0_ace_3` = **5.15.180**,
  and the build log's "up to date with origin/main" was mistaken for a successful checkout of
  5.15.207. **Never infer the kernel version from the manifest name or from build intent — read
  `Makefile` and the built `Image` banner.** `build_oneplus_resukisu.sh` now enforces a version gate
  so this class of bug aborts the build instead of shipping a wrong-version Image.
- **[2026-08-01] Verify the banner of the artifact, not of the source.** One command closes this
  whole class of bug: `strings -a <Image> | grep -m1 "Linux version"` — compare it to
  `adb shell uname -r` **before** packing the AK3 zip.
- **[2026-08-01] `CONFIG_LOCALVERSION_AUTO=n` alone appends `+`.** `scripts/setlocalversion` only
  skips the `+` when the `LOCALVERSION` env var is *set* (an empty value counts). The script pins via
  `scripts/config --set-str LOCALVERSION` and neutralizes `setlocalversion`, so neither `-dirty`
  nor `+` appears.
- **[2026-08-01] pershoot/KernelSU-Next and ReSukiSU are drop-in interchangeable** on this tree:
  identical driver layout (`core/ feature/ hook/ infra/ manager/ policy/ runtime/ selinux/ sulog/
  supercall/`) and identical `CONFIG_KSU_SUSFS_*` option names. Switching variants is just
  re-running `setup.sh` from the other project — no need to re-patch the tree.
- **[2026-08-01] ReSukiSU tag `v4.1.0` has no SUSFS Kconfig**; the "SUSFS Inline Hook" option only
  exists on `main`. If the tree carries SUSFS kernel-side patches, build ReSukiSU from `main`,
  otherwise `CONFIG_KSU_SUSFS` silently disappears and the SUSFS features are lost.
- **ReSukiSU `main` hook mode is a `choice`** (`KSU_TRACEPOINT_HOOK` default / `KSU_MANUAL_HOOK` /
  `KSU_SUSFS`) — the three are mutually exclusive. Picking `KSU_SUSFS` requires the SUSFS
  kernel-side hooks to already exist; `kernel/tools/inline_hook_check.mk` lists exactly which
  (`ksu_handle_setresuid`, `ksu_handle_execveat`, `ksu_handle_faccessat`, `ksu_handle_sys_read`,
  `ksu_handle_stat`, `ksu_handle_sys_reboot`, `ksu_handle_input_handle_event`). Grep for them
  before configuring instead of discovering it at build time.
- **Manager mismatch is NOT fatal** (unlike KSU Next): ReSukiSU accepts multiple managers, so if one
  doesn't crown, try another (Official KSU / RKSU / MKSU / ReSukiSU manager) before assuming a
  kernel problem.
- **LTO OOM**: forgetting `LTO=thin` on a <24 GB host is the #1 cause of a failed link.
- **`-dirty` / wrong scmversion**: an appended `-dirty` or mismatched version can break manager
  version matching; pin the version (the script does).
- **KMI / check_defconfig** (oplus-wrapper path only): adding `CONFIG_KSU*` fails ABI checks unless
  they're disabled for the local build. The direct-make flow used by this skill avoids this.
- **Wrong branch / wrong `_v_` vs `_b_` line**: syncing sm8650 source for an sm8550 device — or the
  wrong Android line — produces a non-booting kernel. Match the kernel version AND the Android line
  first.

## Key paths (host layout; adjust per user)

- Build workdir: `$HOME/kernel-build/`
- Source root after sync: `<workdir>/kernel_platform/` (contains `common/`, `prebuilts/`, ...)
- Output Image: `<workdir>/kernel_platform/common/out/arch/arm64/boot/Image`
- Packed AK3 zip: `<workdir>/ReSukiSU-Ace3.zip`
- Raw Image copy: `<workdir>/Image_ReSukiSU`
- Backups: `<workdir>/stock-imgs/` (via `extract_stock_img.sh`)
