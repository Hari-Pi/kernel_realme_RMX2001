# RMX2001 Droidian Porting Status

Last updated: 2026-06-26

This is the cleaned-up handoff for the Realme RMX2001 Droidian bring-up. The short version: the device now boots Droidian with the B65-based hybrid boot image, SSH works, WiFi works after enabling the MediaTek WiFi node, and Phosh/GNOME starts after networking is brought up.

## Current Good Boot Image

Use this image unless explicitly debugging initramfs:

```text
artifacts/boot-hybrid-b65base-normal-v7.img
SHA256: CE5D48E4802398CEB2CD0DD8C84E04DD944CAC08BB540ACE87F1C26A9FFE14C2
```

Image notes:

- Base boot image: B65 stock boot image.
- Replaced components: Droidian kernel, appended kernel DTB, boot-header DTB, and Droidian ramdisk.
- Preserved B65 boot metadata:
  - `os_version=10.0.0`
  - `os_patch_level=2021-08`
  - stock 32 MiB boot partition padding
  - magiskboot VBMETA marker
- Cmdline:

```text
bootopt=64S3,32N2,64N2 buildvariant=userdebug droidian.lvm.prefer systemd.unified_cgroup_hierarchy=0
```

C18 stock-base and directly generated Droidian boot images bootlooped. B65 is the working base because its DTB/kernel layout matches this Droidian kernel much more closely.

## Workspace Layout

Windows note/documentation workspace:

```text
C:\Users\Hari\Projects\Droidian
```

Linux build workspace in WSL Ubuntu:

```text
~/Projects/Droidian/kernel_realme_RMX2001
~/Projects/Droidian/docker-images
~/Projects/Droidian/packages
```

Important repos:

- Kernel: `https://github.com/Hari-Pi/kernel_realme_RMX2001/tree/droidian`
- Droidian porting guide: `https://github.com/droidian/porting-guide`
- Droidian Docker images: `https://github.com/droidian-releng/docker-images`

## Kernel Build

Build container image:

```text
quay.io/droidian/build-essential:current-amd64
```

Persistent container name used during bring-up:

```text
droidian-kernel-build
```

Inside the container, build from `/buildd/sources`:

```sh
cd /buildd/sources
rm -f debian/control
debian/rules debian/control CLANG_CUSTOM=1
RELENG_HOST_ARCH=arm64 releng-build-package
```

Build fixes already applied:

- Removed legacy `debian/compat` because generated `debian/control` already depends on `debhelper-compat (= 13)`.
- Set `KERNEL_BUILD_TARGET = Image.gz-dtb` so the built boot image includes `KERNEL_DTB_SZ`, matching stock layout.
- The required custom clang is available from the kernel repo submodule/path used by the packaging rules.

## Rootfs And Devtools

The Droidian rootfs is installed as:

```text
/data/rootfs.img
```

OrangeFox ZIP flashing of devtools failed because the updater tried to mount `/data/rootfs.img` directly and recovery did not auto-loop-mount it:

```text
mount: '/dev/block/loop0'->... Block device required
E: Unable to mount image
```

Manual devtools install fixed it:

- Explicitly attached `/data/rootfs.img` with `losetup`.
- Mounted it read/write.
- Extracted `payload.tar`.
- Ran `package-sideload` in chroot.
- Fixed `openssh-server` postinst by creating `/android/data/local/tmp`, because `/data` points to `/android/data`.

Verified installed/configured packages:

- `openssh-server`
- `droidian-devtools`
- `hybris-usb`
- `adaptation-hybris-devtools`

## SSH Access

RNDIS SSH worked first:

```sh
ssh droidian@10.15.19.82
```

WiFi SSH now works too:

```sh
ssh droidian@10.0.0.33
```

The host key fingerprint seen during testing:

```text
SHA256:zY5cqH6k2yL4GsGCEs0c+yK9yw0oZJKC9dqdFQVyjTI
```

The Windows warning about `C:\Users\Hari\.ssh\known_hosts` is a local file permission issue on the PC, not a Droidian issue.

## WiFi Bring-Up

The MediaTek WiFi device must be kicked through `/dev/wmtWifi` before NetworkManager can use WiFi:

```sh
echo S | sudo tee /dev/wmtWifi
sudo nmcli radio wifi on
sudo nmcli dev wifi list
sudo nmcli dev wifi connect "SSID" password "PASSWORD"
```

Do not put real WiFi passwords in this repo's docs.

