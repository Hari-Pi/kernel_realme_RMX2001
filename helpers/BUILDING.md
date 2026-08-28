# Building the RMX2001 Droidian boot package

## Requirements

- Linux x86_64 host (WSL 2 is supported)
- Docker daemon access
- Git and at least 25 GiB free space
- validated 32 MiB stock boot image
- pinned x86_64 MagiskBoot binary

The Droidian archive public key is bundled in `helpers/keys/` and verified
against its pinned checksum and fingerprint before use. Build artifacts are
written outside the source tree.

## Guarded package

Validate the complete environment without compiling:

```sh
./helpers/build-magiskboot-deb.sh --check-only
```

Compile and create the guarded Debian package:

```sh
./helpers/build-magiskboot-deb.sh
```

On another host, provide the validated inputs explicitly:

```sh
./helpers/build-magiskboot-deb.sh \
  --stock-boot /path/to/stock-boot.img \
  --magiskboot /path/to/magiskboot
```

The helper uses every available CPU by default. Use `--jobs N` to limit it.
`--compiler-artifact DIR` may reuse a completed, commit-matched compiler
artifact for packaging diagnostics; normal builds compile from source.

The package replaces only the kernel inside the known-good stock layout. It
byte-compares the preserved ramdisk, DTB, and kernel DTB, contains no recovery
image, does not request a reboot, and never accesses the phone while building.
Its install scripts verify the target device and stock boot hash, create a full
rollback image, write the complete 32 MiB candidate, and verify the partition.

Artifacts are stored under:

```text
../rmx2001-magiskboot-artifacts/<timestamp>-<commit>/
```

Each successful directory contains the Debian package, extracted boot image,
compiler artifact reference, audits, manifest, and SHA-256 checksums.

## Native compiler backend

`./build.sh` creates the native Droidian compiler artifact consumed by the
guarded packager. It can also be checked independently:

```sh
./build.sh --check-only
```

Its generated boot image is structurally verified but deliberately marked as
not boot-tested. Do not deploy it directly.

The complete installation and device-test process is in
[KERNEL-OPTIMIZATION-WORKFLOW.md](KERNEL-OPTIMIZATION-WORKFLOW.md). Server APT
and distribution-upgrade policy is in
[SERVER-MAINTENANCE.md](SERVER-MAINTENANCE.md).
