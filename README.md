# Realme 6 (RMX2001) Droidian kernel

Linux 4.14.141 kernel source and guarded build tooling for the Realme 6
RMX2001 Droidian port.

## Build

The boot-tested deployment path compiles the kernel, replaces only the kernel
inside the validated 32 MiB stock boot layout with MagiskBoot, verifies every
preserved component, and creates a rollback-aware Debian package:

```sh
./helpers/build-magiskboot-deb.sh
```

On the established rig, the known-good stock image and pinned MagiskBoot binary
are discovered automatically. Use `--stock-boot` and `--magiskboot` on another
host. Builds use all available CPUs unless `--jobs N` is supplied.

`./build.sh` is the native Droidian compiler and structural package backend
used by the MagiskBoot workflow. Its generated boot image is not considered
deployable until it has passed the same real-device validation.

See [helpers/BUILDING.md](helpers/BUILDING.md) for build inputs and output
layout, and
[helpers/KERNEL-OPTIMIZATION-WORKFLOW.md](helpers/KERNEL-OPTIMIZATION-WORKFLOW.md)
for the guarded installation and recovery procedure.

## Server mode

Install the reversible headless mode and persistent server tuning on the phone:

```sh
sudo helpers/setup-headless-server.sh
server mode status
server mode on
server mode off
```

The installer detects the invoking desktop user. Pass `--user NAME` when
installing as root or on a device with multiple interactive users. Server mode
does not modify SSH, networking, Cloudflare, Tailscale, or Docker.

Package-source policy and distribution-upgrade recovery are documented in
[helpers/SERVER-MAINTENANCE.md](helpers/SERVER-MAINTENANCE.md).

## Safety

- Keep verified boot, recovery, and rootfs backups physically accessible.
- Change and test one kernel behavior at a time.
- Never publish an image before a real-device reboot and health test.
- Never commit credentials, tunnel configuration, or device-private data.

The upstream kernel documentation starts at
[Documentation/admin-guide/README.rst](Documentation/admin-guide/README.rst).
