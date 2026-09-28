# Kernel build and device validation

This procedure separates compilation, package inspection, installation, and
boot testing. Complete each stage before moving to the next one.

The primary build path is the official Droidian pipeline (`./build.sh`,
wrapping `releng-build-package`) — this is what CI
([`.github/workflows/build-kernel.yml`](../.github/workflows/build-kernel.yml))
runs, and it produces a fully bootable image on its own (see
[`AVB-FOOTER-FIX.md`](AVB-FOOTER-FIX.md) for why that wasn't always true and
how it was fixed). `build-magiskboot-deb.sh` — repacking a compiled kernel
into the validated stock boot layout with MagiskBoot — is kept as a manual
fallback; see the last section.

## 1. Prepare recovery material

Before installing a kernel package, keep verified copies of the device's boot,
recovery, and root filesystem on separate storage. Confirm that recovery can be
entered without relying on the installed operating system or its network.

Remote access and an automatic rollback timer are useful checks, but neither
replaces a physically tested recovery path.

## 2. Check the build environment

```sh
./build.sh --check-only
```

Resolve every preflight error before compiling.

## 3. Build the package

```sh
./build.sh --jobs "$(nproc)"
```

Keep the complete artifact directory. Its manifest identifies the source
commit, container, toolchain, boot image, kernel, and package checksums.

## 4. Audit before installation

```sh
dpkg-deb --info /path/to/linux-bootimage-*.deb
dpkg-deb --contents /path/to/linux-bootimage-*.deb
mkdir -p /tmp/rmx2001-package-audit
dpkg-deb --control /path/to/linux-bootimage-*.deb /tmp/rmx2001-package-audit
sh -n /tmp/rmx2001-package-audit/preinst
sh -n /tmp/rmx2001-package-audit/postinst
```

Confirm the package contains the expected boot image and no unexpected
maintainer scripts. Compare its SHA-256 checksum against the build manifest
before transferring it. Unlike the MagiskBoot-repack package (see below),
this package's `preinst`/`postinst` come from Droidian's own
`linux-bootimage.postinst.in` template and `flash-bootimage`, not a
device-specific predecessor-checksum guard — read them rather than assume
their behavior matches the MagiskBoot package's.

## 5. Install and reboot

Install only while a working physical recovery route is available. Back up
the live boot partition first — this package's own install path does not
save one the way the MagiskBoot-repack package's `preinst` does:

```sh
sudo dd if=/dev/disk/by-partlabel/boot of=/userdata/kernel-backups/pre-install-$(date -u +%Y%m%dT%H%M%SZ).img bs=1M status=progress
sudo apt install ./linux-bootimage-*.deb
sudo reboot
```

## 6. Validate the running kernel

After rebooting, verify at minimum:

```sh
uname -a
systemctl --failed
journalctl -b -p warning
dmesg --level=err,warn
```

Also test display, touch, power controls, charging, suspend and resume, Wi-Fi,
SSH, and any device-specific hardware used by the target installation. Keep a
build only after it survives repeated cold boots and an appropriate stability
test — the official-pipeline boot image was validated this way with three
clean reboot cycles before being trusted (see `AVB-FOOTER-FIX.md`), and every
new build should get the same treatment, not just the first one. Publish only
artifacts that passed this validation.

## 7. Publish a validated build

Once a build has passed step 6, publish it as a GitHub Release so it is
distinguishable from unvalidated workflow artifacts:

```sh
gh release create <tag> \
  boot.img <package>.deb MANIFEST.txt SHA256SUMS \
  --title "<title>" --notes-file <notes.md> --latest
```

Release notes should record the source commit, package and boot image
checksums, and a summary of the step 6 validation (what was checked, and
which failures, if any, were confirmed pre-existing rather than caused by the
new kernel). This publish step is currently manual.

A device-triggered pipeline — where the device reports a successful reboot
back to GitHub Actions (for example via `repository_dispatch` or a
`workflow_dispatch` call from a device-side script) and a separate workflow
job then runs the `gh release create` above automatically — is planned but not
yet built. Until it exists, treat every release as the result of a human
having completed step 6 on real hardware.

## Alternative: MagiskBoot repack (manual fallback)

Kept for emergency use if a future official-pipeline build ever regresses
(e.g. a ramdisk change the ported device doesn't tolerate) and a MagiskBoot
repack of the validated stock image is needed as a stopgap. Not used by CI.

```sh
./helpers/build-magiskboot-deb.sh \
  --check-only \
  --stock-boot /path/to/stock-boot.img \
  --magiskboot /path/to/magiskboot
./helpers/build-magiskboot-deb.sh \
  --stock-boot /path/to/stock-boot.img \
  --magiskboot /path/to/magiskboot
```

Do not bypass the pinned input hashes without first validating the new stock
image layout and MagiskBoot binary. This package's `preinst` validates the
device, boot-partition size, predecessor checksum, payload checksum, and
Android image magic; it saves and verifies the current boot image before
writing, verifies the partition after writing, and does not reboot
automatically — install and validate it the same way as steps 4-6 above.
