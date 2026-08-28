# RMX2001 kernel optimization workflow

This is the operational runbook for building and testing optimized kernels for
the Droidian RMX2001 server. It is designed to remain useful without the Codex
session that created the tooling.

## Safety rules

1. Change one small behavior per kernel.
2. Commit and push the source before building.
3. Never flash or package recovery, DTBO, or vbmeta.
4. Repack the validated stock boot layout with only the kernel replaced.
5. Audit every Debian package before it reaches the phone.
6. Back up and hash both boot and recovery before installation.
7. Arm a timed userspace rollback before writing boot.
8. Remember that a userspace timer cannot recover a kernel that fails before
   systemd starts. Keep the stock boot and recovery images available for manual
   recovery.
9. Publish only boot images that have completed a real-device reboot and health
   test.
10. Never commit passwords, access tokens, tunnel credentials, or device-private
    configuration.

## Current validated baseline

The following state was verified on the phone on 2026-08-28 after the MCDI
heartbeat and BBR/fq candidate completed a guarded installation and reboot:

| Item | Value |
| --- | --- |
| Kernel ABI | `4.14.141-realme-rmx2001` |
| Source commit | `2b74e274ae46ae37507fe859fb61e8e521bf413f` |
| Running marker | `RMX2001 mcdi-v3-bbr-fq 2026-08-28` |
| Installed boot package | `0.0.0+magiskboot.git20260827231134.2b74e274ae46` |
| Running boot SHA-256 | `0b7d5682dc120a26acb307dc38e590f470d4b9d3c8731d7c55f23dc32b408fea` |
| Recovery SHA-256 | `55d75023630495d2f9018d46b8fd836bca8eae66b2ee9c251a21ca09338806f6` |
| Validated stock boot SHA-256 | `ce5d48e4802398ceb2cd0dd8c84e04dd944cac08bb540ace87f1c26a9ffe14c2` |
| Pinned MagiskBoot SHA-256 | `a18ecbd7981179494b7d281453d6c4e25b5c719e7d2ef7f6eba3c6be3043c58e` |

The complete test history is in [KERNEL-TESTS.md](KERNEL-TESTS.md).
The server's package sources and upgrade constraints are recorded in
[SERVER-MAINTENANCE.md](SERVER-MAINTENANCE.md).

## Build host layout

Run the workflow inside the rig's Debian WSL environment.

```text
/home/dazai/kernel-build/
├── input/stock-boot.img
├── tools/magisk-v30.7/magiskboot
├── kernel_realme_RMX2001-build-system/
└── rmx2001-magiskboot-artifacts/
```

The helper validates the stock image and MagiskBoot checksums before compiling.
It refuses unexpected inputs.

## Normal build

From Debian WSL on the rig:

```sh
cd /home/dazai/kernel-build/kernel_realme_RMX2001-build-system
./helpers/build-magiskboot-deb.sh
```

Do not invoke the helper with `sh`. It is a Bash program with a Bash shebang.
Executing it directly, as above, uses the correct interpreter.

With no arguments on the rig, the helper automatically finds:

- `/home/dazai/kernel-build/input/stock-boot.img`
- `/home/dazai/kernel-build/tools/magisk-v30.7/magiskboot`
- all available CPU cores, currently 24

The build is local to the rig. It does not connect to or modify the phone.

To limit CPU use intentionally:

```sh
./helpers/build-magiskboot-deb.sh --jobs 12
```

For diagnostics only, a commit-matched compiler artifact can be reused:

```sh
./helpers/build-magiskboot-deb.sh \
  --compiler-artifact /path/to/completed/compiler/artifact
```

A normal release candidate must compile from source and should not use the
reuse option.

## What the helper does

The zero-argument helper performs these gates in order:

1. Confirms required host tools are available.
2. Confirms the source tree is suitable for a reproducible build.
3. Verifies the stock boot is exactly 32 MiB, begins with Android boot magic,
   and matches the pinned stock SHA-256.
4. Verifies the pinned MagiskBoot binary SHA-256.
5. Runs the Droidian build preflight using the bundled archive key.
6. Compiles the raw kernel with the pinned Droidian toolchain.
7. Unpacks the validated stock boot image with MagiskBoot.
8. Replaces only the kernel component.
9. Repacks a full 32 MiB candidate boot image.
10. Re-unpacks the candidate and byte-compares the stock ramdisk, DTB, and
    kernel DTB.
11. Builds a guarded arm64 Debian package containing only the candidate boot
    image and documentation.
12. Extracts and audits the package it just built.
13. Writes manifests, inventories, logs, and SHA-256 checksums beside the
    candidate.

Artifacts are written to:

```text
/home/dazai/kernel-build/rmx2001-magiskboot-artifacts/
  <UTC timestamp>-<source commit>-magiskboot/
```

Important files in a successful artifact directory are:

```text
boot.img
kernel-Image
linux-bootimage-*_arm64.deb
MANIFEST.txt
SHA256SUMS
PRESERVED-COMPONENTS.txt
package-info.txt
package-contents.txt
unpack-stock.log
unpack-candidate.log
repack.log
```

A successful build is structurally verified, but it is not considered working
until the real phone boots it and completes the runtime checks below.

## Source-change workflow

Before editing:

```sh
cd /home/dazai/kernel-build/kernel_realme_RMX2001-build-system
git fetch origin droidian
git merge --ff-only origin/droidian
git status --short
```

The status output must be empty before starting a new optimization.

For each optimization:

1. Locate the exact call site using `git grep`.
2. Prefer changing a threshold or disabling one routine diagnostic over
   changing power-state, scheduler, timing, or hardware behavior.
3. Update the marker in `init/version.c` so `/proc/version` identifies the
   candidate unambiguously.
