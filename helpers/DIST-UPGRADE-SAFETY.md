# Dist-upgrade safety assessment

This assessment was performed on the RMX2001 Droidian server on 2026-08-28.
It answers whether a distribution upgrade can preserve SSH, Tailscale, and
Cloudflare access, and records the physical recovery requirements for testing
one safely.

## Decision

Do not run `apt full-upgrade` or `apt-get dist-upgrade` in the current
repository state. Physical recovery is available and has been exercised, so a
controlled upgrade experiment is viable after the repository configuration is
corrected and the resolver produces an explicitly approved plan.

The current resolver does not directly upgrade or remove OpenSSH, Tailscale,
Cloudflare, NetworkManager, systemd, Docker, or containerd. That lowers the
probability of losing remote access, but it does not make the operation
recoverable through the network alone. All remote paths depend on the same kernel, writable root image,
systemd, DNS resolver, Wi-Fi interface, and userspace network stack.

## Current resolver plan

With both the package-managed Droidian rolling snapshot and the manually added
production repository enabled:

```text
6 upgraded, 8 newly installed, 31 to remove and 5 not upgraded
```

The removals include:

- `droidian-phosh-full`
- `droidian-phosh-phone`
- `droidian-phosh-minimal`
- `adaptation-hybris-phosh`
- `droidian-extras`
- Phosh, Phoc, mobile settings, and hardware-composer configuration
- GNOME session and settings components

This would remove the GUI path that `server mode off` is expected to restore.

## Source-isolated simulations

Each plan was simulated without installing, removing, or downgrading packages.

### Rolling snapshot only

```text
0 upgraded, 0 newly installed, 49 downgraded, 0 to remove and 0 not upgraded
```

The downgrade set includes Droidian APT configuration, migrations, device
quirks, hybris adaptation packages, graphics libraries, and server-relevant
system integration. A mass downgrade is not a safe remote recovery strategy.

### Production only

```text
4 upgraded, 1 newly installed, 29 downgraded, 31 to remove and 7 not upgraded
```

This plan removes the same GUI/adaptation stack and downgrades systemd,
systemd-resolved, udev, libsystemd, and related packages from version 257 to
256. That directly crosses the shared failure domain used by every remote
access method.

### Current mixed configuration

```text
6 upgraded, 8 newly installed, 31 to remove and 5 not upgraded
```

This avoids the large systemd downgrade only by mixing package candidates from
the two channels. It still removes the GUI and adaptation packages.

## Why the direct production source is risky

Droidian's snapshot generation overlays production packages and then applies
version masks, cherry-picks, package drops, and keep rules before publishing a
rolling snapshot. Adding the underlying production archive directly can bypass
those curated snapshot decisions. See Droidian's
[`droidian-current.in`](https://github.com/droidian/droidian-release/blob/group/102/updates/droidian-current.in)
manifest for the production overlay and snapshot rules.

This is an inference from the official manifest and the live resolver plans,
not a claim that the production archive itself is broken.

## Shared recovery failure domain

The services are currently healthy and enabled:

- `NetworkManager.service`
- `ssh.service`
- `tailscaled.service`
- `cloudflared.service`
- `docker.service`

However, they are not independent recovery channels:

```text
Wi-Fi + kernel + root filesystem + systemd + DNS
                       |
          +------------+------------+
          |            |            |
         SSH       Tailscale    Cloudflare
```

A failure above the branch can remove all three access paths simultaneously.
A userspace rollback timer also cannot run if the kernel, root filesystem, or
systemd cannot start.

## Root filesystem limitation

The live root filesystem is a single ext4 image:

```text
/dev/loop1 -> /userdata/rootfs.img
logical size: 16 GiB
filesystem: ext4
```

There is no LVM, Btrfs, ZFS, A/B root slot, or tested initramfs fallback for
atomic rollback. `/userdata` had enough free capacity for a second image during
the audit, but merely copying `rootfs.img` does not provide automatic recovery:
the boot process would still select the broken image, and replacing a mounted
root image is unsafe.

## What can be protected

Before any future attempt, the transaction can be made fail-closed against
several common APT mistakes:

1. Mark OpenSSH, NetworkManager, systemd, systemd-resolved, Tailscale,
   Cloudflare, Docker, and containerd as manually installed.
2. Pre-download every package and dependency needed to restore their current
   versions without network access.
3. Back up `/etc`, dpkg status, APT extended states, package selections, boot,
   recovery, and a filesystem-consistent root image.
4. Use `apt-get --no-remove` so any removal aborts the transaction.
5. Run a fresh simulation and compare it with an approved package manifest.
6. Arm a health-gated timer that checks Wi-Fi, DNS, SSH, Tailscale, Cloudflare,
   Docker, and the public services.

These measures reduce risk but cannot recover a device that fails before
userspace starts. The tested physical recovery path covers that remaining
failure class.

## Controlled upgrade sequence

Do not begin this sequence until the simulated transaction stops removing or
downgrading the Droidian adaptation, Phosh, systemd, networking, and recovery
packages unexpectedly.

1. Correct the Droidian repository configuration and refresh package metadata.
2. Save the complete simulated transaction and review every install, upgrade,
   downgrade, and removal.
3. Verify the known-good boot and recovery images and the commands needed to
   flash them from the physically connected host.
4. Create a filesystem-consistent backup of `/userdata/rootfs.img` while it is
   not mounted, plus `/etc`, dpkg state, and the locally cached recovery
   packages.
5. Confirm SSH, Tailscale, and Cloudflare service enablement and record a
   pre-upgrade health report.
6. Run the approved transaction from a persistent local console, not through a
   remote shell, and retain the full APT log.
7. Reboot once, then verify Wi-Fi, DNS, SSH, Tailscale, Cloudflare, Docker, the
   GUI restoration path, and the public services before accepting the result.
8. If boot or health checks fail, restore the known-good boot/recovery and root
   image using the physically connected host.

## Requirements for a genuinely recoverable upgrade

Use one of these before attempting the distribution upgrade:

### Physical recovery available (current situation)

The phone is physically accessible and its boot/recovery restoration path has
already been used. Before the upgrade, verify the exact known-good artifacts
again and add an offline, filesystem-consistent root-image backup. This is the
recovery method for the first controlled upgrade attempt.

### Tested A/B root-image fallback

Create a second root image, boot the upgrade candidate from that copy, and add
an initramfs-level boot counter that automatically returns to the known-good
image unless userspace records a healthy boot. This must itself be tested while
physical recovery is available before it can be trusted remotely.

An additional SSH daemon, VPN, tunnel, container, or systemd timer is not a
substitute for either option because it remains inside the same shared failure
domain.

## Safe commands for the current system

Metadata refresh is safe:

```sh
sudo apt-get update
```

Review the non-removing plan:

```sh
apt-get --simulate upgrade
```

After the controlled repository repair and validation documented in
[DIST-UPGRADE-EXECUTION-2026-08-28.md](DIST-UPGRADE-EXECUTION-2026-08-28.md),
both ordinary and full upgrade simulations proposed no changes:

```text
0 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.
```

Always inspect, but do not execute, the distribution plan remotely:

```sh
apt-get --simulate full-upgrade
```

Do not convert that final command into a real upgrade until the resolver plan
is corrected and the physical recovery checklist above is complete.
