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

## Safety

- Keep verified boot, recovery, and rootfs backups on separate storage.
- Test one kernel change at a time.
- Audit every package before installing it.
- Do not publish an image until it passes a real-device reboot and health test.

The upstream kernel documentation starts at
[Documentation/admin-guide/README.rst](Documentation/admin-guide/README.rst).