4. Run `git diff --check` and inspect the complete diff.
5. Commit and push the source before building.
6. Run the normal zero-argument build command.

## Current unbuilt change

Commit `b22b9d6eaaa11b89f656931b4fc98b1dc57fb5a7` changes the MCDI heartbeat
from 5 seconds to 5 minutes and advances the marker to:

```text
RMX2001 mcdi-heartbeat-v3 2026-08-28
```

This source commit is pushed to the `droidian` branch. It has deliberately not
been built or installed yet.

## Package audit before transfer

Do not trust a `.deb` only because the build exited successfully. In the new
artifact directory:

```sh
sha256sum -c SHA256SUMS
dpkg-deb --info ./linux-bootimage-*_arm64.deb
dpkg-deb --contents ./linux-bootimage-*_arm64.deb
```

Then extract it into a temporary directory and verify:

- package architecture is `arm64`
- package name is `linux-bootimage-4.14.141-realme-rmx2001`
- maintainer scripts pass `sh -n`
- the data archive contains only `/boot/boot.img-4.14.141-realme-rmx2001`
  and package documentation
- no recovery, DTBO, or vbmeta payload exists
- both scripts target only `/dev/disk/by-partlabel/boot`
- the payload is 33,554,432 bytes and begins with `ANDROID!`
- the payload SHA-256 matches `MANIFEST.txt`
- MagiskBoot can unpack both stock and candidate images
- ramdisk, DTB, and kernel DTB remain byte-identical
- the candidate kernel equals the compiled `kernel-Image`
- header version, page size, OS version, patch level, command line, and image
  formats remain expected

Stop before transferring the package if any audit check fails.

## Predecessor-hash guard

The current package pre-install script accepts only this predecessor:

```text
ce5d48e4802398ceb2cd0dd8c84e04dd944cac08bb540ace87f1c26a9ffe14c2
```

That is the validated stock boot image. The phone currently runs the tested v2
image with SHA-256 `befcdf3e...`, so an unchanged v3 package will correctly
refuse to install over it.

Before a v3 test, choose one explicit approach:

1. Restore and verify the stock boot image, then install the stock-guarded
   package; or
2. Extend the builder to accept the exact tested v2 SHA-256 as an additional
   predecessor, audit that generated guard, and preserve a verified v2 backup.

Never remove the predecessor check and never accept an arbitrary current boot
hash.

## Device preflight

Before installing a candidate, record and verify:

```sh
uname -a
cat /proc/version
dpkg-query -W linux-bootimage-4.14.141-realme-rmx2001
sudo blockdev --getsize64 /dev/disk/by-partlabel/boot
sudo blockdev --getsize64 /dev/disk/by-partlabel/recovery
sudo sha256sum \
  /dev/disk/by-partlabel/boot \
  /dev/disk/by-partlabel/recovery
systemctl is-active NetworkManager ssh docker cloudflared
docker ps --format '{{.Names}}|{{.Status}}'
```

Create full boot and recovery backups under a new timestamped directory in
`/userdata/kernel-backups/`. Run `sync`, hash both backups, and confirm they
match the source partitions. Recovery is read for backup and verification only;
it is never written during a kernel update.

## Rollback protection

Use two layers:

1. The package pre-install script creates and verifies a fresh boot backup. Its
   post-install script restores that backup if the write or post-write checksum
   fails in the same installation session.
2. Before installation, create and start a candidate-specific systemd timer.
   If it is not disarmed after a successful reboot, it restores the verified
   predecessor boot image, checks the restored hash, and reboots.

The timer should hard-code all of the following:

- boot target: `/dev/disk/by-partlabel/boot`
- exact predecessor SHA-256
- exact candidate SHA-256
- exact verified backup path
- a bounded test window, normally 12 minutes after userspace starts

The timer is only a userspace fallback. If the candidate cannot start the
kernel and systemd, manual boot restoration is required.

## Installation

Transfer the already-audited package, verify its SHA-256 again on the phone,
then install the exact local file without rebooting:

```sh
sudo apt-get install -y --no-install-recommends ./linux-bootimage-*_arm64.deb
```

Before rebooting, confirm:

- `dpkg-query` reports the intended version
- `/boot/boot.img-4.14.141-realme-rmx2001` matches the candidate hash
- the full boot partition matches the candidate hash
- recovery still matches its preflight hash
- the rollback timer is active and has the expected deadline

Only then perform one controlled reboot.

## Post-boot verification

Monitor SSH for at least six minutes. If it does not return, stop remote work
and restore the known-good boot manually.

When SSH returns, verify:

```sh
uname -a
cat /proc/version
uptime
sudo sha256sum \
  /dev/disk/by-partlabel/boot \
  /dev/disk/by-partlabel/recovery
systemctl is-active NetworkManager ssh docker cloudflared
docker ps --format '{{.Names}}|{{.Status}}'
sudo dmesg | grep -Ei \
  'kernel panic|Oops:|BUG: unable|Unable to handle kernel|watchdog.*lockup'
```

Also test the public services and observe the specific metric targeted by the
optimization. For the MCDI v3 candidate, confirm that `[mcdi]mcdi cpu:` appears
at most once per five minutes instead of once every five seconds.

Keep the rollback timer armed during a short soak. Disarm and remove it only
after all hashes, services, containers, logs, and the targeted behavior pass.

## Completion and release policy

After a successful test:

1. Append exact source, package, boot, recovery, and backup hashes to
   `helpers/KERNEL-TESTS.md`.
2. Commit and push the test result.
3. Preserve the complete artifact directory on the rig.
4. Publish a GitHub boot-image release only after the candidate is confirmed
   working on the physical device.
5. Keep failed or unbooted images out of GitHub releases.

If a test fails, record the failure and its symptoms in the test log, restore
the predecessor, and do not overwrite or relabel the previous working release.
