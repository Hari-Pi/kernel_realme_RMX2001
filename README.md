# Realme 6 (RMX2001) Droidian kernel

Linux 4.14.141 kernel source and reproducible build tooling for the Realme 6
RMX2001 Droidian port.

## Build a boot package

The guarded build compiles the kernel, replaces only the kernel inside a
validated 32 MiB stock boot image, verifies the preserved boot components,
and creates a Debian package:

```sh
./helpers/build-magiskboot-deb.sh \
  --stock-boot /path/to/stock-boot.img \
  --magiskboot /path/to/magiskboot
```

The build uses all available CPUs by default. Pass `--jobs N` to set a limit.
The helper only creates artifacts; it does not connect to a device, install a
package, flash a partition, or reboot anything.

See [helpers/BUILDING.md](helpers/BUILDING.md) for prerequisites and output
layout. The package audit and device-validation procedure is documented in
[helpers/KERNEL-BUILD-AND-TEST.md](helpers/KERNEL-BUILD-AND-TEST.md).

## Compiler backend

`./build.sh` creates the native Droidian compiler artifact consumed by the
MagiskBoot packager. Check its prerequisites independently with:

```sh
./build.sh --check-only
```

The backend's generated boot image is structurally verified but is not treated
as deployable until it has passed real-device boot testing.

## Automated builds

Pushing to `droidian` starts the
[kernel build workflow](.github/workflows/build-kernel.yml). It runs the native
Droidian compiler and uploads `boot.img`, the `arm64` Debian package, a manifest,
and SHA-256 checksums as a downloadable workflow artifact. It can also be
started manually from GitHub Actions. These are build outputs, not a release or
a boot-tested image.

Use a **minimal Debian 13 (amd64)** installation as the self-hosted runner. It
needs Docker Engine, Git, `dpkg-deb`, access to the Docker daemon, and at least
25 GiB free in its temporary directory. Register it for this repository with
the `rmx2001-build` label; the workflow uses two build jobs. A disk larger than
the 25 GiB minimum leaves room for Docker images and build outputs. GitHub's
standard hosted Ubuntu runners have only 14 GB of storage, so they do not meet
this build's preflight requirement. See [GitHub's runner setup](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/add-runners)
and [Docker's Debian installation guide](https://docs.docker.com/engine/install/debian/).
Once the runner is online, each push to `droidian` builds and uploads the files
automatically. The workflow does not require the stock boot backup or
MagiskBoot; those are inputs to the separate guarded package workflow described
above.

## Droidian installation notes

For the full kernel compilation procedure, see the
[Droidian porting guide](https://github.com/droidian/porting-guide/blob/master/kernel-compilation.md).
The older workflow ran `RELENG_HOST_ARCH="arm64" releng-build-package` in the
Docker build environment and placed `boot.img` in `out/KERNEL_OBJ/`. For that
workflow, use the API 29 ZIP from the
[Droidian CI images](https://github.com/droidian-images/droidian/releases).
The guarded MagiskBoot package workflow above is the current build path.

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

### Power button helper

The earlier repository included `helpers/power-button/` with a helper to turn
the screen on using the power button. Its installer also installed
`pbhelper.service`; the original follow-up step installed
`libdroid-hal-lights`. Those files were removed from the current branch during
the public build cleanup. The
[earlier helper files](https://github.com/Hari-Pi/kernel_realme_RMX2001/tree/13b15f81a040/helpers/power-button)
and [installation script](https://github.com/Hari-Pi/kernel_realme_RMX2001/blob/13b15f81a040/helpers/power-button/script.sh)
remain available in repository history.

The original SSH installation command, pinned to the older script, was:

```sh
wget https://raw.githubusercontent.com/Hari-Pi/kernel_realme_RMX2001/13b15f81a040/helpers/power-button/script.sh
chmod +x script.sh
./script.sh
sudo apt install libdroid-hal-lights
```

### Reversible server mode

The earlier setup included a `server mode` command. `server mode on` disabled
the phone interface while leaving SSH, networking, Cloudflare tunnels, Docker,
and persistent performance tuning in place. `server mode off` restored Phosh,
the display, touch input, audio, Android phone HALs, and the power-button
helper. The selected mode persisted across reboots.

The server-mode installer and headless setup script were removed from the
current branch during the public build cleanup. Their
[earlier versions](https://github.com/Hari-Pi/kernel_realme_RMX2001/tree/90820a2442c1/helpers)
are available in repository history. With those scripts restored on a device,
the original commands were:

```sh
sudo helpers/setup-headless-server.sh
server mode status
server mode on
server mode off
```

The earlier README also documented `sudo helpers/server-mode.sh install` for
installing just the mode command from a checkout of that earlier revision.

The installer detected the invoking desktop user; `--user NAME` selected a
specific user when installing as root or on a device with multiple interactive
users. Server mode did not change SSH, networking, Cloudflare, Tailscale, or
Docker. The earlier
[server maintenance notes](https://github.com/Hari-Pi/kernel_realme_RMX2001/blob/90820a2442c1/helpers/SERVER-MAINTENANCE.md)
cover package sources and distribution-upgrade recovery.

## Safety

- Keep verified boot, recovery, and rootfs backups on separate storage.
- Test one kernel change at a time.
- Audit every package before installing it.
- Do not publish an image until it passes a real-device reboot and health test.

The upstream kernel documentation starts at
[Documentation/admin-guide/README.rst](Documentation/admin-guide/README.rst).
