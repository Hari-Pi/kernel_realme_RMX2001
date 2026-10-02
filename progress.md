# Realme 6 postmarketOS bring-up progress

Last updated: 2026-10-02 (Asia/Kolkata)

This is the most current engineering snapshot. Older README notes and build
labels may lag behind it. It intentionally excludes account passwords, SSH key
passphrases, and Wi-Fi credentials.

## Current objective

Produce a recovery-installable postmarketOS image for the Realme 6
(`realme-nemo` / RMX2001) with a stable display, working touch input, and a
reliable remote SSH path for continued bring-up.

## Confirmed working

- OrangeFox can install the postmarketOS recovery ZIP without replacing the
  recovery partition.
- The installer targets `userdata` and creates an MBR inside that Android
  partition with:
  - `pmOS_boot`, approximately 236 MiB, ext2.
  - `pmOS_root`, ext4, using the rest of userdata.
- UFS logical sectors are 4096 bytes. The port correctly sets
  `deviceinfo_rootfs_image_sector_size="4096"`.
- The OpenRC root filesystem boots and starts normal system services.
- OpenSSH works with the installed PAM compatibility links and authorized-key
  configuration.
- The mainline 6.16.4 kernel boots to a usable userspace and provides stable
  compute and USB NCM networking.
- The downstream 4.14.141 kernel boots with the vendor MediaTek display and
  touch drivers:
  - `/dev/fb0` exists and reports `mtkfb`.
  - Six `/dev/input/event*` devices are present in the initramfs.
  - The Novatek NT36672C touch controller has previously probed and loaded its
    embedded firmware.
- RNDIS networking works in the downstream-kernel initramfs at
  `172.16.42.1`; the connected host receives `172.16.42.2`.

## Display findings

Two different kernel paths had been conflated by similarly named boot images.
Live diagnostics established the distinction:

### Mainline 6.16.4

- Boots userspace and SSH.
- MediaTek DRM probe fails with:

  ```text
  mediatek-drm ... Invalid display hw pipeline. Last component: 6 (ret=-22)
  ```

- It exposes neither `/dev/dri` nor `/dev/fb0`.
- Xorg correctly fails with `no screens found` because no display device
  exists. LightDM is not the root cause.

### Downstream 4.14.141

- Exposes the vendor framebuffer as `/dev/fb0` (`mtkfb`).
- Exposes the vendor touch input devices.
- This is the current display-and-touch bring-up base.
- Since it has no DRM/KMS device, `deviceinfo_drm` must be `false` and the UI
  must use Xorg with the `fbdev` driver. Phosh/Phoc is not suitable for this
  kernel.

The installed Xorg configuration forces `fbdev` and `/dev/fb0`. It has not yet
been validated after a complete downstream-kernel userspace boot because USB
connectivity is lost during the initramfs-to-root transition.

## Touch findings

- The downstream kernel creates the expected input event nodes during early
  boot.
- The debug-shell on-screen keyboard does not accept touch because the hybrid
  initramfs contains modules for 6.16.4 while the running kernel is 4.14.141;
  `modprobe uinput` therefore fails. This does not prove that the physical
  touchscreen driver is broken.
- An uncommitted kernel change in
  `drivers/input/touchscreen/oppo_touchscreen/touchpanel_common_driver.c`
  ignores framebuffer blank notifications while MediaTek `bypass_blank` is
  active. It must be reviewed and tested after persistent SSH is restored.

## Root filesystem and installer details

The current userdata subpartition table uses 4096-byte sectors:

| Subpartition | Start sector | Byte offset | Purpose |
| --- | ---: | ---: | --- |
| p1 | 2048 | 8,388,608 | `pmOS_boot` |
| p2 | 62464 | 255,852,544 | `pmOS_root` |

The root subpartition size currently used for recovery loop mounting is
54,152,626,176 bytes.

The ext4 `orphan_file` feature was disabled because the OrangeFox 4.14 kernel
cannot mount filesystems containing that feature. The root filesystem now
mounts normally in recovery.

