# Post-flash device provisioning (Droidian userspace)

This records userspace changes made directly on the running Droidian device
that are **not** part of this kernel tree and are **not** carried by any
kernel package or release. If the device is ever reflashed or reprovisioned
from scratch, these steps must be reapplied by hand — nothing here happens
automatically.

Everything below targets the Droidian server reachable as `dazai@droidian`.

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

## Known pre-existing failed units (not caused by any of the above)

`systemctl --failed` normally reports these four units on this device,
independent of kernel version or the manifest change above. They are
environment/porting issues in this Droidian bring-up, not regressions:

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

These were confirmed byte-identical across boots and kernel versions before
being ruled out as regressions; do not spend time chasing them as kernel
bugs without new evidence.

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
