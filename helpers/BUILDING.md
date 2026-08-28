# Building the RMX2001 Droidian boot package

## Requirements

- Linux x86_64 host (WSL 2 is supported)
- Docker daemon access
- Git and at least 25 GiB of free space
- validated 32 MiB RMX2001 stock boot image
- pinned x86_64 MagiskBoot binary

The Droidian archive public key is bundled in `helpers/keys/` and checked
against its pinned checksum and fingerprint. Build artifacts are written
outside the source tree.

## Preflight

Validate the toolchain and inputs without compiling:

```sh
./helpers/build-magiskboot-deb.sh \
  --check-only \
  --stock-boot /path/to/stock-boot.img \
  --magiskboot /path/to/magiskboot
```

The same inputs can be provided through `STOCK_BOOT_IMAGE` and `MAGISKBOOT`.
MagiskBoot may also be available on `PATH`.

## Build

```sh
./helpers/build-magiskboot-deb.sh \
  --stock-boot /path/to/stock-boot.img \
  --magiskboot /path/to/magiskboot
```

The helper uses every available CPU by default. Use `--jobs N` to limit it.
Use `--output DIR` to choose the artifact root. A completed, commit-matched
compiler artifact can be reused with `--compiler-artifact DIR` when debugging
the packaging stage.

The package replaces only the kernel in the validated stock layout. It
byte-compares the ramdisk, DTB, and kernel DTB, contains no recovery image,
does not request a reboot, and never accesses a phone while building.

The default artifact location is:

```text
../rmx2001-magiskboot-artifacts/<timestamp>-<commit>/
```

Each successful build contains the Debian package, boot image, raw kernel,
component audit, package metadata, manifest, and SHA-256 checksums.

## Native compiler backend

The packager invokes `./build.sh`, which uses the pinned Droidian toolchain.
It can be checked independently:

```sh
./build.sh --check-only
```

Its generated boot image is a structural build artifact, not a boot-tested
release image. Follow
[KERNEL-BUILD-AND-TEST.md](KERNEL-BUILD-AND-TEST.md) before deploying a build.
