# Building the RMX2001 Droidian boot image

The supported entry point is `./build.sh`. It follows Droidian's Debian kernel
packaging flow and never flashes a device.

For the complete optimization, MagiskBoot packaging, package-audit, rollback,
installation, and real-device test process, see
[KERNEL-OPTIMIZATION-WORKFLOW.md](KERNEL-OPTIMIZATION-WORKFLOW.md).

The server's Droidian and Tailscale APT configuration is documented in
[SERVER-APT-REPOSITORIES.md](SERVER-APT-REPOSITORIES.md).

## Requirements

- Linux x86_64 host (WSL 2 is supported)
- Docker daemon access
- Git and at least 25 GiB free space

The Droidian archive public key is bundled in `helpers/keys/` and is verified
against its pinned checksum and fingerprint before use.

Run checks only:

```sh
./build.sh --check-only
```

Build packages and extract a verified `boot.img`:

```sh
./build.sh
```

By default the build uses every CPU available to the host. Use `--jobs N` only
when you intentionally want to limit it. `--key FILE` remains available when
CI keeps another copy of the same pinned key elsewhere.

Artifacts are written outside the source tree to
`../rmx2001-kernel-artifacts/<timestamp>-<commit>/`. Every build includes the
boot-image Debian package, extracted `boot.img`, build log, package inventory,
tool versions, manifest, and SHA-256 checksums.

The verifier checks the Android magic, partition-size limit, header version,
page size, load addresses, kernel command line, gzip kernel and ramdisk, and DTB
magic. If any step fails, the run is marked with `FAILED.txt` and no `boot.img`
or success manifest is retained in that artifact directory.

The result is structurally verified but deliberately labelled **not
boot-tested**. A successful build is not evidence that the phone can boot it.

## Stock-layout MagiskBoot package

`helpers/build-magiskboot-deb.sh` uses the same pinned compiler, but discards
the generated Droidian boot image. It replaces only the kernel inside the
validated 32 MiB stock image using a pinned MagiskBoot binary, re-unpacks the
result, and byte-compares the preserved ramdisk, DTB, and kernel DTB before
creating a guarded boot-only Debian package.

On the established build host, both inputs are discovered automatically:

```sh
./helpers/build-magiskboot-deb.sh
```

On another host, provide them explicitly:

```sh
./helpers/build-magiskboot-deb.sh \
  --stock-boot /path/to/known-good-boot.img \
  --magiskboot /path/to/magiskboot
```

The package contains no recovery image and does not request a reboot. Building
it never accesses or modifies a phone. Its install scripts only accept the
known-good stock boot hash, create and verify a full rollback image, write the
full 32 MiB candidate, and verify the partition after writing.

For packaging diagnostics, `--compiler-artifact DIR` reuses a completed,
commit-matched compiler artifact. Normal runs do not use this option and always
compile from source first.
