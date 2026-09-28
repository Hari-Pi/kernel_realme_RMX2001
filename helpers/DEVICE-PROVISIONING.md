# Post-flash device provisioning (Droidian userspace)

This records userspace changes made directly on the running Droidian device
that are **not** part of this kernel tree and are **not** carried by any
kernel package or release. If the device is ever reflashed or reprovisioned
from scratch, these must be reapplied.

**Install [`adaptation/adaptation-realme-rmx2001`](../adaptation/adaptation-realme-rmx2001)
first.** It applies every fix documented below as one real Debian package
(dpkg diversions + systemd presets, not just idempotent shell), following the
[Droidian porting guide](https://github.com/droidian-releng/docs.droidian.org/blob/main/content/porting-guide/rootfs-creation.md)'s
adaptation-package convention. Built and installed on-device (needs
`dpkg-deb`, so run it on the device itself, not this Mac/CI host):

```sh
./helpers/build-adaptation-deb.sh
sudo apt install ./adaptation-realme-rmx2001_*.deb
sudo reboot
```

[`helpers/setup-rmx2001.sh`](setup-rmx2001.sh) applies the same fixes as a
plain idempotent shell script (checks current state, only changes what's
needed, safe to re-run any time) — no `dpkg`/`apt` bookkeeping, so it's not
tracked as an installed package or cleanly removable, but it's a lighter
option if you don't want to build a `.deb`:

```sh
sudo ./helpers/setup-rmx2001.sh [--user NAME]
sudo reboot
```

The prose below exists to explain *why* each fix exists and to let you apply
one piece by hand if you ever need to. If you add a new device-specific fix
by hand, add it to the adaptation package (or `setup-rmx2001.sh`, whichever
you're maintaining) and this document in the same change — this doc is the
source of truth both are meant to implement, and they drift apart if only one
gets updated.

Everything below targets the Droidian server reachable as `dazai@droidian`.

## `server-mode` toggle script

`/usr/local/sbin/server-mode` (symlinked from `/usr/local/bin/server`, run as
`server mode on|off|status`) toggles the device between headless-server mode
and the Phosh phone GUI. A copy is tracked here at
[`helpers/server-mode.sh`](server-mode.sh) so it survives a reflash; deploy it
with:

```sh
sudo install -o root -g root -m 755 helpers/server-mode.sh /usr/local/sbin/server-mode
```

It was rewritten from its original brute-force form to:

- **Check state before acting.** `unit_table()` reads `LoadState`,
  `ActiveState`, and `UnitFileState` for a whole group of units with one
  `systemctl show` call, instead of forking `systemctl is-enabled`/`is-active`
  once per unit. Masking, unmasking, and starting units, and starting/stopping
  Android HAL services inside the `android` LXC container, all skip units
  already in the desired state and log `<unit> is already <state>` instead of
  reissuing the command.
- **Batch remaining work into single calls.** Units that do need a state
  change are passed to one `systemctl mask/unmask/start ...` invocation
  (systemd handles the whole list without a subprocess per unit), and Android
  HAL state is read and changed with one `lxc-attach` each instead of one per
  service.
- **Run independent steps in parallel.** `run_parallel()` runs the phone-unit
  masking/unmasking, desktop audio, Android HALs, the display on/off sequence,
  and boot-target changes concurrently (they don't depend on each other),
  shows a live `[####----] 2/5 steps done (3s)` progress bar, and prints each
  step's grouped output once everything finishes. Measured result: a full
  `server mode off` restore went from ~87s to ~18s (the remaining time is an
  unavoidable 8-second hardware settle sleep plus the Wayland-socket wait
  inside the display-on sequence, which cannot be parallelized away).
- **Cancel cleanly.** Ctrl+C during `run_parallel` stops every step still
  running (killing each step's actual command, not just its subshell wrapper,
  so nothing is left orphaned) and exits with status 130, instead of leaving
  the terminal or partial background work in a stuck state.

Re-running `mode on` or `mode off` back-to-back was verified to be a near
no-op the second time (every unit reports "already ..." and no
`systemctl mask/unmask/start` call is issued at all), and a real on/off
round-trip was tested live with no change to the known failed-unit baseline
below, aside from the two pre-existing issues discovered while testing (next
section) — both unrelated to this rewrite.

### Two pre-existing issues surfaced while testing the rewrite

Neither of these is caused by the parallel rewrite: both units are pulled in
passively by systemd's own `WantedBy=graphical.target`/`Wants=` dependencies
the moment the graphical target is reached, exactly as they were under the
original serial script — they just hadn't been noticed before because nobody
checked `systemctl --failed` immediately after a mode toggle.

- **`bluebinder.service`** crash-looped with `Failed to open /dev/rfkill: No
  such file or directory`, because this kernel had no RFKILL support at all —
  `/dev/rfkill` didn't exist and `modprobe rfkill` reported "Module rfkill
  not found" (never built, not just unloaded). **Fixed** by enabling
  `CONFIG_RFKILL=y` in [`arch/arm64/configs/RMX2001_defconfig`](../arch/arm64/configs/RMX2001_defconfig)
  (commit `0ae6050bf`) and installing the resulting build — see
  [`rmx2001-magiskboot-kernel-rfkill-20260928`](https://github.com/Hari-Pi/kernel_realme_RMX2001/releases/tag/rmx2001-magiskboot-kernel-rfkill-20260928).
  Verified on-device: `/dev/rfkill` exists, `rfkill list` shows `hci0:
  Bluetooth` unblocked, `bluebinder` logs "Bluetooth initialized
  successfully", and `bluetoothctl show` reports a powered-on controller.
  `bluebinder` was unmasked and re-added to `server-mode.sh`'s `PHONE_UNITS`
  list (it's no longer guaranteed to fail).

  Fixing RFKILL surfaced two further, separate bugs needed to get
  `bluebinder.service` to actually report `active` instead of `failed`:

  1. `/usr/bin/droid/bluebinder_post.sh` (from the `bluebinder` package) had
     `if [ "$bt_addr_file" == "" ]; then` on line 18 — `==` is a bashism, not
     valid in POSIX `[ ]` under `/bin/sh` (dash), and made the script exit
     with "unexpected operator" before it could even check for a real
     address. Fixed directly on the regular writable rootfs (not a dpkg
     conffile, so a package upgrade could silently restore the bug — a
     backup of the original is kept alongside it as
     `bluebinder_post.sh.orig-bashism-bug`):
     ```sh
     sudo sed -i 's/\[ "\$bt_addr_file" == "" \]/[ "$bt_addr_file" = "" ]/' /usr/bin/droid/bluebinder_post.sh
     ```
  2. With that fixed, the script still fails because this device has no
     Bluetooth MAC address available through any of the three Android
     properties it checks (`ro.bt.bdaddr_path`, `ro.vendor.bt.bdaddr_path`,
     `persist.vendor.service.bdroid.bdaddr` were all empty) — a real,
     separate device-porting gap (the actual address likely lives in NVRAM
     and needs a device-specific `droid-get-bt-address.sh`, which doesn't
     exist here). Rather than leave the whole service reporting `failed`
     over a missing persisted address, its exit code was made non-fatal to
     the unit via a systemd drop-in (survives package upgrades cleanly,
     unlike editing the shipped unit file):
     ```sh
     sudo install -d -m 755 /etc/systemd/system/bluebinder.service.d
     sudo tee /etc/systemd/system/bluebinder.service.d/99-ignore-missing-bdaddr.conf <<'EOF'
     [Service]
     ExecStartPost=
     ExecStartPost=-/usr/bin/droid/bluebinder_post.sh
     EOF
     sudo systemctl daemon-reload
     ```
     BlueZ falls back to the controller's own default address
     (confirmed working: `bluetoothctl show` reports a real, valid
     controller address and full profile list). Finding and wiring up this
     device's actual persisted Bluetooth address is separate follow-up work,
     not required for Bluetooth to function.
- **`ModemManager.service`** reliably times out after 90 seconds
  (`start operation timed out`) on every attempt (confirmed 3/3). This device
  will never have a SIM installed, so cellular/SMS is not a feature being
  given up: `ofono.service` and `ModemManager.service` are now masked
  permanently (`systemctl mask --now`) and removed from `server-mode.sh`'s
  `PHONE_UNITS`/`GUI_START_UNITS` lists, so `server mode off` no longer
  unmasks or tries to start them.

  Masking `ModemManager.service` alone left its D-Bus activation file
  (`/usr/share/dbus-1/system-services/org.freedesktop.ModemManager1.service`,
  pointing at the alias unit `dbus-org.freedesktop.ModemManager1.service`)
  still in place, so any app calling `org.freedesktop.ModemManager1` over
  D-Bus — notably **gnome-control-center's WWAN panel, on every single
  Settings launch** — tried to D-Bus-activate a masked unit and got a
  confusing `failed to load properly ... File exists` error instead of a
  fast, clean "service unknown". This was a real, measured contributor to
  Settings feeling slow to open, not just a cosmetic warning. Fixed by
  disabling the D-Bus activation file itself:

  ```sh
  sudo mv /usr/share/dbus-1/system-services/org.freedesktop.ModemManager1.service \
          /usr/share/dbus-1/system-services/org.freedesktop.ModemManager1.service.disabled-no-sim
  sudo systemctl reload dbus.service
  ```

  After this, `busctl status org.freedesktop.ModemManager1` fails
  immediately with a clean `No such device or address` instead of a stalled
  mask conflict, and the WWAN-panel warning no longer appears in
  `gnome-control-center`'s output at all. This file lives on the regular
  writable rootfs (owned by the `modemmanager` package, not a dpkg conffile),
  so a package upgrade could silently restore it — reapply the `mv` above if
  the warning/stall ever comes back.

  **Not yet fully explained:** a headless CPU-usage trace of
  `gnome-control-center` showed its real startup CPU burst finishing in
  roughly 1.5 seconds even before this fix, so this ModemManager stall is a
  confirmed real bug worth having fixed, but it may not fully account for
  what the perceived on-screen slowness feels like when actually watching the
  panel open on the phone. If Settings still feels slow to open after this
  fix, that needs a fresh look with the app open on the real display (a
  headless SSH session can't observe on-screen render timing).

## Vendor overlay mechanism

`/vendor` is a read-only overlay:

```
overlay on /vendor type overlay (ro,relatime,lowerdir=/usr/lib/droid-vendor-overlay:<vendor.img rootfs>)
```

`/usr/lib/droid-vendor-overlay` (owned by the `droidian-quirks-api29` package,
on the regular writable ext4 root) is the highest-priority lower directory, so
any file placed there overrides the matching path from the read-only
`vendor.img`. This is the sanctioned way to patch vendor files on this device
— never remount `/vendor` read-write or modify `vendor.img` directly.

A change under `/usr/lib/droid-vendor-overlay` takes effect after
`sudo mount -o remount /vendor` for anything that re-reads the file at access
time, but services that cached the old content at their own startup (see
below) need to be restarted or the device rebooted.

## Camera provider HAL: removed from the VINTF manifest

**Symptom:** `dmesg` filled with roughly one line per second:

```
init: Received control message 'interface_start' for 'android.hardware.camera.provider@2.4::ICameraProvider/internal/0' from pid: 17 (/system/bin/hwservicemanager)
init: Could not find 'android.hardware.camera.provider@2.4::ICameraProvider/internal/0' for ctl.interface_start
```

**Root cause:** `/vendor/etc/vintf/manifest.xml` declares
`android.hardware.camera.provider@2.4::ICameraProvider/internal/0` as a
required HAL. `hwservicemanager` (pid 17) retries `ctl.interface_start` for
every required-but-missing HAL roughly once a second, forever. On this
Droidian port `camerahalserver` (the service that would back this interface)
has never been wired up (`getprop init.svc.camerahalserver` reports
`stopped`, and `camerahalserver.rc` has no `interface hwbinder ...` binding
for it), so the interface can never start and the retry never stops. This is
driven by `hwservicemanager` reading the manifest, not by any `init.rc`
trigger — there is nothing to fix in `init.rc` itself.

**Fix applied:** added an override manifest with that one `<hal>` entry
removed, instead of touching `vendor.img`:

```
/usr/lib/droid-vendor-overlay/etc/vintf/manifest.xml
```

This is a full copy of the original `/vendor/etc/vintf/manifest.xml` with the
following block deleted:

```xml
<hal format="hidl">
    <name>android.hardware.camera.provider</name>
    <transport>hwbinder</transport>
    <version>2.4</version>
    <interface>
        <name>ICameraProvider</name>
        <instance>internal/0</instance>
    </interface>
    <fqname>@2.4::ICameraProvider/internal/0</fqname>
</hal>
```

A backup of the original, unmodified manifest is kept at:

```
/userdata/kernel-backups/vintf-manifest-backup-20260928T090130Z.xml
```

**To reapply after a from-scratch flash:**

```sh
sudo mkdir -p /usr/lib/droid-vendor-overlay/etc/vintf
sudo cp /vendor/etc/vintf/manifest.xml /usr/lib/droid-vendor-overlay/etc/vintf/manifest.xml
sudo python3 - <<'EOF'
import re
path = "/usr/lib/droid-vendor-overlay/etc/vintf/manifest.xml"
with open(path) as f:
    content = f.read()
pattern = re.compile(
    r'<hal format="hidl">\s*<name>android\.hardware\.camera\.provider</name>.*?</hal>\s*',
    re.DOTALL,
)
new_content, n = pattern.subn("", content, count=1)
assert n == 1, f"expected exactly 1 match, found {n}"
with open(path, "w") as f:
    f.write(new_content)
EOF
sudo mount -o remount /vendor
sudo reboot
```

Verify after reboot:

```sh
dmesg | grep -c ICameraProvider   # expect 0
grep -c camera.provider /vendor/etc/vintf/manifest.xml   # expect 0
systemctl --failed
```

**If camera support is ever wired up for this device**, this override must be
removed (delete
`/usr/lib/droid-vendor-overlay/etc/vintf/manifest.xml`, or restore it from
the backup above) so the real HAL can be declared and started again.

## polkit was masked, causing apt update/install to print a bogus timeout

**Symptom:** every `apt update` (and `apt install`) printed:

```
Error: Timeout was reached
```

interleaved with otherwise-normal output.

**Root cause:** the `packagekit` package installs an apt hook
(`/etc/apt/apt.conf.d/20packagekit`, `APT::Update::Post-Invoke-Success` /
`DPkg::Post-Invoke`) that runs on every `apt update`/install:

```
gdbus call --system --dest org.freedesktop.PackageKit \
  --object-path /org/freedesktop/PackageKit --timeout 4 \
  --method org.freedesktop.PackageKit.StateHasChanged cache-update > /dev/null
```

This D-Bus-activates `packagekitd`. `packagekitd` failed to initialize its
APT backend because `polkit.service` was masked
(`/etc/systemd/system/polkit.service -> /dev/null`, created manually on
2026-08-28, not a stock Droidian default), even though the `polkitd` package
itself was installed. With PackageKit unable to start, the `gdbus` call hung
until its 4-second timeout and printed `Error: Timeout was reached` to
stderr — the hook only redirects the call's **stdout** to `/dev/null`, so the
stderr message leaked straight into apt's output.

**Fix applied:**

```sh
sudo systemctl unmask polkit.service
sudo systemctl start polkit.service
```

This is the root-cause fix (PackageKit's D-Bus call now succeeds instead of
timing out) rather than just silencing the symptom. It also restores normal
polkit-based authorization prompts for anything on the device that expects
them. `polkit.service` is `static` (dependency/D-Bus activated, not directly
enabled), so unmasking it is sufficient — nothing additional needs enabling,
and this survives reboots.

Verify:

```sh
gdbus call --system --dest org.freedesktop.PackageKit \
  --object-path /org/freedesktop/PackageKit --timeout 4 \
  --method org.freedesktop.PackageKit.StateHasChanged cache-update
# expect: () with exit code 0, not "Error: Timeout was reached"
sudo apt update   # expect no "Error: Timeout was reached" line
```

**To reapply after a from-scratch flash:** only needed if whatever masked
`polkit.service` in the first place (unknown — predates this session) is
part of that flash image. Run the two `systemctl` commands above if the
timeout reappears.

## Known pre-existing failed units (not caused by any of the above)

`systemctl --failed` normally reports these units on this device, independent
of kernel version or the manifest change above. They are environment/porting
issues in this Droidian bring-up, not regressions:

- `android-mount.service` — several Android partitions have no valid
  filesystem yet, or are already mounted by the time the unit runs (`oppo_*`,
  `metadata`, `cache`, `nvdata`, `persist`, `protect1/2`, `odm`).
- `dnsmasq.service` — fails with "Address already in use" on port 53; another
  resolver already owns it.
- `droidian-fpd.service` — no `android.hardware.biometrics.fingerprint@2.1`
  HAL is registered.
- `lxc-net.service` — `iptables`/`ip6tables` errors
  (`ip6tables ... table 'nat': Table does not exist`); this kernel's config
  has `CONFIG_IP6_NF_NAT` disabled.
- `nfcd.service` — same pattern as `droidian-fpd`: `binder-wait` reports
  `No such service: android.hardware.nfc@1.1::INfc/default`, i.e. no NFC HAL
  is registered on this port.

These were confirmed byte-identical across boots and kernel versions before
being ruled out as regressions; do not spend time chasing them as kernel
bugs without new evidence.

## GStreamer video decode: droidvdec/droidadec are broken, ranked down

**Symptom:** YouTube (and any other GStreamer-based video, e.g. in
Epiphany/WebKitGTK) did not play at all.

**Root cause:** `decodebin`/`playbin` autoplugging picks the highest-ranked
decoder for a given format, and the `gstreamer1.0-droid` package's
`droidvdec`/`droidadec` elements (a bridge to Android's StageFright video/audio
decode HAL, same family of broken HAL bridges as the camera, fingerprint, and
NFC issues elsewhere in this document) outrank the real hardware decoder.
Confirmed directly with a real downloaded H.264 MP4:

```sh
gst-launch-1.0 -q playbin uri=file:///path/to/real.mp4 video-sink=fakesink audio-sink=fakesink
# ERROR: .../GstDroidVDec:droidvdec0: No valid frames decoded before end of stream
```

GStreamer does not fall back to another decoder once autoplugging has
committed to one, so the whole pipeline fails — the video never plays, rather
than playing slowly. The actual hardware decoder works correctly once
selected:

```sh
GST_PLUGIN_FEATURE_RANK=droidvdec:0,droidadec:0 gst-launch-1.0 -q playbin uri=file:///path/to/real.mp4 video-sink=fakesink audio-sink=fakesink
# selects v4l2h264dec (hardware) + avdec_aac, plays with no errors
```

Confirmed present for both H.264 (`v4l2h264dec`) and VP9 (`v4l2vp9dec` —
YouTube's default codec); both hardware decoder elements exist and are
usable (`/dev/video0`/`/dev/video1` are world-read/write, no permission
issue).

**Fix applied:** ranked `droidvdec`/`droidadec` down to 0 for the whole
graphical session via systemd's `environment.d` mechanism (already used on
this device for one other purpose — see `/etc/environment.d/90qt-a11y.conf`
for precedent):

```
/etc/environment.d/80-gstreamer-video-decode.conf:
GST_PLUGIN_FEATURE_RANK=droidvdec:0,droidadec:0
```

This is read once when the systemd `--user` manager starts (i.e. at
login/session start, not hot-reloadable) — confirmed present with
`systemctl --user show-environment` and confirmed effective by launching a
test pipeline the same way real apps are launched, through
`systemd-run --user` (a plain `runuser -u <user>` shell does **not** inherit
this — it bypasses the systemd user manager entirely, which is a test-harness
gotcha, not a real gap). If this file is ever lost on a reflash, video
playback will silently regress to the broken droid path with no crash or
obvious error pointing back here — check this section first if it recurs.

**Not yet done:** the underlying `gstreamer1.0-droid` HAL bridge itself is
still broken and unused for video, and Firefox has `layers.acceleration
.disabled=true` set device-wide by `droidian-quirks-firefox`'s
`hybris-gpu.js` (a known Mali GPU workaround — the package comment says
enabling it breaks Firefox on Mali GPUs). Firefox therefore almost certainly
has no GPU-accelerated video path at all on this device regardless of the
GStreamer fix above; Epiphany/WebKitGTK (which uses GStreamer for media,
unlike Firefox) is the browser expected to benefit from this fix. Chromium is
not actually installed (only `chromium-sandbox`, a dependency of something
else) so it was not evaluated as an alternative.

## Server mode audit: leftover phone-stack processes and services (2026-09-28)

With this device now running in server mode "for the most part", audited
what was still running that shouldn't be. Two real gaps found and fixed:

- **`audiosystem-passthrough.service`** (bridges PulseAudio to the Android
  audio HAL) kept running in server mode even though `pulseaudio.service`
  was correctly masked. Its unit file only has `After=pulseaudio.service` (a
  weak ordering hint), not a real dependency (`Requires=`/`BindsTo=`), so
  masking pulseaudio never stopped it, leaving it holding the Android audio
  HAL open for no reason. **Fixed in `server-mode.sh`**: added it to the same
  mask/unmask group as `pulseaudio.service`/`pulseaudio.socket`
  (`USER_AUDIO_UNITS`), so it now correctly stops in `mode on` and restarts
  in `mode off`. Verified: process gone after `server mode on`, confirmed
  back as `masked`/`inactive`.
- **`mmsd-tng.service`** (MMS daemon) and **`calls-daemon.service`** (phone
  dialer/call handler) were both running and consuming a small but pointless
  footprint. Since no SIM will ever be used in this device (same reasoning
  as the `ofono`/`ModemManager` decision above), these can never do anything
  useful either. Masked permanently at the user level:
  ```sh
  systemctl --user mask --now mmsd-tng.service calls-daemon.service
  ```
  These are `--user` units (not system units like `ofono`/`ModemManager`),
  so they're not part of `server-mode.sh`'s `PHONE_UNITS` mechanism at all —
  reapply the command above after a reflash if MMS/calls daemons come back.

**Not a bug, left as-is:** `systemctl --user --failed` in server mode also
shows `xdg-desktop-portal-gtk.service`, `xdg-desktop-portal-phosh.service`
(both need a running compositor to attach to, which server mode intentionally
doesn't have), and `fpd-unlockd.service` (downstream of the already-documented
broken fingerprint HAL, see `droidian-fpd.service` above) — none of these
indicate a problem, they're expected consequences of already-known states.

## Upstream Droidian repo audit (2026-09-28)

Checked the actual upstream source repos (not just this device's apt cache)
for the packages touched above, via `gh api repos/droidian/<pkg>/commits`:

- **`bluebinder`** and **`gst-droid`** (source of `gstreamer1.0-droid`):
  this device already runs the latest commit of both
  (`cec1d04`/2024-03-01 and `946765b`/2024-05-18 respectively — confirmed
  these are the top of each repo's commit log). The `==` bashism in
  `bluebinder_post.sh` and the broken `droidvdec`/`droidadec` decode path are
  both still present upstream, unpatched — genuine upstream bugs, not
  staleness in this device's package snapshot. Worth reporting/PRing to
  [droidian/bluebinder](https://github.com/droidian/bluebinder) given how
  trivial the `==` → `=` fix is.
- **A real, usable device-specific example exists** for the "no Bluetooth
  address in any Android property" problem: the official
  [porting guide's debugging tips](https://github.com/droidian-releng/docs.droidian.org/blob/main/content/porting-guide/debugging-tips.md)
  documents a `droid-get-bt-address.sh` mechanism precisely for this case,
  linking a MediaTek example at
  [droidian-devices/adaptation-droidian-angelica](https://github.com/droidian-devices/adaptation-droidian-angelica/blob/droidian/usr/bin/droid/droid-get-bt-address.sh).
  That specific script derives the address from an existing
  `/var/lib/bluetooth/<addr>/` directory rather than reading NVRAM directly,
  so it's a "keep whatever address BlueZ already picked" persistence trick,
  not a general NVRAM reader — not copied here since it wouldn't do anything
  useful before BlueZ has run at least once, and this device's controller
  already gets a stable, working default address without it. Worth
  revisiting only if the address is ever observed changing across reboots.
- **Tried and reverted:** upstream `droidian-quirks-firefox-gpu`
  (available in this device's own apt repo, not installed by default) was
  installed to test re-enabling Firefox's WebRender/GPU acceleration — its
  commit message claims this became safe on Droidian 101, which this device
  runs, contradicting the currently-installed `droidian-quirks-firefox`
  package's own comment that it breaks Firefox on Mali GPUs. Tested directly:
  Firefox segfaulted immediately (`status=11`, minidump generated,
  `[GFX1-]: No GPUs detected via PCI` /
  `vaapitest: VA-API test failed: failed to open renderDeviceFD` in the
  crash log) on this Mali-G76 device. **Removed** — do not reinstall
  `droidian-quirks-firefox-gpu` on this device; the "fixed since 101" claim
  does not hold for this GPU/driver combination. Firefox remains without GPU
  acceleration here (see the GStreamer section above for why Epiphany, not
  Firefox, is the browser expected to benefit from hardware video decode).
- No other apt package updates were pending for droidian-sourced packages at
  audit time (only an unrelated `tailscale` update was available).

## Kernel-log noise still open (not yet addressed)

Found during the same audit, not yet fixed:

- `mtk_axi_interrupt: N callbacks suppressed` and the periodic
  `[name:spm&]` / `[name:bc&]` idle/tick-broadcast dumps — verbose MediaTek
  SPM power-management debug logging left enabled, firing every few seconds.
- `connlog_log_data_handler` / `connlog_ring_emi_to_cache: N callbacks
  suppressed` and `wifi_fw cache is full` — the WCN connectivity log ring
  buffer is never drained by userspace.
- Repeated `healthd: charger: Unknown power supply type` and
  `mtk_pdc_check_charger` / `TCPC-TCPC` battery/charger debug polling every
  ~6 seconds.

GPU (`Mali-G76`, `mali_kbase`) was audited and is clean: no error/warning
output at any log level, DVFS enabled, no thermal throttling observed at
idle.

## Load average is not a reliable signal on this device

`uptime` commonly reports a load average around 25-30 on this 8-core device
even while `vmstat` shows the CPU 90-99% idle. This comes from ~25
always-present MediaTek BSP kernel threads (`wdtk-0..7`, `ccci_fsm1`,
`disp_idlemgr`, `gauge_coulomb_thread`, `tee_scheduler`, etc.) that sit in `D`
state as part of their normal idle-wait loops. Use `vmstat`/`top` CPU
percentages to judge actual load, not the raw load average.
