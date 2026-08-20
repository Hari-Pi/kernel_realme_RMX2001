# Building the RMX2001 Droidian boot image

The supported entry point is `./build.sh`. It follows Droidian's Debian kernel
packaging flow and never flashes a device.

## Requirements

- Linux x86_64 host (WSL 2 is supported)
- Docker daemon access
- Git and at least 25 GiB free space
- The Droidian archive key matching the fingerprint embedded in the script

Run checks only:

```sh
./build.sh --check-only --key /path/to/droidian.gpg
```

Build packages and extract a verified `boot.img`:

```sh
./build.sh --key /path/to/droidian.gpg --jobs 16
```

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
