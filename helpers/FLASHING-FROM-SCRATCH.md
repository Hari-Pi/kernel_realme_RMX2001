# Flashing Droidian on the Realme 6 (RMX2001) from scratch

## Demo

See Droidian running on this device first:
[Realme 6 Droidian project page](https://hari-pi.com/projects/kernel-realme-rmx2001.html)
([demo video direct link](https://hari-pi.com/media/realme6-droidian-demo.mp4)).

## What you need

- A Windows PC (SP Flash Tool and MTK Bypass both target Windows)
- A Linux host for the final RNDIS setup step
- USB cable
- [MTK Bypass Utility](https://github.com/MTK-bypass/bypass_utility)
- [SP Flash Tool](https://spflashtool.com/)
- B.56 baseline firmware for the RMX2001 — download from
  [this Telegram post](https://t.me/rm6785dumppAss/1082)
- [LKPatcher](https://github.com/R0rt1z2/lkpatcher)
- A custom recovery image — [OrangeFox](https://orangefox.download/release/610bd249dfa9fd3c4edb5814)
  is what this guide uses; any equivalent recovery.img works
- This repo's [validated kernel release](https://github.com/Hari-Pi/kernel_realme_RMX2001/releases)
  (`boot.img`)
- The [fixed recovery-flashable devtools zip](https://github.com/Hari-Pi/kernel_realme_RMX2001/releases/tag/rmx2001-recovery-api29-loopmount-fixed)
  from this repo, plus the official upstream `api29` zip

Read every step before starting. Unlocking the bootloader and reflashing
firmware on a MediaTek device carries real bricking risk if a step is
skipped or done out of order.

## 1. Get on B.56 firmware

The unlock/patch steps below are only validated against the B.56 baseline.
Download it from the link above and keep it accessible to SP Flash Tool.

## 2. Bypass MTK auth, then flash B.56 with SP Flash Tool

MediaTek's BROM/preloader authentication normally blocks SP Flash Tool from
talking to the device. Use MTK Bypass Utility first to get the device into a
state SP Flash Tool can flash:

1. Run MTK Bypass Utility, follow its instructions to put the device into
   BROM mode and bypass auth.
2. With the device still connected, open SP Flash Tool, load the B.56
   firmware's scatter file, and flash it (download-only, not format).

## 3. Patch the B.56 lk, and flash a custom recovery

1. Run LKPatcher against the `lk` (little kernel / bootloader) partition
   image extracted from the B.56 firmware you just flashed, to produce a
   patched `lk.img` with bootloader restrictions lifted.
2. Flash the patched `lk.img` via fastboot:
   ```sh
   fastboot flash lk lk.img
   ```
3. Alongside it, flash your chosen recovery image (OrangeFox or equivalent):
   ```sh
   fastboot flash recovery recovery.img
   ```

## 4. Format data

Boot into the newly flashed recovery and format `data` (not just a cache
wipe — a full format, since the encryption state changes across this whole
process). Do this before flashing anything else.

## 5. Flash the Droidian boot image and rootfs zips

Still in recovery/fastboot:

```sh
fastboot flash boot boot.img
```

using a `boot.img` from this repo's
[Releases](https://github.com/Hari-Pi/kernel_realme_RMX2001/releases) (the
`rmx2001-magiskboot-kernel-rfkill-20260928` release or newer — check for a
more recent validated release first).

Then, from recovery's sideload/install menu:

1. Flash the official upstream `droidian` `api29` zip.
2. Flash this repo's
   [loop-mount-fixed devtools zip](https://github.com/Hari-Pi/kernel_realme_RMX2001/releases/tag/rmx2001-recovery-api29-loopmount-fixed)
   — the stock devtools zip fails to loop-mount its rootfs payload in
   recovery on this device; this build fixes that.

## 6. Reboot and connect

Reboot. First boot will take a while. Continue setup from a Linux host over
USB RNDIS — see
["Connect over USB and enable Wi-Fi"](../README.md#connect-over-usb-and-enable-wi-fi)
in the main README.

## After first boot

Once you have SSH/Wi-Fi:

1. Flash a validated kernel from this repo's
   [Releases](https://github.com/Hari-Pi/kernel_realme_RMX2001/releases) if
   you haven't already, following
   [`KERNEL-BUILD-AND-TEST.md`](KERNEL-BUILD-AND-TEST.md).
2. Run the [Quick start one-liner](../README.md#quick-start-already-flashed-device)
   to install every device-specific fix (adaptation package) and bring up
   Phosh in one command.
