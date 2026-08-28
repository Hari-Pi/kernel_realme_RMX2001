#!/bin/sh

# Install the reusable server-mode command and apply persistent RMX2001
# server tuning. Display and phone-service changes live in server-mode.sh so
# they can be reversed later with `server mode off`.

set -eu

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MODE_INSTALLER=$SCRIPT_DIR/server-mode.sh
TARGET_USER=${SUDO_USER:-$(id -un)}

usage() {
    printf 'Usage: %s [--user NAME]\n' "$0"
}

if [ "${1:-}" = --user ]; then
    TARGET_USER=${2:-}
    [ -n "$TARGET_USER" ] || {
        usage >&2
        exit 2
    }
elif [ "$#" -gt 0 ]; then
    usage >&2
    exit 2
fi

[ -f "$MODE_INSTALLER" ] || {
    printf 'Missing %s; run this script from the repository helpers directory.\n' "$MODE_INSTALLER" >&2
    exit 1
}
id "$TARGET_USER" >/dev/null 2>&1 || {
    printf 'Unknown desktop user: %s\n' "$TARGET_USER" >&2
    exit 1
}

printf '%s\n' '== 1/7: installing the reversible server-mode command =='
sudo "$MODE_INSTALLER" install --user "$TARGET_USER"

printf '%s\n' '== 2/7: configuring zram swap =='
sudo tee /etc/systemd/system/zram-swap.service >/dev/null <<'EOF'
[Unit]
Description=Set up zram-backed swap
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

printf '%s\n' '== 3/7: applying memory and network sysctls =='
sudo tee /etc/sysctl.d/99-headless.conf >/dev/null <<'EOF'
vm.swappiness = 100
vm.page-cluster = 0
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
net.ipv4.tcp_congestion_control = cubic
net.ipv4.tcp_slow_start_after_idle = 0
net.core.somaxconn = 1024
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
EOF
sudo sysctl --system >/dev/null 2>&1

printf '%s\n' '== 4/7: configuring the CPU governor =='
sudo tee /etc/systemd/system/cpu-performance.service >/dev/null <<'EOF'
[Unit]
Description=Pin the CPU governor to performance
DefaultDependencies=no
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c "for governor in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > \$governor; done"

[Install]
WantedBy=multi-user.target
EOF

printf '%s\n' '== 5/7: capping the system journal =='
sudo install -d -m 755 /etc/systemd/journald.conf.d
sudo tee /etc/systemd/journald.conf.d/99-cap.conf >/dev/null <<'EOF'
[Journal]
SystemMaxUse=64M
RuntimeMaxUse=32M
ForwardToSyslog=no
EOF

printf '%s\n' '== 6/7: configuring storage and Wi-Fi =='
sudo tee /etc/systemd/system/mount-tuning.service >/dev/null <<'EOF'
[Unit]
Description=Apply server mount options and IO scheduler
After=local-fs.target
Wants=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c "mount -o remount,noatime / 2>/dev/null; mount -o remount,nodiscard,noatime,commit=60 /userdata 2>/dev/null; echo none > /sys/block/loop1/queue/scheduler 2>/dev/null; true"

[Install]
WantedBy=multi-user.target
EOF

connection=$(nmcli -t -f NAME connection show --active 2>/dev/null | head -1 || true)
if [ -n "$connection" ]; then
    sudo nmcli connection modify "$connection" 802-11-wireless.powersave 2 2>/dev/null || true
fi

sudo systemctl daemon-reload
sudo systemctl enable zram-swap.service cpu-performance.service mount-tuning.service >/dev/null
sudo systemctl restart systemd-journald

printf '%s\n' '== 7/7: enabling server mode =='
sudo /usr/local/sbin/server-mode on

cat <<'EOF'

Server setup complete.

  server mode status
  server mode off      # restore the phone GUI
  server mode on       # return to headless operation

The default target change applies to future boots; the current display and
phone services were switched immediately.
EOF
