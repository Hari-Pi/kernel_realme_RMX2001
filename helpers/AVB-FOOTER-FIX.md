# Why the official Droidian pipeline's boot.img didn't boot (and the fix)

Since this port's kernel work began, `helpers/build-magiskboot-deb.sh` has
been used to produce installable kernel builds: compile the kernel, then use
MagiskBoot to swap only the kernel binary into the *validated stock* boot
image, preserving its ramdisk, dtb, and AVB footer byte-for-byte. The
official Droidian pipeline (`build.sh`, wrapping `releng-build-package`)
produces its own complete `boot.img` from scratch, but that image never
booted on this device — hence the MagiskBoot workaround.

## Root cause

Built and compared both pipelines' `boot.img` from the exact same source
commit, using [`unpack_bootimg`](https://github.com/droidian/mkbootimg) from
Droidian's own `build-essential` container, plus a raw hexdump of each
image's last 64 bytes:

| Field | Official pipeline (broken) | Stock / MagiskBoot repack (working) |
|---|---|---|
| File size | 28,116,992 bytes | 33,554,432 bytes (= boot partition size) |
| AVB footer | **none** (last 64 bytes all zero) | `AVBf` magic + valid footer |
| `os_version` | `None` (zeroed) | `10.0.0` |
| `os_patch_level` | `None` (zeroed) | `2021-08` |
| header v2 fields (page size, kernel/ramdisk/dtb load addrs, cmdline) | identical | identical |

This device's bootloader enforces AVB (Android Verified Boot) on the boot
partition. An image with no AVB footer at all is rejected outright — this
was the actual reason the official pipeline's output never booted, not
anything about the kernel, ramdisk, or dtb content itself.

`releng-build-package`'s own packaging snippets
([`droidian/linux-packaging-snippets`](https://github.com/droidian/linux-packaging-snippets),
`kernel-info.mk.example`) document the mechanism directly:

```
# boot partition size. If specified, an AVB footer will be added at the
# end of the bootimage.
KERNEL_BOOTIMAGE_PARTITION_SIZE = 

# Specify boot image security patch level if needed
# KERNEL_BOOTIMAGE_PATCH_LEVEL = 2022-04-05

# Specify boot image OS version if needed
# KERNEL_BOOTIMAGE_OS_VERSION = 12.0.0
```

This device's `debian/kernel-info.mk` never set any of these three keys, so
`releng-build-package` produced an unpadded image with a zeroed header and no
footer at all — a config gap in this device's port, not a limitation of the
Droidian build pipeline itself.

## Fix

Three lines added to `debian/kernel-info.mk` (commit `74ea0498f`):

```
KERNEL_BOOTIMAGE_OS_VERSION = 10.0.0
KERNEL_BOOTIMAGE_PATCH_LEVEL = 2021-08
KERNEL_BOOTIMAGE_PARTITION_SIZE = 33554432
```

This is the documented upstream mechanism, applied at the source-config
level — not a post-build patch of the resulting `boot.img`.

## Validation

Built via `build.sh` (the official pipeline, no MagiskBoot involved) from
commit `74ea0498f`, on a local WSL2 build host with 24 cores (Docker,
`quay.io/droidian/build-essential`). Result:

- `boot.img`: 33,554,432 bytes, `AVBf` footer present, `os_version 10.0.0`,
  `os_patch_level 2021-08` — all now matching the stock/MagiskBoot image.
- Backed up the device's live (known-good) boot partition to
  `/userdata/kernel-backups/pre-avb-footer-test-known-good-20260928T155244Z.img`
  before touching anything.
- Wrote the new image directly to `/dev/disk/by-partlabel/boot` (checksum
  verified at every transfer hop: build host → Mac → device → written
  partition).
- **Three clean reboot cycles**, each confirmed via `uname -a` (new kernel
  build timestamp), boot partition checksum (matches written image), and
  `systemctl --failed` (only the same pre-existing 5 units seen throughout
  this port's bring-up — `android-mount`, `dnsmasq`, `droidian-fpd`,
  `lxc-net`, `nfcd` — no new regressions across any of the three boots).

This is real, repeated evidence that the official Droidian pipeline now
produces a fully bootable image for this device without MagiskBoot.

## What's left open

- **Not yet switched over.** CI (`.github/workflows/build-kernel.yml`) and
  the documented install procedure
  ([`helpers/KERNEL-BUILD-AND-TEST.md`](KERNEL-BUILD-AND-TEST.md)) still use
  `build-magiskboot-deb.sh`. Retiring MagiskBoot from the primary pipeline is
  a deliberate follow-up decision, not done automatically by this fix.
- **One remaining, likely-harmless header difference**: `second bootloader
  load address` is `0x00000000` in the official build vs `0x40f00000` in
  stock/MagiskBoot. `second bootloader size` is `0` in all three, so no
  second-stage binary is actually loaded at that address regardless of its
  value — three successful reboots support this being cosmetic, but it
  hasn't been root-caused.
- **Ramdisk content differs** between the official pipeline's freshly
  generated ramdisk and the stock/MagiskBoot-preserved one (expected — they
  are genuinely different content, not just recompressed). Three clean
  reboots with no new failed units is good evidence this doesn't matter
  functionally on this device, but it has not been soak-tested (suspend/
  resume, Wi-Fi, display, prolonged uptime) the way MagiskBoot builds have
  been earlier in this port's history.
- The `helpers/build-droidian.sh` `IMAGE_ID` pin
  (`sha256:cc97ed18ab572816258ee104bbf5433c50e9e00dadfb5251c273be0b0f17247b`)
  was captured on an older Docker version and does not match what Docker
  29.7.2 reports for the identical, digest-verified image
  (`sha256:53a9ebae9787b2d74c56974ae9b0727aae81409fdff612aca1f97b1083c9fd49`
  — same as the pull digest). This blocked `build.sh`'s own preflight check
  on the build host used for this investigation and had to be edited locally
  there (not committed) to proceed. Worth a proper fix if the official
  pipeline becomes the primary path.
