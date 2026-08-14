#!/bin/sh
# headless-optimize.sh
#
# Converts a fresh Droidian install on the Realme RMX2001 into a lean,
# SSH-only headless box: no GUI boot, dead/unused hardware daemons masked,
# and the OLED panel forced off at boot instead of being left stuck on
# whatever the bootloader/Plymouth last drew to it.
#
# Run once after a fresh flash/format, as the droidian user, with sudo
# available. Idempotent - safe to re-run.
#
#   chmod +x headless-optimize.sh
#   ./headless-optimize.sh
#
# A reboot is required at the end: the default-target change, Plymouth
# removal, and the display power-off cycle only take effect at boot.

set -e

echo "== 1/15: killing the modem stack (ofono2mm crash-loops with no SIM in use) =="
sudo systemctl mask --now ofono ModemManager

echo "== 2/15: switching to text-mode boot, no Phosh GUI =="
sudo systemctl set-default multi-user.target
sudo systemctl disable phosh

echo "== 3/15: masking unused phone-hardware services =="
sudo systemctl mask --now \
  cups cups-browsed cups.socket cups.path \
  bluetooth bluebinder \
  nfcd \
  geoclue iio-sensor-proxy sensorfwd \
  openvpn strongswan-starter \
  lm-sensors vnstat \
  udisks2 accounts-daemon \
  NetworkManager-wait-online \
  polkit upower
sudo systemctl disable --now apt-daily.timer apt-daily-upgrade.timer

echo "== 4/15: disabling the Plymouth boot splash =="
sudo systemctl mask plymouth-start.service

echo "== 5/15: installing early best-effort framebuffer blank =="
sudo tee /usr/lib/systemd/system/blank-display.service > /dev/null <<'EOF'
[Unit]
Description=Blank display and kill backlight (headless server, prevent OLED burn-in)
DefaultDependencies=no
After=local-fs.target
Before=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c "echo 1 > /sys/class/graphics/fb0/blank 2>/dev/null; echo 0 > /sys/class/leds/lcd-backlight/brightness 2>/dev/null; true"

[Install]
WantedBy=multi-user.target
EOF

echo "== 6/15: installing the real display power-off cycle =="
# The bootloader/Plymouth draw the panel via a hardware overlay plane that
# only gets released once something real (phoc, via the hwcomposer HAL)
# takes ownership of the display and issues an explicit power-off. Nothing
# else on a headless box ever does that, so without this the panel is
# stuck showing whatever was last drawn, forever. This briefly brings up
# Phosh purely to grab the panel and turn it off, then tears it back down.
sudo tee /usr/local/sbin/display-poweroff.sh > /dev/null <<'EOF'
#!/bin/sh
set -e

systemctl start phosh

for i in $(seq 1 40); do
  [ -S /run/user/32011/wayland-0 ] && break
  sleep 0.5
done

sleep 8

su -s /bin/sh droidian -c "XDG_RUNTIME_DIR=/run/user/32011 WAYLAND_DISPLAY=wayland-0 wlr-randr --output HWCOMPOSER-1 --off" || true

systemctl stop phosh || true
systemctl stop android-service@hwcomposer || true

# phosh's ExecStartPost does `chvt 7`, which kills getty@tty1's session -
# bring local console login back so it doesn't stay dead after every boot.
systemctl restart getty@tty1 || true

exit 0
EOF
sudo chmod +x /usr/local/sbin/display-poweroff.sh

sudo tee /usr/lib/systemd/system/display-poweroff.service > /dev/null <<'EOF'
[Unit]
Description=Power off display panel at boot (headless server - prevent OLED burn-in/wasted power)
After=lxc@android.service
Wants=lxc@android.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/display-poweroff.sh
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable display-poweroff.service

echo "== 7/15: enabling zram swap (device ships with none at all) =="
sudo tee /usr/lib/systemd/system/zram-swap.service > /dev/null <<'EOF'
[Unit]
Description=Set up zram-backed swap (headless, no swap partition available)
DefaultDependencies=no
After=local-fs.target
Before=multi-user.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c "echo lz4 > /sys/block/zram0/comp_algorithm && echo 2G > /sys/block/zram0/disksize && /sbin/mkswap /dev/zram0 && /sbin/swapon --priority 100 /dev/zram0"
ExecStop=/sbin/swapoff /dev/zram0

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable zram-swap.service

# page-cluster=0 matters most here: the default reads swap in 8-page
# batches, which is right for a spinning disk and wasteful for RAM-backed
# zram. swappiness=100 looks aggressive but is correct with zram, since
# swapping to compressed RAM is cheaper than dropping page cache.
sudo tee /etc/sysctl.d/99-headless.conf > /dev/null <<EOF
vm.swappiness = 100
vm.page-cluster = 0
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
EOF
sudo sysctl --system > /dev/null 2>&1

echo "== 8/15: pinning CPU governor to performance =="
# Verified stable at 37-44C under this on the RMX2001's MT6785 with no
# active cooling - well below throttle territory. Re-check thermals if
# running this on different hardware before trusting it long-term.
sudo tee /usr/lib/systemd/system/cpu-performance.service > /dev/null <<EOF
[Unit]
Description=Pin CPU governor to performance (headless server, thermal headroom verified)
DefaultDependencies=no
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c "for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > \$g; done"

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable cpu-performance.service

echo "== 9/15: capping journald =="
sudo mkdir -p /etc/systemd/journald.conf.d
sudo tee /etc/systemd/journald.conf.d/99-cap.conf > /dev/null <<EOF
[Journal]
SystemMaxUse=64M
RuntimeMaxUse=32M
ForwardToSyslog=no
EOF
sudo systemctl restart systemd-journald

