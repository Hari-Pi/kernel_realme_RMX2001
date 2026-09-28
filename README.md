# Realme 6 (RMX2001) Droidian kernel

[![Build](https://github.com/Hari-Pi/kernel_realme_RMX2001/actions/workflows/build-kernel.yml/badge.svg?branch=droidian)](https://github.com/Hari-Pi/kernel_realme_RMX2001/actions/workflows/build-kernel.yml)
[![Latest release](https://img.shields.io/github/v/release/Hari-Pi/kernel_realme_RMX2001?label=latest%20release&sort=date)](https://github.com/Hari-Pi/kernel_realme_RMX2001/releases)
[![License: GPL v2](https://img.shields.io/badge/license-GPL--2.0-blue.svg)](COPYING)

Linux 4.14.141 kernel source and reproducible build tooling that turns a
Realme 6 (RMX2001) into a fully working [Droidian](https://droidian.org)
Linux server — RFKILL/Bluetooth working, hardware video decode working, a
kernel `boot.img` that boots straight out of Droidian's own official build
pipeline (no MagiskBoot repacking needed), and a one-command install for
every device-specific fix this port required.

## Demo

<video src="https://hari-pi.com/media/realme6-droidian-demo.mp4" controls muted playsinline width="640"></video>

If the player above doesn't load, watch it directly:
[realme6-droidian-demo.mp4](https://hari-pi.com/media/realme6-droidian-demo.mp4) ·
[full project writeup](https://hari-pi.com/projects/kernel-realme-rmx2001.html)

## Contents

- [Flashing Droidian from scratch](#flashing-droidian-from-scratch)
- [Quick start (already-flashed device)](#quick-start-already-flashed-device)
- [Building a boot package](#building-a-boot-package)
- [Automated builds (CI)](#automated-builds-ci)
- [Device adaptation package](#device-adaptation-package)
  - [Connect over USB and enable Wi-Fi](#connect-over-usb-and-enable-wi-fi)
  - [Phosh and udev setup](#phosh-and-udev-setup)
  - [Server mode](#server-mode)
- [Safety](#safety)

## Flashing Droidian from scratch

Never touched this device before? Full procedure — bootloader unlock (MTK
Bypass + SP Flash Tool + B.56 firmware), `lk` patching, custom recovery, data
format, and flashing this device's fixed rootfs zip — is in
[`helpers/FLASHING-FROM-SCRATCH.md`](helpers/FLASHING-FROM-SCRATCH.md).

Once you're booted, flash a validated kernel release (below) and run the
[Quick start](#quick-start-already-flashed-device) one-liner.

## Quick start (already-flashed device)

Already running Droidian with a working kernel? Connect to Wi-Fi, then run:

```sh
curl -fsSL https://raw.githubusercontent.com/Hari-Pi/kernel_realme_RMX2001/droidian/helpers/bootstrap.sh | bash
```

This installs the [adaptation package](#device-adaptation-package) — every
device-specific fix in one `.deb` — and brings up the Phosh phone GUI. Safe
to re-run. Reboot afterward so the VINTF manifest override and GStreamer
decoder ranking fully apply.

## Building a boot package

The primary build path is the official Droidian pipeline: it compiles the
kernel in the pinned Droidian container via `releng-build-package` and
produces a complete, directly bootable `boot.img` and Debian package on its
own — no repacking step needed.

```sh
./build.sh --jobs "$(nproc)"
```

`--jobs N` limits CPUs (default: all available). `./build.sh --check-only`
validates prerequisites without compiling. The script only creates
artifacts; it never touches a device.

> **Why this matters:** this device's `boot.img` didn't always boot straight
> out of this pipeline. See [`helpers/AVB-FOOTER-FIX.md`](helpers/AVB-FOOTER-FIX.md)
> for the root cause (a missing AVB footer, from three unset
> `debian/kernel-info.mk` keys) and how it was fixed and validated — three
> clean reboot cycles on real hardware, no new failed units.

A MagiskBoot-based repack of the validated stock boot image
(`./helpers/build-magiskboot-deb.sh`) is kept as a manual fallback in case a
future official-pipeline build ever regresses; it is **not** used by CI. See
the last section of
[`helpers/KERNEL-BUILD-AND-TEST.md`](helpers/KERNEL-BUILD-AND-TEST.md).

See [`helpers/BUILDING.md`](helpers/BUILDING.md) for prerequisites and
output layout, and
[`helpers/KERNEL-BUILD-AND-TEST.md`](helpers/KERNEL-BUILD-AND-TEST.md) for
the package audit and device-validation procedure.

## Automated builds (CI)

Pushing to `droidian` starts the
[kernel build workflow](.github/workflows/build-kernel.yml), which runs
`./build.sh` on a GitHub-hosted `ubuntu-24.04` runner using the pinned
Droidian Docker image (`quay.io/droidian/build-essential`, pinned by content
digest). It uploads the resulting `boot.img`, `kernel-Image`, every
`.deb`/`.changes`/`.buildinfo` package, a manifest, and SHA-256 checksums as
a downloadable workflow artifact — a build output, not a release or a
boot-tested image. It can also be started manually from GitHub Actions.

A build only becomes a [GitHub Release](https://github.com/Hari-Pi/kernel_realme_RMX2001/releases)
after it passes the manual install-and-reboot validation described in
[`helpers/KERNEL-BUILD-AND-TEST.md`](helpers/KERNEL-BUILD-AND-TEST.md)
("Publish a validated build"). Publishing is a manual step
(`gh release create`) run once that validation passes; automatically gating
it on a device-reported reboot success is tracked as follow-up work.

## Device adaptation package

Beyond the kernel itself, the live Droidian server needs a handful of
device-specific fixes that aren't part of this repo or any kernel package —
a VINTF manifest override, a Bluetooth/RFKILL fix, GStreamer hardware video
decode, cellular disabled permanently (no SIM will ever be used), and more.
These are **not** preserved by a reflash.

[`adaptation/adaptation-realme-rmx2001`](adaptation/adaptation-realme-rmx2001)
is a real Debian package — following the
[Droidian porting guide](https://github.com/droidian-releng/docs.droidian.org/blob/main/content/porting-guide/rootfs-creation.md)'s
adaptation-package convention — that applies all of them via proper `dpkg`
diversions and systemd presets, instead of a shell script:

```sh
./helpers/build-adaptation-deb.sh   # run on a Debian host, e.g. the device itself
sudo apt install ./adaptation-realme-rmx2001_*.deb
```

The [Quick start](#quick-start-already-flashed-device) one-liner does this
for you. See [`helpers/DEVICE-PROVISIONING.md`](helpers/DEVICE-PROVISIONING.md)
for what each fix is and why it's needed.
[`helpers/setup-rmx2001.sh`](helpers/setup-rmx2001.sh) — a plain idempotent
shell script doing the same thing without `dpkg` bookkeeping — is kept as a
lighter-weight alternative.

For the full kernel compilation procedure this port is based on, see the
[Droidian porting guide](https://github.com/droidian/porting-guide/blob/master/kernel-compilation.md).

### Connect over USB and enable Wi-Fi

Connect the phone to a Linux host by USB, use `dmesg` to find the RNDIS
address, then SSH into the phone (for example, `ssh droidian@10.??.??.82`).
The original installation notes list `1234` as the default password. To
activate Wi-Fi:

```sh
echo S | sudo tee /dev/wmtWifi
```

### Phosh and udev setup

The original port used these external setup resources for Phosh and the
udev rule. Review the scripts and rule before applying them to a device:

```sh
sudo apt install curl
curl -fsSL https://raw.githubusercontent.com/NeelamArunkumar/droidian-script/main/droid-script.sh | sudo bash
wget https://raw.githubusercontent.com/NeelamArunkumar/droidian-script/main/70-denniz.rules -O - | sudo tee /etc/udev/rules.d/70-denniz.rules > /dev/null
```

Restart the phone after installing the udev rule.

### Server mode

The [Quick start](#quick-start-already-flashed-device) one-liner installs
this — nothing further to do manually on a device that's already been
through it.

`server mode` (installed as `/usr/local/bin/server`, from
[`helpers/server-mode.sh`](helpers/server-mode.sh)) toggles the device
between headless server mode and the Phosh phone GUI:

```sh
server mode status
sudo server mode on    # headless: display, touch, audio, and phone HALs off
sudo server mode off   # phone GUI: Phosh, display, touch, audio, phone HALs back on
```

`server mode on` leaves SSH, networking, Cloudflare tunnels, and Docker
untouched, and the selected mode persists across reboots. See
[`helpers/DEVICE-PROVISIONING.md`](helpers/DEVICE-PROVISIONING.md) for the
full design rationale — why it checks state before acting instead of
brute-forcing every unit, why independent steps run in parallel, and how
Ctrl+C cancellation works cleanly.

## Safety

- Keep verified boot, recovery, and rootfs backups on separate storage.
- Test one kernel change at a time.
- Audit every package before installing it.
- Do not publish an image until it passes a real-device reboot and health test.

The upstream kernel documentation starts at
[Documentation/admin-guide/README.rst](Documentation/admin-guide/README.rst).
