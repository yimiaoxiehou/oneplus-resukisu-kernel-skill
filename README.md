# oneplus-resukisu-kernel-skill

A WorkBuddy / Agent skill that builds, flashes, and verifies a **ReSukiSU** (KernelSU-family)
rooted kernel for OnePlus devices, starting from a **no-root** phone.

No Magisk is involved at any point.

## What it does

- **Gather info without root**: `gather_device_info.sh` prints `adb` (non-root) values and a manual
  Settings checklist to pick the right source tree / defconfig / `LOCALVERSION`.
- Integrates ReSukiSU into a OnePlus / Oplus kernel source tree (`setup.sh` + `CONFIG_KSU=y`).
- **Builds** the GKI `Image` with the prebuilt clang (direct `make` flow) and packs an AnyKernel3
  zip (`build_oneplus_resukisu.sh`, with a **version gate** so a mismatched kernel never ships).
- Extracts a stock `boot.img` / `vendor_boot.img` from the OTA `payload.bin` for a safe rollback
  (`extract_stock_img.sh`).
- Flashes via fastboot (`flash_kernel.sh`) or AnyKernel3/`ksud`; includes a `_b`-slot guard and a
  `fastboot boot` RAM-test mode for the Ace 3 / Lunaris-AOSP slot quirks.
- Registers a **compatible manager** — ReSukiSU is **manager-agnostic**: Official KernelSU
  (`me.weishu.kernelsu`), RKSU, MKSU, or the ReSukiSU manager all work (unlike KSU Next, which is
  locked to `com.rifsxd.ksunext`).
- Verifies ReSukiSU root via the `u:r:ksu:s0` SELinux context (`verify_resukisu.sh`, handles no-root
  gracefully; `/proc/ksu` may be absent — that is normal).

## Included files

| Path | Purpose |
|---|---|
| `SKILL.md` | Main workflow + hard rules for the agent |
| `references/oneplus_resukisu.md` | Verified fact sheet (Ace 3 source of truth) + pitfalls |
| `scripts/gather_device_info.sh` | No-root device/kernel info gathering (+ version check) |
| `scripts/build_oneplus_resukisu.sh` | Integrate + build + pack (version gate, thinLTO) |
| `scripts/extract_stock_img.sh` | Extract stock boot/vendor_boot from OTA `payload.bin` (rollback backup) |
| `scripts/flash_kernel.sh` | `fastboot flash boot` / `fastboot boot` (slot-safe) |
| `scripts/verify_resukisu.sh` | Verify ReSukiSU status (handles no-root gracefully) |

## Quick start (agent-facing)

```bash
# 1. Gather device info WITHOUT root (adb + manual Settings)
bash scripts/gather_device_info.sh [<serial>] --target-version 5.15.207

# 2. Build (sync optional) — version gate aborts if tree != device kernel
bash scripts/build_oneplus_resukisu.sh --workdir "$HOME/kernel-build" --target-version 5.15.207

# 3. (optional) Back up stock boot image from the OTA zip for rollback
bash scripts/extract_stock_img.sh "<rom.zip>" [out] -p boot -p vendor_boot

# 4. RAM-test first (no flash), then flash for real (raw boot.img)
bash scripts/flash_kernel.sh [<serial>] "$HOME/kernel-build/Image_ReSukiSU" --boot-test
bash scripts/flash_kernel.sh [<serial>] "$HOME/kernel-build/Image_ReSukiSU"

# 5. Install a compatible manager (e.g. Official KernelSU me.weishu.kernelsu), open it once

# 6. Verify
bash scripts/verify_resukisu.sh [<serial>]
```

## Hard rules (do not violate)

- The built kernel **version MUST equal the device's `uname -r`** or it will not boot
  (vendor_dlkm `vermagic` mismatch). `build_oneplus_resukisu.sh` enforces this with a version gate.
- ReSukiSU is **manager-agnostic** — Official KernelSU, RKSU, MKSU, and the ReSukiSU manager all
  work. (This is the key difference from KSU Next, which is locked to `com.rifsxd.ksunext`.)
- Default flow is **no-root → flash**; root appears only after the ReSukiSU kernel boots and a
  manager is installed and opened once.
- Verify by `u:r:ksu:s0` context, **not** by presence of `/proc/ksu`.
- `LTO=thin` is mandatory when host RAM < 24 GB.
- On Ace 3 / Lunaris-AOSP, do NOT flash the `_b` slot (stale init_boot/vendor_boot) — use
  `fastboot boot` (RAM test) first, then flash `_a`.
- **Only the OnePlus Ace 3 has been verified end-to-end.**

## License

MIT — use freely, but if it bricks your untested OnePlus, that's on you. 🫠