`nmtui` over SSH may fail with:

```text
Could not activate connection: Not authorized to control networking
```

That is PolicyKit treating the SSH session as not locally authorized. Use `sudo nmcli` for now, or add a temporary development PolicyKit rule:

```sh
sudo install -d -m 755 /etc/polkit-1/rules.d
sudo tee /etc/polkit-1/rules.d/49-droidian-networkmanager.rules >/dev/null <<'EOF'
polkit.addRule(function(action, subject) {
    if (action.id.indexOf("org.freedesktop.NetworkManager.") === 0 &&
        (subject.user == "droidian" || subject.isInGroup("sudo"))) {
        return polkit.Result.YES;
    }
});
EOF
sudo systemctl restart polkit NetworkManager
```

## Phosh And Device Fixes

The external helper script was mirrored locally for inspection:

```text
artifacts/external-scripts/droid-script.sh
artifacts/external-scripts/70-denniz.rules
```

The Phosh helper script does these important things:

- Creates a dummy `/usr/lib/droid-vendor-overlay/lib64/hw/gralloc.default.so`.
- Appends ODM mount lines to `/usr/sbin/mount-android.sh`.
- Creates `/usr/bin/device-hacks`.
- Waits for Android property service and MediaTek NVRAM readiness.
- Writes `S` to `/dev/wmtWifi`.
- Sets Android property `wifi.interface wlan0`.
- Marks `wlan1` unmanaged in NetworkManager.
- Enables WoWLAN magic packet on `phy0`.
- Installs/enables `device-hacks.service`.
- Writes `/etc/phosh/phoc.ini` with RMX2001-friendly display scaling.

Safer way to run it on-device:

```sh
sudo apt update
sudo apt install -y curl wget
curl -fsSLo /tmp/droid-script.sh https://raw.githubusercontent.com/NeelamArunkumar/droidian-script/main/droid-script.sh
less /tmp/droid-script.sh
sudo bash /tmp/droid-script.sh
sudo systemctl daemon-reload
sudo systemctl enable --now device-hacks.service
```

The pasted udev command was incomplete:

```sh
wget https://raw.githubusercontent.com/NeelamArunkumar/droidian-script/main/70-denniz.rules -O - | sudo
```

Use this instead:

```sh
wget https://raw.githubusercontent.com/NeelamArunkumar/droidian-script/main/70-denniz.rules -O /tmp/70-denniz.rules
sudo install -m 0644 /tmp/70-denniz.rules /etc/udev/rules.d/70-denniz.rules
sudo udevadm control --reload-rules
sudo udevadm trigger
```

The udev rules mainly set Android-style permissions for binder, hwbinder, vndbinder, GPU, input, audio, camera, modem, MediaTek WiFi, KVM, flashlight, and related device nodes. The WiFi-relevant rules include:

```text
KERNEL=="wmtWifi", OWNER="wifi", GROUP="wifi", MODE="0660"
KERNEL=="fw_log_wifi", OWNER="wifi", GROUP="wifi", MODE="0660"
```

After installing the script and udev rules, reboot:

```sh
sudo reboot
```

Expected result: Droidian boots normally, WiFi can be activated, and Phosh/GNOME starts.

## Debug Images

Keep these around only for recovery/debugging:

```text
artifacts/boot-hybrid-b65base-panic-telnet-v6.img
SHA256: BBF652406EE3269CA06C087E9AD38DAD7551E96F959C96294B9D125835195F9C
```

The v6 image intentionally enters Halium panic telnet:

```text
192.168.2.15:23
```

It proved that:

- `userdata` is visible by partlabel.
- `/data/rootfs.img` exists and is 8 GiB.
- `rootfs.img` mounts read/write.
- `/sbin/init` points to systemd.
- devtools logs and dpkg logs exist inside the rootfs.

The older custom USB gadget images were useful for RNDIS/ACM experiments, but v7 is the normal boot target.

## Known Issues And Next Steps

- Keep using B65 as the boot-image base unless a firmware-specific DTB reason appears.
- Convert the useful parts of `droid-script.sh` into proper adaptation packaging later instead of relying on a remote script.
- Turn the `/dev/wmtWifi` activation into a packaged systemd service or keep `device-hacks.service`.
- Replace the temporary NetworkManager PolicyKit rule with the least-permissive rule needed for the final user/session model.
- Investigate display/compositor stability now that Phosh/GNOME starts.
- Check suspend/resume and WiFi persistence after the WoWLAN setting is active.
