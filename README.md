# oneplus-resukisu-kernel-skill

A WorkBuddy / Agent skill that builds, flashes, and verifies a **ReSukiSU** (KernelSU-family)
rooted kernel for OnePlus devices, starting from a **no-root** phone.

It encodes the hard-won lessons from getting ReSukiSU working on the **OnePlus Ace 3**
(`PJE110` / `sm8550` / kernel `5.15.207` / Android 16, running Lunaris-AOSP):

- The kernel **version MUST match the device's running kernel** or the device will not boot
  (vendor_dlkm `vermagic` mismatch). The build script enforces a **version gate** that aborts the
  build on a mismatch.
- ReSukiSU is **manager-agnostic** (Official KernelSU / RKSU / MKSU / ReSukiSU manager all work).
- `LTO=thin` is mandatory when host RAM < 24 GB.
- Match the SoC platform **and** the Android `_v_`/`_b_` line.

## Layout

This repo *is* the skill — drop it into your skills directory:

```bash
# WorkBuddy (user-level):
cp -r oneplus-resukisu-kernel-skill ~/.workbuddy/skills/oneplus-resukisu-kernel
# or symlink it
ln -s "$PWD" ~/.workbuddy/skills/oneplus-resukisu-kernel
```

```
oneplus-resukisu-kernel/
├── SKILL.md                       # procedural workflow (the entry point)
├── references/
│   └── oneplus_resukisu.md        # device/manifest mapping, build recipe, pitfalls
└── scripts/
    ├── gather_device_info.sh      # non-root device/kernel info (+ version check)
    ├── build_oneplus_resukisu.sh  # integrate + build + pack (version gate, thinLTO)
    ├── extract_stock_img.sh       # backup stock boot/vendor_boot from OTA zip
    ├── flash_kernel.sh            # fastboot flash / boot-test, slot-safe
    └── verify_resukisu.sh         # verify root / crowning state
```

## Quick start

```bash
# 1. gather info (no root needed)
bash scripts/gather_device_info.sh <serial> --target-version 5.15.207

# 2. build (sync + integrate + compile + pack, with version gate)
bash scripts/build_oneplus_resukisu.sh \
  --workdir "$HOME/kernel-build" \
  --target-version 5.15.207 \
  --hook manual

# 3. RAM-test before flashing (no partition touched)
bash scripts/flash_kernel.sh <serial> "$HOME/kernel-build/Image_ReSukiSU" --boot-test

# 4. flash for real (raw boot.img) — or ksud install ReSukiSU-Ace3.zip
bash scripts/flash_kernel.sh <serial> "$HOME/kernel-build/Image_ReSukiSU"

# 5. install a manager (e.g. Official KernelSU me.weishu.kernelsu) and open it once

# 6. verify
bash scripts/verify_resukisu.sh <serial>
```

> ⚠️ Read `SKILL.md` and `references/oneplus_resukisu.md` before running anything. The single most
> expensive mistake is building from a source tree whose kernel version ≠ the device's `uname -r`.

## License

MIT — see [LICENSE](LICENSE).
