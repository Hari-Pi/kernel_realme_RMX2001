# Kernel package test log

## 2026-08-21: MagiskBoot-preserved package

- Source commit: `73c0d48656d83c6133b1913b74f8ac485605a471`
- Package version: `0.0.0+magiskboot.git20260821140314.73c0d48656d8`
- Package SHA-256: `9aa68a12cee8d868a5fa6a0fceb81709797a508eb496f124309572ae30e8c948`
- Installed boot SHA-256: `befcdf3e000d008723bacc2feacc5fbc7ad09e2c8d4be85790182c4167cf6f31`
- Preserved recovery SHA-256: `55d75023630495d2f9018d46b8fd836bca8eae66b2ee9c251a21ca09338806f6`
- Kernel marker: `RMX2001 idle-log-v2-official 2026-08-21`

The package was audited before installation. It contains only the boot image
and documentation, writes only `/dev/disk/by-partlabel/boot`, and preserves the
stock ramdisk, DTB, and kernel DTB byte-for-byte. Its pre-install backup and
post-write checksum checks passed on the RMX2001.

The device rebooted successfully into the packaged kernel. Wi-Fi, SSH, Docker,
Cloudflare, and all deployed containers returned healthy. The boot partition
retained the candidate hash and recovery was unchanged. A timed userspace
rollback guard was armed for the test and removed after the healthy soak.

No kernel panic or oops was observed. Existing V4L2 plugin startup traces and
pre-existing failed Android compatibility units remained. The optimization is
incomplete: the separate `[mcdi]mcdi cpu:` status message still appears every
five seconds and should be traced to its actual call site in the next change.

## 2026-08-28: Stability baseline

The device was audited read-only after a later reboot and 1 day 12 hours of
continuous uptime. The installed boot package passed `dpkg -V`. The boot image,
boot partition, recovery partition, and verified stock rollback backups retained
their expected SHA-256 hashes.

- Boot package: `0.0.0+magiskboot.git20260821140314.73c0d48656d8`
- Boot SHA-256: `befcdf3e000d008723bacc2feacc5fbc7ad09e2c8d4be85790182c4167cf6f31`
- Recovery SHA-256: `55d75023630495d2f9018d46b8fd836bca8eae66b2ee9c251a21ca09338806f6`
- Stock rollback boot SHA-256: `ce5d48e4802398ceb2cd0dd8c84e04dd944cac08bb540ace87f1c26a9ffe14c2`

NetworkManager, SSH, Docker, and Cloudflare were active. All 11 intended
containers were running, including healthy application containers. The public
terminal and Nextcloud returned HTTP 200; the file service correctly returned
HTTP 401 before authentication. No panic, oops, lockup, or call trace was found
in the current boot.

The load average remains near 28 because 28 MediaTek vendor kernel threads are
permanently accounted in uninterruptible sleep. CPU, I/O, and memory pressure
were low, so this value does not represent actual saturation. Four enabled but
failed units were recorded without modification: `android-mount.service`,
`dnsmasq.service`, `droidian-fpd.service`, and `lxc-net.service`. One unrelated
one-shot Docker build container, `focused_cray`, remains exited from August 20.

Known recurring log noise remains: the `[mcdi]mcdi cpu:` report every five
seconds, camera-provider lookup failures every second, and charger diagnostics
roughly every six seconds. These are the next optimization targets; they are not
new regressions from the packaged kernel.

## 2026-08-28: MCDI heartbeat and BBR/fq kernel

- Source commit: `2b74e274ae46ae37507fe859fb61e8e521bf413f`
- Package version: `0.0.0+magiskboot.git20260827231134.2b74e274ae46`
- Package SHA-256: `a2b988a35db4b0ccfad2cf0b0919a0546ae14a55f7e7abca241b1720195b5f97`
- Raw kernel SHA-256: `fdcbce397d7dae0e38871d765830e428d50085b43d2873d759c451077bc6cb92`
- Installed boot SHA-256: `0b7d5682dc120a26acb307dc38e590f470d4b9d3c8731d7c55f23dc32b408fea`
- Preserved recovery SHA-256: `55d75023630495d2f9018d46b8fd836bca8eae66b2ee9c251a21ca09338806f6`
- Predecessor boot SHA-256: `befcdf3e000d008723bacc2feacc5fbc7ad09e2c8d4be85790182c4167cf6f31`
- Verified backups: `/userdata/kernel-backups/20260827T233552Z/{boot-v2.img,recovery.img}`
- Kernel marker: `RMX2001 mcdi-v3-bbr-fq 2026-08-28`

This kernel carries two source changes on top of the tested v2 image: the MCDI
heartbeat threshold moves from 5 seconds to 5 minutes, and `CONFIG_TCP_CONG_BBR`,
`CONFIG_NET_SCH_FQ` and `CONFIG_NET_SCH_FQ_CODEL` are built in. The networking
options are additive only. `CONFIG_DEFAULT_TCP_CONG` stays `bic` and
`CONFIG_NET_SCH_DEFAULT` stays unset, so boot behaviour is unchanged and the
device kept using cubic and pfifo_fast until a sysctl was changed deliberately.

The build required re-pinning `linux-packaging-snippets` from
`45+git20260713160329.54d2db9.next.production` to
`49+git20260824222026.46633f1.next.production`. The old version had been removed
from every suite and from the pool of Droidian's production archive, so the
build aborted during `apt-get install`. Before adopting the new pin, the v2
source commit was recompiled under snippets 49 and compared against the
2026-08-21 kernel. Both images were 32,499,724 bytes and differed in 76 bytes
across the same eight regions that already differ between two builds of
identical source, so the pin change does not alter kernel output. These builds
are not bit-reproducible: `scripts/mkcompile_h` embeds a build timestamp and the
container hostname.

The package guard was extended to accept the tested v2 image as a second
predecessor alongside stock, and to verify its rollback backup against whichever
of the two is actually present. Arbitrary current hashes are still refused.

The package was audited before installation. It contains only the boot image and
documentation, writes only `/dev/disk/by-partlabel/boot`, and preserves the stock
ramdisk, DTB, and kernel DTB byte-for-byte. Boot and recovery were backed up and
verified first. A health-gated rollback timer was armed before the write.

The device rebooted successfully into the packaged kernel. The rollback guard
fired two minutes after boot, found Docker, NetworkManager, SSH, all 11
containers healthy and no kernel faults, and disarmed itself without acting. The
boot partition retained the candidate hash and recovery was unchanged. No panic,
oops, lockup, or call trace was observed.

The MCDI optimization is confirmed: `[mcdi]mcdi cpu:` now appears once per five
minutes instead of once every five seconds, cutting that source from 17,079 to
roughly 288 lines per day. `bbr` is present in
`tcp_available_congestion_control`, and `fq` and `fq_codel` both attach
successfully. BBR and fq were subsequently enabled via
`/etc/sysctl.d/99-headless.conf`.

Remaining log noise is unchanged and dominated by two sources that this kernel
does not address: the camera provider lookup failures at about 2.0 lines per
second, and the charger diagnostics at about 2.0 lines per second combined. The
charger path also drives the highest non-timer interrupt load and is the best
candidate for the next kernel change.

Unrelated to this kernel, the device was moved from the `TATA-2.4` access point
to `NETGEAR 703` during the same session. Duplicate ICMP replies previously seen
on `wlan0` were caused by that weak, congested 2.4 GHz link and stopped entirely
after the move. Any log comparison against earlier entries should account for the
changed LAN address.