echo "== 10/15: TCP congestion control - bic (2006-era default) to cubic =="
sudo tee -a /etc/sysctl.d/99-headless.conf > /dev/null <<EOF
net.ipv4.tcp_congestion_control = cubic
EOF
sudo sysctl --system > /dev/null 2>&1

echo "== 11/15: masking PulseAudio (no audio use on a headless box) =="
# Socket-activated with Accept=no, so it self-starts on every login even
# though nothing ever plays audio. Masked per-user, persists via
# ~/.config/systemd/user/ symlinks, survives reboot and new sessions.
systemctl --user mask --now pulseaudio.service pulseaudio.socket 2>/dev/null || true

echo "== 12/15: stopping unused Android HAL services (camera/NN/RIL) =="
# /vendor and /system are mounted read-only (this device enforces
# dm-verity at the bootloader stage), so their init.rc files are never
# edited. Instead this uses Android's own `stop` command via lxc-attach
# on every boot - fully reversible, never touches the protected
# partitions. Verified individually: each service stays down with no
# auto-respawn, and lxc@android/Wi-Fi/SSH are unaffected by any of them.
sudo tee /usr/local/sbin/android-hal-trim.sh > /dev/null <<'EOF'
#!/bin/sh
set -e

for svc in \
  camerahalserver \
  neuralnetworks_hal_service_gpunn \
  neuralnetworks_hal_service_neuron_ann \
  camera_service \
  mediaextractor \
  vendor.ril-daemon-mtk
do
  lxc-attach -n android -- /system/bin/stop "$svc" 2>/dev/null || true
done

exit 0
EOF
sudo chmod +x /usr/local/sbin/android-hal-trim.sh

sudo tee /usr/lib/systemd/system/android-hal-trim.service > /dev/null <<EOF
[Unit]
Description=Stop unused Android HAL services (camera/NN/RIL - headless server)
After=lxc@android.service
Requires=lxc@android.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/android-hal-trim.sh
TimeoutStartSec=30

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable android-hal-trim.service

echo "== 13/15: mount options + IO scheduler =="
# /userdata ships with `discard` (inline TRIM on every unlink) while
# fstrim.timer is also enabled - redundant work. Measured on this device:
# deleting 400 files took ~293ms with discard, ~140ms without. TRIM still
# happens, just batched weekly by fstrim instead of inline.
#
# noatime drops atime metadata writes; commit=60 flushes the journal less
# often (costs up to 60s of writes on a hard power loss - acceptable here,
# the device is permanently on charge).
#
# loop1 (the rootfs.img loop device) gets scheduler `none`: the underlying
# UFS device already schedules, so mq-deadline on top is duplicated work.
#
# NOT fixable here: `nodelalloc` and `data=journal` reject remount and are
# set by boot.img's initramfs - see closing notes.
sudo tee /usr/lib/systemd/system/mount-tuning.service > /dev/null <<'EOF'
[Unit]
Description=Apply tuned mount options and IO scheduler (headless server)
After=local-fs.target
Wants=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c "mount -o remount,noatime / 2>/dev/null; mount -o remount,nodiscard,noatime,commit=60 /userdata 2>/dev/null; echo none > /sys/block/loop1/queue/scheduler 2>/dev/null; true"

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable mount-tuning.service

echo "== 14/15: network tuning =="
# Wi-Fi power save parks the radio between beacons, adding latency to
# inbound packets - wrong trade for a box whose whole purpose is answering
# the network. Applies on next connection activation.
CON=$(nmcli -t -f NAME connection show --active 2>/dev/null | head -1)
[ -n "$CON" ] && sudo nmcli connection modify "$CON" 802-11-wireless.powersave 2 2>/dev/null || true

sudo tee -a /etc/sysctl.d/99-headless.conf > /dev/null <<EOF

# Server-appropriate network behaviour.
# tcp_slow_start_after_idle: default re-enters slow start after any idle
# period, which penalises exactly the bursty pattern this box has.
net.ipv4.tcp_slow_start_after_idle = 0
net.core.somaxconn = 1024
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
EOF
sudo sysctl --system > /dev/null 2>&1

echo "== 15/15: masking avahi + serial console =="
# PRECONDITION: this assumes you reach the box by Tailscale MagicDNS or a
# bare IP. Verified on this device - `droidian` resolves to its Tailscale
# name, not mDNS. If you rely on <host>.local to find it, SKIP THIS or you
# will lose the ability to resolve the box by name.
#
# serial-getty@ttyS0 needs physical UART test points to be usable at all.
sudo systemctl mask --now avahi-daemon avahi-daemon.socket serial-getty@ttyS0

echo
echo "Done. Reboot to apply (default target, Plymouth removal, and the"
echo "display power-off cycle only take effect at boot):"
echo
echo "    sudo reboot"
echo
echo "SSH, Wi-Fi (lxc@android), and Tailscale are all untouched - verify"
echo "SSH access before disconnecting, same as any remote change."
echo
echo "Not included: removing data=journal/nodelalloc from /userdata."
echo "/etc/fstab is an unconfigured placeholder on this device - that"
echo "mount option is set inside boot.img's initramfs, on the raw 'boot'"
echo "partition, outside anything this script can reach. Needs a kernel"
echo "build + reflash, not a live fix."
echo
echo "Also not included (kernel cmdline, needs a boot.img rebuild):"
echo "  - slub_debug=OFZPU: SLUB red-zoning/poisoning on every kmalloc"
echo "  - page_owner=on: per-page allocation stack traces"
echo "  - cma=262144K reservation, ~93% permanently idle with no camera"
