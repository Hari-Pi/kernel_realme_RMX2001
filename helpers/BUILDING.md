# Building the RMX2001 Droidian boot package

## Requirements

- Linux x86_64 host (WSL 2 is supported)
- Docker daemon access
- Git and enough free space for the Docker image, build tree, and artifacts

The Droidian archive public key is bundled in `helpers/keys/` and checked
against its pinned checksum and fingerprint. Build artifacts are written
outside the source tree.

## Preflight

Validate the toolchain and inputs without compiling:

```sh
./build.sh --check-only
```

## Build

```sh
./build.sh --jobs "$(nproc)"
```

Runs the official Droidian `releng-build-package` pipeline in the pinned
container. Uses every available CPU by default; pass `--jobs N` to limit it,
`--output DIR` to choose the artifact root, and `--allow-dirty` to build from
an uncommitted tree (the source state is recorded in the manifest either
way).

The default artifact location is:

```text
../rmx2001-kernel-artifacts/<timestamp>-<commit>/
```

Each successful build contains the boot image, raw kernel `Image`, every
`.deb`/`.changes`/`.buildinfo` package, compiler and packaging-snippets
version files, a manifest, and SHA-256 checksums. Follow
[KERNEL-BUILD-AND-TEST.md](KERNEL-BUILD-AND-TEST.md) before deploying a
build — the generated boot image is a structural build artifact, not a
boot-tested release, until it passes that procedure.

## MagiskBoot repack (manual fallback)

Not used by CI; kept for emergency use if a future official-pipeline build
ever regresses. Requires a validated 32 MiB RMX2001 stock boot image and a
pinned x86_64 MagiskBoot binary.

```sh
./helpers/build-magiskboot-deb.sh \
  --check-only \
  --stock-boot /path/to/stock-boot.img \
  --magiskboot /path/to/magiskboot
./helpers/build-magiskboot-deb.sh \
  --stock-boot /path/to/stock-boot.img \
  --magiskboot /path/to/magiskboot
```

The same inputs can be provided through `STOCK_BOOT_IMAGE` and `MAGISKBOOT`;
MagiskBoot may also be available on `PATH`. Use `--jobs N` to limit CPUs,
`--output DIR` to choose the artifact root, and `--compiler-artifact DIR` to
reuse a completed, commit-matched compiler artifact (from a prior `./build.sh`
run) when debugging the packaging stage instead of recompiling.

This package replaces only the kernel in the validated stock layout. It
byte-compares the ramdisk, DTB, and kernel DTB, contains no recovery image,
does not request a reboot, and never accesses a phone while building. The
default artifact location is:

```text
../rmx2001-magiskboot-artifacts/<timestamp>-<commit>-magiskboot/
```
