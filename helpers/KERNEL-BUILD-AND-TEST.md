# Kernel build and device validation

This procedure separates compilation, package inspection, installation, and
boot testing. Complete each stage before moving to the next one.

## 1. Prepare recovery material

Before installing a kernel package, keep verified copies of the device's boot,
recovery, and root filesystem on separate storage. Confirm that recovery can be
entered without relying on the installed operating system or its network.

Remote access and an automatic rollback timer are useful checks, but neither
replaces a physically tested recovery path.

## 2. Check the build environment

```sh
./helpers/build-magiskboot-deb.sh \
  --check-only \
  --stock-boot /path/to/stock-boot.img \
  --magiskboot /path/to/magiskboot
```

Resolve every preflight error before compiling. Do not bypass the pinned input
hashes without first validating the new stock image layout and MagiskBoot
binary.

## 3. Build the package

```sh
./helpers/build-magiskboot-deb.sh \
  --stock-boot /path/to/stock-boot.img \
  --magiskboot /path/to/magiskboot
```

Keep the complete artifact directory. Its manifest identifies the source
commit, tool inputs, boot image, kernel, and package checksums.

## 4. Audit before installation

```sh
dpkg-deb --info /path/to/linux-bootimage-*.deb
dpkg-deb --contents /path/to/linux-bootimage-*.deb
mkdir -p /tmp/rmx2001-package-audit
dpkg-deb --control /path/to/linux-bootimage-*.deb /tmp/rmx2001-package-audit
sh -n /tmp/rmx2001-package-audit/preinst
sh -n /tmp/rmx2001-package-audit/postinst
```

Confirm that the package contains one boot image, no recovery image, and no
unexpected maintainer scripts. Compare its SHA-256 checksum with the build
manifest before transferring it.

## 5. Install and reboot

Install only while a working physical recovery route is available:

```sh
sudo apt install ./linux-bootimage-*.deb
sudo reboot
```

The package validates the device, boot-partition size, predecessor checksum,
payload checksum, and Android image magic. It saves and verifies the current
boot image before writing, verifies the partition after writing, and does not
reboot automatically.

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
test. Publish only artifacts that passed this validation.

## 7. Publish a validated build

Once a build has passed step 6, publish it as a GitHub Release so it is
distinguishable from unvalidated workflow artifacts:

```sh
gh release create <tag> \
  boot.img <package>.deb MANIFEST.txt PRESERVED-COMPONENTS.txt \
  package-info.txt package-contents.txt SHA256SUMS \
  --title "<title>" --notes-file <notes.md> --latest
```

Release notes should record the source commit, package and candidate boot
checksums, and a summary of the step 6 validation (what was checked, and
which failures, if any, were confirmed pre-existing rather than caused by the
new kernel). This publish step is currently manual.

A device-triggered pipeline — where the device reports a successful reboot
back to GitHub Actions (for example via `repository_dispatch` or a
`workflow_dispatch` call from a device-side script) and a separate workflow
job then runs the `gh release create` above automatically — is planned but not
yet built. Until it exists, treat every release as the result of a human
having completed step 6 on real hardware.