The postmarketOS initramfs discovers nested Android subpartitions by scanning
`userdata`/`system*`, creating a loop device with the sector size from
deviceinfo, and finding filesystems by the `pmOS_boot` and `pmOS_root` labels.

## SSH and USB networking

An earlier SSH fingerprint mismatch was traced to testing the wrong LAN host.
The device at `10.0.0.7` remains online while the phone is in recovery and is
not the Realme 6.

The reliable target is USB networking:

- Mainline kernel: NCM works and SSH is reachable at `172.16.42.1`.
- Downstream kernel: NCM enumerates but does not pass packets.
- Downstream kernel: RNDIS passes packets in the initramfs and exposes the
  debug shell over telnet port 23.

The port now declares:

```sh
deviceinfo_drm="false"
deviceinfo_rootfs_image_sector_size="4096"
deviceinfo_usb_network_function="rndis.usb0"
deviceinfo_usb_network_udc="musb-hdrc"
```

The same values have been written to `/etc/deviceinfo` in the installed root.

## Current blocker

The downstream initramfs RNDIS connection works, but the USB gadget disappears
after `pmos_continue_boot` switches to the OpenRC root filesystem. The
`usb-signaller` service was suspected of reconfiguring the gadget. Its OpenRC
runlevel symlink has now been removed from the mounted root, but a full boot
with persistent RNDIS/SSH has not yet been observed.

The latest automated debug-shell run successfully:

1. Located `pmOS_root` as `/dev/loop1` by filesystem label.
2. Mounted it read-write.
3. Verified the RNDIS, UDC, and DRM deviceinfo overrides.
4. Removed all `usb-signaller` runlevel links.
5. Synced and unmounted the filesystem.
6. Continued boot.

Despite that, the USB adapter disappeared during the root transition. The
next investigation must determine which userspace component unbinds the UDC or
whether the vendor kernel resets the gadget during late initialization.

## Important boot images

| Image | SHA-256 | Kernel | Notes |
| --- | --- | --- | --- |
| Current RNDIS debug image | `c19565cc152b4f8b471e4597de2c58b26a766a4c88884a678db4c332e426c372` | 4.14.141 | RNDIS deviceinfo and `pmos.debug-shell` |
| Saved downstream display image | `f003e5eaa7b5dc30053aee0068939135bc1f02a084b3e673e14929c6306521d8` | 4.14.141 | Source for the RNDIS debug image |
| Previous mainline boot backup | `c74f921e4c2d78b19e4af847f91d0b5dbc1293568c4d9aa72a1637685f4b2a45` | 6.16.4 | Compute works; display pipeline fails |

The current RNDIS debug boot image is stored on the rig at:

```text
C:\Users\hari\realme6-vendor-rndis-debug.img
```

A pre-flash boot backup is stored at:

```text
C:\Users\hari\device-backups\20261002-before-rndis-debug.img
```

## Kernel repository state

- Rig checkout: `/home/dazai/rmx2001-build/kernel_realme_RMX2001` in Ubuntu
  under WSL.
- Repository: `Hari-Pi/kernel_realme_RMX2001`, branch `droidian`.
- Stable framebuffer work is represented by kernel commit `18e1ca2df`.
- The touch blank-notifier change remains uncommitted.
- Other unrelated modifications are present in the kernel worktree and must
  not be overwritten when committing the touch work.

At the 2026-10-02 checkpoint, the rig checkout had two deliberate build-system
changes awaiting commit:

- `debian/kernel-info.mk` records Android OS version `10.0.0`, security patch
  level `2021-08`, and a 33,554,432-byte boot partition. This makes generated
  boot images preserve the stock-compatible header metadata and carry an AVB
  footer at the actual partition size.
- `helpers/build-droidian.sh` corrects the expected immutable builder image ID
  so it matches the SHA-256 digest already pinned in `IMAGE`.

