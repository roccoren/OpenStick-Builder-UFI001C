# GitHub Actions build: UFI001C Hybrid Debian 13

This repository now includes a GitHub Actions workflow for building a **UFI001C hybrid Debian 13 (Trixie)** image bundle.

## Workflow file
- `.github/workflows/build-hybrid.yml`

## Build script
- `scripts/build_hybrid_bundle.sh`

## What the workflow produces
A ZIP bundle containing:
- `boot.bin`
- `rootfs.bin`
  - On some Windows fastboot builds, flash `rootfs.bin` with `fastboot -S 128M flash rootfs rootfs.bin`
- `gpt_both0.bin`
- `aboot.bin`
- `hyp.mbn`
- `rpm.mbn`
- `sbl1.mbn`
- `tz.mbn`
- `sbc_1.0_8016.bin`
- `lk2nd.img`
- `flash_from_fastboot.sh`
- `README-flash.md`
- `SHA256SUMS`

## How to use on GitHub
1. Fork this repository to your own GitHub account.
2. Open the **Actions** tab.
3. Run **Build UFI001C Hybrid Debian 13** manually.
4. Download the artifact named:
   - `ufi001c-debian13-hybrid-slim-zip`

## Technical route
- Debian 13 userspace
- postmarketOS MSM8916 kernel `6.12.1-r2`
- mainline `msm8916-thwc-ufi001c.dtb`
- legacy OpenStick low-level boot chain downloaded during the workflow
- lightweight tuning inspired by DietPi

## Important note
The workflow intentionally downloads a legacy OpenStick low-level boot chain (`base.zip` / `firmware-ufi001c.zip`) during the build instead of rebuilding every low-level piece from source, because that path is currently the most practical for producing a flashable UFI001C bundle on GitHub-hosted runners.
