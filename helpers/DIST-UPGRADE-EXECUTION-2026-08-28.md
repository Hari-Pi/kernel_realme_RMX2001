# Droidian package upgrade recovery - 2026-08-28

This is the execution record for repairing and validating the RMX2001 server's
Droidian package state. No kernel or boot image was changed.

## Initial state

The server was healthy, but a manually added direct source pointed at:

```text
https://production.repo.droidian.org/ trixie main
```

At 06:12 local time, `apt-get upgrade` had already installed 49 packages from
that development channel. The package-managed Droidian 101 rolling snapshot
remained enabled at the same time. A simulated full upgrade in this mixed state
proposed 31 removals, including Phosh, Phoc, the hybris Phosh adaptation, and
Droidian desktop metapackages.

The direct production source is not part of the installed
`droidian-apt-config` source set. Droidian's rolling snapshot is curated from
production inputs and applies package masks, drops, keeps, and update rules.
Mixing the raw production archive into a released snapshot bypassed those
rules.

## Recovery preparation

Before changing packages, the following were saved under a timestamped
directory in `/userdata/upgrade-backups/`:

- complete installed-package and manual/automatic package manifests
- dpkg status and APT extended state
- APT, NetworkManager, SSH, systemd, and Cloudflare configuration
- APT history and the complete simulated transaction
- all 49 currently installed development-channel packages
- all packages needed for the stable snapshot transaction
- SHA-256 manifests for both package sets

The existing physical rootfs, boot, and recovery restoration path remained the
hard fallback.

## Resolver correction

The unowned direct production source was backed up and disabled. After an APT
metadata refresh, the official rolling snapshot proposed:

```text
0 upgraded, 0 newly installed, 49 downgraded, 0 to remove and 0 not upgraded.
```

Those 49 changes reversed the packages installed by the earlier partial
development-channel upgrade. The plan did not touch OpenSSH, NetworkManager,
wpasupplicant, systemd, systemd-resolved, Tailscale, Cloudflare, Docker, or
containerd.

## Transaction safeguards

The repair used `--allow-downgrades`, `--no-remove`, noninteractive operation,
and `--force-confold`. PackageKit was runtime-masked for the maintenance window
so it could not compete for dpkg's lock.

A 15-minute transient systemd timer was armed before the transaction. If the
health checks did not complete, it would reinstall the cached pre-repair
package set. The timer was disarmed only after all checks passed.

## Post-transaction validation

The following passed before reboot:

- `dpkg --audit` returned no issues
- simulated full upgrade returned no pending actions
- `sshd -t` passed
- NetworkManager, SSH, Tailscale, Cloudflare, and Docker were active and enabled
- DNS resolution and Tailscale status worked
- every Docker container was running, with all defined health checks healthy

## Boot validation

The server was rebooted twice. The final verified state was:

```text
configured mode: on
default target: multi-user.target
phosh: inactive
hardware composer: inactive
display brightness: 0
```

NetworkManager, SSH, Tailscale, Cloudflare, and Docker all returned active.
Direct Tailscale SSH and Cloudflare-proxied SSH both connected successfully.
TunnelTerm and Nextcloud returned HTTP 200 externally, while TunnelPane returned
its expected HTTP 401 authentication challenge. All Docker health checks passed
and APT reported:

```text
0 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.
```

## Cloudflare boot ordering

On the first reboot, `network-online.target` was reached before the local DNS
stub could answer queries. Cloudflare recovered through its restart policy, but
only after two failed starts.

A systemd drop-in now orders Cloudflare after NetworkManager and
systemd-resolved and uses an `ExecStartPre` loop to wait up to 60 seconds for a
real DNS answer. This was installed behind a five-minute transient rollback,
tested with a live service restart, and validated by the second reboot.
Cloudflare then connected on its first attempt, registered all four QUIC
connections, and logged zero startup failures.

## Current upgrade status

The server is now aligned with the latest published Droidian 101 rolling
snapshot. There is no newer safe distribution transaction currently offered by
that snapshot. The direct production archive must not be re-enabled to force a
future snapshot early; wait until Droidian publishes the next curated rolling
snapshot, then repeat the simulation and recovery gates.
