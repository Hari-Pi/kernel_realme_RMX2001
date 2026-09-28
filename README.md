# Realme 6 (RMX2001) Droidian kernel

Linux 4.14.141 kernel source and reproducible build tooling for the Realme 6
RMX2001 Droidian port.

## Flashing Droidian from scratch

The stock upstream Droidian `devtools-api29-arm64` recovery zip fails to
loop-mount its rootfs payload in recovery on this specific device. A fixed
build is published here:
[`rmx2001-recovery-api29-loopmount-fixed`](https://github.com/Hari-Pi/kernel_realme_RMX2001/releases/tag/rmx2001-recovery-api29-loopmount-fixed) —
flash it via `adb sideload` or your recovery's sideload/install menu, same
as any other `package-sideload` zip. After first boot, flash a validated
kernel (see below) and run the [Quick start](#quick-start-already-flashed-device)
one-liner.

## Quick start (already-flashed device)

On a device already running Droidian with a working kernel, connect to
Wi-Fi, then run:

```sh
curl -fsSL https://raw.githubusercontent.com/Hari-Pi/kernel_realme_RMX2001/droidian/helpers/bootstrap.sh | bash
```

This installs the [adaptation package](#droidian-installation-notes) (every
device-specific fix in one `.deb`) and brings up the Phosh phone GUI. Safe to
re-run. Reboot afterward so the VINTF manifest override and GStreamer decoder
ranking fully apply.

## Build a boot package

The primary build path is the official Droidian pipeline: it compiles the
kernel in the pinned Droidian container via `releng-build-package` and
produces a complete, directly bootable `boot.img` and Debian package on its
own — no repacking step needed.

```sh
./build.sh --jobs "$(nproc)"
```

The build uses all available CPUs by default. Pass `--jobs N` to set a limit.
`./build.sh --check-only` validates prerequisites without compiling. The
helper only creates artifacts; it does not connect to a device, install a
package, flash a partition, or reboot anything.

This device's `boot.img` didn't always boot straight out of this pipeline —
see [`helpers/AVB-FOOTER-FIX.md`](helpers/AVB-FOOTER-FIX.md) for the root
cause (a missing AVB footer, from unset `debian/kernel-info.mk` keys) and how
it was fixed and validated (three clean reboot cycles on real hardware, no
new failed units).

A MagiskBoot-based repack of the validated stock boot image
(`./helpers/build-magiskboot-deb.sh`) is kept as a manual fallback in case a
future official-pipeline build ever regresses; it is not used by CI. See the
last section of
[helpers/KERNEL-BUILD-AND-TEST.md](helpers/KERNEL-BUILD-AND-TEST.md).

See [helpers/BUILDING.md](helpers/BUILDING.md) for prerequisites and output
layout. The package audit and device-validation procedure is documented in
[helpers/KERNEL-BUILD-AND-TEST.md](helpers/KERNEL-BUILD-AND-TEST.md).

## Automated builds

Pushing to `droidian` starts the
[kernel build workflow](.github/workflows/build-kernel.yml), which runs
`./build.sh` on a GitHub-hosted `ubuntu-24.04` runner using the pinned
Droidian Docker image (`quay.io/droidian/build-essential`, pinned by content
digest). It uploads the resulting `boot.img`, `kernel-Image`, every
`.deb`/`.changes`/`.buildinfo` package, a manifest, and SHA-256 checksums as a
downloadable workflow artifact. It can also be started manually from GitHub
Actions. These are build outputs, not a release or a boot-tested image.

A build only becomes a [GitHub Release](https://github.com/Hari-Pi/kernel_realme_RMX2001/releases)
after it passes the manual install-and-reboot validation in
[`helpers/KERNEL-BUILD-AND-TEST.md`](helpers/KERNEL-BUILD-AND-TEST.md). Publishing
is currently a manual step (`gh release create`) run once that validation
passes; see that doc's "Publish a validated build" section. Gating the publish
step on an automatic report of reboot success from the device, instead of a
manual step, is tracked as follow-up work and not yet implemented.

## Droidian installation notes

Beyond the kernel itself, the live Droidian server needs a handful of
device-specific fixes that are not part of this repo or any kernel package
(for example, a VINTF manifest override). These are **not** preserved by a
reflash. After flashing, install
[`adaptation/adaptation-realme-rmx2001`](adaptation/adaptation-realme-rmx2001)
— a real Debian package, following the
[Droidian porting guide](https://github.com/droidian-releng/docs.droidian.org/blob/main/content/porting-guide/rootfs-creation.md)'s
adaptation-package convention, that applies all of them via proper `dpkg`
diversions and systemd presets instead of a shell script:

```sh
./helpers/build-adaptation-deb.sh   # run on a Debian host, e.g. the device itself
sudo apt install ./adaptation-realme-rmx2001_*.deb
```

See [`helpers/DEVICE-PROVISIONING.md`](helpers/DEVICE-PROVISIONING.md) for
what each fix is and why it's needed. `helpers/setup-rmx2001.sh` (a plain
idempotent shell script doing the same thing without `dpkg` bookkeeping) is
kept as a lighter-weight alternative.

For the full kernel compilation procedure, see the
[Droidian porting guide](https://github.com/droidian/porting-guide/blob/master/kernel-compilation.md).

### Connect over USB and enable Wi-Fi

Connect the phone to a Linux host by USB, use `dmesg` to find the RNDIS address,
then SSH into the phone (for example, `ssh droidian@10.??.??.82`). The original
installation notes list `1234` as the default password. To activate Wi-Fi:

```sh
echo S | sudo tee /dev/wmtWifi
```

### Phosh and udev setup

The original port used these external setup resources for Phosh and the udev
rule. Review the scripts and rule before applying them to a device:

```sh
sudo apt install curl
curl -fsSL https://raw.githubusercontent.com/NeelamArunkumar/droidian-script/main/droid-script.sh | sudo bash
wget https://raw.githubusercontent.com/NeelamArunkumar/droidian-script/main/70-denniz.rules -O - | sudo tee /etc/udev/rules.d/70-denniz.rules > /dev/null
```

Restart the phone after installing the udev rule.

### Server mode

The [Quick start](#quick-start-already-flashed-device) one-liner at the top
of this README installs this — nothing further to do manually on a device
that's already been through it.

`server mode` (installed as `/usr/local/bin/server`, from
[`helpers/server-mode.sh`](helpers/server-mode.sh)) toggles the device
between headless server mode and the Phosh phone GUI:

```sh
server mode status
sudo server mode on    # headless: display, touch, audio, and phone HALs off
sudo server mode off   # phone GUI: Phosh, display, touch, audio, phone HALs back on
```

`server mode on` leaves SSH, networking, Cloudflare tunnels, and Docker
untouched. The selected mode persists across reboots. See
[`helpers/DEVICE-PROVISIONING.md`](helpers/DEVICE-PROVISIONING.md) for the
full design rationale (why it checks state before acting, runs independent
steps in parallel, and how Ctrl+C cancellation works).

An earlier `pbhelper.service` (power-button screen-wake helper) that
`server mode off` used to re-enable turned out to be an orphaned manual
install with no open file descriptor to any input device — confirmed doing
nothing after a Droidian update changed how power-button wake is handled.
Removed from `server-mode.sh` and stopped on-device.

## Safety

- Keep verified boot, recovery, and rootfs backups on separate storage.
- Test one kernel change at a time.
- Audit every package before installing it.
- Do not publish an image until it passes a real-device reboot and health test.

The upstream kernel documentation starts at
[Documentation/admin-guide/README.rst](Documentation/admin-guide/README.rst).
