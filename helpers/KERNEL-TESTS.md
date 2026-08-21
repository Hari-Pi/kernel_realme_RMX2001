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