The recovery-safe flashing rule remains: write experimental images only to
`/dev/block/by-name/boot`. Do not write `recovery`, `lk`, `lk2`, `preloader`,
or either vbmeta partition unless a separate, explicitly reviewed procedure
requires it. Back up and hash the current boot partition before every test.

## Installed root configuration

- SSH authorized keys are read from `/etc/ssh/authorized_keys/%u`.
- `StrictModes` is disabled for the current recovery-created key layout.
- PAM compatibility links and `linux-pam` are included by the device package.
- LightDM is allowed to start without a DRM graphical-seat check.
- Xorg is explicitly configured for the `fbdev` driver and `/dev/fb0`.
- `usb-signaller` runlevel links were removed during diagnosis, but that did
  not prevent the downstream USB gadget from disappearing at root switch.

## Reproducible recovery mount geometry

For the currently installed partition table, `pmOS_root` starts at byte offset
255,852,544 and is 54,152,626,176 bytes long inside `userdata`. Recovery can
mount it through a loop device using those exact values. Always verify the
filesystem label before changing files; geometry must be recalculated if the
installer repartitions userdata.

The current filesystem identifiers are:

- `pmOS_boot`: `77fe36f6-5009-4d8d-83ab-cb79045f3032`
- `pmOS_root`: `8f2dcf79-8c4d-45fe-a058-e2411d86d7d1`

The root ext4 filesystem has `orphan_file` disabled for compatibility with the
OrangeFox 4.14 kernel. Its observed features are `has_journal`, `ext_attr`,
`resize_inode`, `dir_index`, `filetype`, `extent`, `64bit`, `flex_bg`,
`sparse_super`, `large_file`, `dir_nlink`, and `extra_isize`.

## Known failure modes to avoid

- A boot image name is not evidence of its kernel. Confirm with `uname -a` or
  extract and hash the image before drawing display conclusions.
- Mainline Xorg cannot be fixed with display-manager settings while the kernel
  exposes neither `/dev/dri` nor `/dev/fb0`.
- The downstream hybrid initramfs must not be treated as a release image: its
  module tree is for 6.16.4 while the running kernel is 4.14.141.
- The on-screen debug keyboard depends on `uinput`; its failure in the hybrid
  image is a module mismatch, not proof that the Novatek touch hardware failed.
- Do not use the LAN address previously tested as `10.0.0.7` for phone SSH; it
  was a different host. Use the USB gadget address and verify its host key.
- Do not enable ext4 `orphan_file` until recovery can mount it reliably.

## Next steps

1. Keep the phone in the RNDIS initramfs debug shell and mount `pmOS_root`.
2. Inspect every OpenRC service and local startup script that references
   configfs, the UDC, `usb0`, RNDIS, NCM, or `usb-signaller`.
3. Disable the exact gadget teardown path, or add an early OpenRC service that
   preserves/recreates `rndis.usb0` before SSH starts.
4. Continue boot and verify persistent ping and SSH at `172.16.42.1`.
5. Capture live downstream-kernel diagnostics:
   - `rc-status -a`
   - `dmesg`
   - `fbset`
   - Xorg and LightDM logs
   - `libinput list-devices` and touch events
6. Start Xorg manually against `/dev/fb0`, then fix LightDM only if Xorg itself
   succeeds.
7. Validate touchscreen coordinates and blank/unblank behavior.
8. Replace the temporary hybrid boot image with a reproducible downstream
   kernel package whose initramfs modules match 4.14.141.
9. Remove `pmos.debug-shell` for release images after SSH is reliable.

## Relevant upstream documentation

- [postmarketOS deviceinfo reference](https://docs.postmarketos.org/pmaports/main/deviceinfo-reference.html)
- [postmarketOS initramfs partition and USB setup](https://gitlab.postmarketos.org/postmarketOS/pmaports/-/blob/master/main/postmarketos-initramfs/init_functions.sh)
- [postmarketOS Android recovery installer](https://gitlab.postmarketos.org/postmarketOS/postmarketos-android-recovery-installer)
