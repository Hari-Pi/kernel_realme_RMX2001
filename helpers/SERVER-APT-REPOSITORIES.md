# Droidian server APT repositories

This file records the repository configuration and transport checks performed
on the RMX2001 server on 2026-08-28. It contains no credentials and does not
replace the package-managed Droidian configuration.

## Current operating system

```text
Droidian 101 (2025-11-30)
Debian-compatible suite: trixie
Architecture: arm64
```

## Active Droidian repositories

### Production channel

The manually added production source is:

```text
/etc/apt/sources.list.d/droidian-production.sources
```

```deb822
Types: deb
Uris: https://production.repo.droidian.org/
Suites: trixie
Components: main
Signed-By: /etc/apt/trusted.gpg.d/droidian.gpg
```

The URL returned a signed `trixie/InRelease` successfully over HTTPS and its
arm64 package index was accepted by APT.

### Rolling snapshot

The original rolling source remains active through a package-managed symlink:

```text
/etc/apt/sources.list.d/droidian-snapshot.sources
  -> /usr/share/droidian-apt-config/sources.list.d/droidian-snapshot.sources
```

Its effective configuration is:

```deb822
Components: main
Suites: rolling
Uris: droidian+http://releases.droidian.org/
Types: deb
Signed-By: /etc/apt/trusted.gpg.d/droidian.gpg
```

`droidian+http` is Droidian's snapshot-aware APT transport. During an update it
resolved to `http://releases.droidian.org/snapshots/current/`.

The production source was added alongside the rolling snapshot; it did not
replace or disable the package-managed source. Both currently have Droidian's
priority 1002 through `/etc/apt/preferences.d/10-droidian`.

## Upgrade safety finding

A normal metadata refresh succeeds against both Droidian repositories and the
Tailscale repository. No packages were installed during this investigation.

The two upgrade modes do not currently have the same safety profile:

```text
apt-get --simulate upgrade
0 upgraded, 0 newly installed, 0 to remove and 14 not upgraded
```

```text
apt-get --simulate full-upgrade
6 upgraded, 8 newly installed, 31 to remove and 5 not upgraded
```

The simulated full upgrade removes Droidian Phosh metapackages, the hybris
hardware adaptation, Phosh, Phoc, GNOME components, and other phone UI packages
while combining production packages with rolling dependencies. It does not
propose changing either locally installed RMX2001 kernel package.

Until the Droidian channel transition is deliberately resolved:

- do not run `apt full-upgrade`, `apt-get dist-upgrade`, or an unattended
  equivalent
- do not approve removals of Droidian adaptation or Phosh packages
- refresh metadata with `apt-get update`
- inspect candidate changes with `apt-get --simulate upgrade`
- simulate any larger transition and review every removal first
- do not manually delete the snapshot symlink without understanding how
  `droidian-apt-config` manages it

## Tailscale repository

The active source is:

```text
/etc/apt/sources.list.d/tailscale.list
```

```text
deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/debian trixie main
```

This file was byte-compared with Tailscale's official
`trixie.tailscale-keyring.list` and matched exactly. The installed key was also
byte-identical to Tailscale's official `trixie.noarmor.gpg` file:

```text
3e03dacf222698c60b8e2f990b809ca1b3e104de127767864284e6c228f1fb39
```

The installed and candidate Tailscale version was `1.102.3` during the audit.
The official repository instructions are available at
<https://pkgs.tailscale.com/stable/>.

## Timeout investigation

No persistent repository failure was reproduced.

- five direct IPv4 HTTPS requests completed in about 0.40 to 0.45 seconds each
- a normal full `apt-get update` fetched Tailscale's signed metadata in about
  one second
- an isolated cold-cache Tailscale APT refresh completed in five seconds
- the same cold-cache refresh with forced IPv4 completed in seven seconds
- the repository source and signing key matched Tailscale's official files
- `tailscaled` was active, UDP connectivity worked, and the nearest DERP was
  Bengaluru at approximately 28 ms

Wi-Fi deliberately has IPv6 disabled. Tailscale's CDN publishes IPv6 addresses,
but forcing APT to IPv4 did not improve the result, so no `ForceIPv4` override
was added.

System logs contained brief `systemd-resolved` failures while services were
starting at boot, including `server misbehaving` and `no such host`. There was
no retained APT log proving a Tailscale-specific timeout. The most likely cause
was a transient DNS or CDN path failure during startup rather than an invalid
repository.

## APT transport resilience

The following bounded retry configuration was installed:

```text
/etc/apt/apt.conf.d/80-network-reliability
```

```aptconf
Acquire::Retries "3";
Acquire::http::Timeout "20";
Acquire::https::Timeout "20";
```

This lets APT recover from a short DNS/CDN failure without hanging indefinitely.
It does not force an address family, change package candidates, or install
packages. A complete `apt-get update` succeeded after installation.

## Diagnostic commands

Show every active source, including symlinks:

```sh
find /etc/apt -maxdepth 3 \( -type f -o -type l \) \
  -printf '%y|%p|%l\n' | sort
apt-get indextargets \
  --format '$(IDENTIFIER)|$(SITE)|$(RELEASE)|$(COMPONENT)|$(ARCHITECTURE)'
```

Refresh metadata and inspect package candidates:

```sh
sudo apt-get update
apt-cache policy
apt-get --simulate upgrade
apt-get --simulate full-upgrade
```

Test the exact repository metadata URLs:

```sh
curl -4 -fsS -o /dev/null --connect-timeout 8 --max-time 20 \
  -w 'HTTP %{http_code}, %{time_total}s\n' \
  https://production.repo.droidian.org/dists/trixie/InRelease

curl -4 -fsS -o /dev/null --connect-timeout 8 --max-time 20 \
  -w 'HTTP %{http_code}, %{time_total}s\n' \
  https://pkgs.tailscale.com/stable/debian/dists/trixie/InRelease
```

Check Tailscale transport independently of APT:

```sh
systemctl is-active tailscaled
tailscale status
tailscale netcheck
```
