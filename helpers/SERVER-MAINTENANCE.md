# RMX2001 server maintenance

This runbook records the package-source and recovery rules needed to maintain
the Droidian server without depending on session history.

## Package sources

The supported Droidian source is the package-managed rolling snapshot:

```text
Components: main
Suites: rolling
Uris: droidian+http://releases.droidian.org/
Types: deb
Signed-By: /etc/apt/trusted.gpg.d/droidian.gpg
```

Tailscale uses its official Debian Trixie repository and key. APT network
operations use three retries and 20-second HTTP/HTTPS timeouts through
`/etc/apt/apt.conf.d/80-network-reliability`.

Do not add `production.repo.droidian.org` directly. Droidian constructs the
rolling snapshot from production inputs and applies package masks, drops,
keeps, and update rules. Mixing the raw production archive with a released
snapshot can produce incompatible candidates.

## Upgrade gate

Before any full upgrade:

1. Confirm physical access and verify the known-good boot, recovery, and rootfs
   backups.
2. Save `/etc`, dpkg status, APT extended state, package selections, and APT
   history.
3. Run `sudo apt-get update` and save `apt-get --simulate full-upgrade`.
4. Reject unexpected removals or downgrades of Droidian adaptation, Phosh,
   systemd, networking, boot, or recovery packages.
5. Pre-download the approved transaction and the currently installed versions
   needed for rollback.
6. Use `--no-remove`, retain configuration with `--force-confold`, and arm a
   timed userspace rollback around the package transaction.
7. Validate dpkg, Wi-Fi, DNS, SSH, Tailscale, Cloudflare, Docker, server mode,
   and public services before rebooting.
8. Reboot once and repeat the checks before accepting the result.

SSH, Tailscale, and Cloudflare are not independent recovery paths. They share
the kernel, root filesystem, systemd, DNS, Wi-Fi, and userspace network stack.
Only physical recovery or a tested initramfs-level A/B root-image selector can
recover a failure below userspace.

## Validated repair on 2026-08-28

An ordinary upgrade had partially installed 49 development-channel packages
from a manually added production source. In the mixed state, full upgrade
proposed 31 removals, including Phosh, Phoc, hybris adaptation, and Droidian
desktop metapackages.

The production source was backed up and disabled. The official rolling
snapshot then proposed exactly 49 reversions, zero installs, and zero removals.
Both sides of the transaction were cached and checksummed under
`/userdata/upgrade-backups/`. A 15-minute transient rollback was armed, the
snapshot repair completed, and the rollback was disarmed only after all health
checks passed.

Two subsequent reboots verified:

- headless server mode persisted with Phosh and hardware composer inactive
- NetworkManager, SSH, Tailscale, Cloudflare, and Docker were active
- direct Tailscale SSH and Cloudflare-proxied SSH both connected
- all containers returned to their expected healthy state
- APT reported no pending upgrade, install, downgrade, or removal

The server is aligned with the latest published Droidian 101 rolling snapshot.
Wait for the next curated snapshot instead of forcing development packages into
the current release.

## Cloudflare boot ordering

`network-online.target` can be reached before the local DNS stub answers. The
Cloudflare unit therefore has a drop-in at:

```text
/etc/systemd/system/cloudflared.service.d/10-dns-ready.conf
```

It orders Cloudflare after NetworkManager and systemd-resolved and waits up to
60 seconds for a real DNS answer. After installation, Cloudflare connected on
its first boot attempt, registered all four QUIC connections, and logged no
startup failure.

## Routine checks

```sh
sudo apt-get update
apt-get --simulate upgrade
apt-get --simulate full-upgrade
dpkg --audit
systemctl is-active NetworkManager ssh tailscaled cloudflared docker
docker ps
server mode status
```

Always inspect simulations. Do not turn them into a real package transaction
when the resolver proposes unexplained removals or downgrades.
