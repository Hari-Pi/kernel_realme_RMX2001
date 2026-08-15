#!/bin/sh

# Toggle an RMX2001 Droidian device between a headless server and Phosh.
# Install once, then use `server mode on|off|status`.

set -u

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

STATE_DIR=/var/lib/server-mode
STATE_FILE=$STATE_DIR/mode
CONFIG_FILE=/etc/default/server-mode
INSTALLED_COMMAND=/usr/local/sbin/server-mode
COMMAND_LINK=/usr/local/bin/server
DISPLAY_OUTPUT=${SERVER_MODE_DISPLAY_OUTPUT:-HWCOMPOSER-1}
BRIGHTNESS_FILE=/sys/devices/platform/leds-mt65xx/leds/lcd-backlight/brightness
MAX_BRIGHTNESS_FILE=/sys/devices/platform/leds-mt65xx/leds/lcd-backlight/max_brightness
FB_BLANK_FILE=/sys/class/graphics/fb0/blank
REQUESTED_USER=

PHONE_UNITS="ofono ModemManager cups cups-browsed cups.socket cups.path bluetooth bluebinder nfcd geoclue iio-sensor-proxy sensorfwd openvpn strongswan-starter lm-sensors vnstat udisks2 accounts-daemon NetworkManager-wait-online polkit upower avahi-daemon avahi-daemon.socket serial-getty@ttyS0"
GUI_START_UNITS="accounts-daemon polkit upower udisks2 bluetooth geoclue iio-sensor-proxy sensorfwd avahi-daemon.socket"
ANDROID_HAL_UNITS="camerahalserver neuralnetworks_hal_service_gpunn neuralnetworks_hal_service_neuron_ann camera_service mediaextractor vendor.ril-daemon-mtk"

log() {
    printf '%s\n' "$*"
}

warn() {
    printf 'warning: %s\n' "$*" >&2
}

unit_exists() {
    systemctl cat "$1" >/dev/null 2>&1
}

valid_desktop_user() {
    [ -n "${1:-}" ] && [ "$1" != root ] && id "$1" >/dev/null 2>&1
}

desktop_user() {
    if valid_desktop_user "$REQUESTED_USER"; then
        printf '%s\n' "$REQUESTED_USER"
        return
    fi

    if [ -r "$CONFIG_FILE" ]; then
        SERVER_MODE_USER=
        . "$CONFIG_FILE"
        if valid_desktop_user "${SERVER_MODE_USER:-}"; then
            printf '%s\n' "$SERVER_MODE_USER"
            return
        fi
    fi

    if valid_desktop_user "${SUDO_USER:-}"; then
        printf '%s\n' "$SUDO_USER"
        return
    fi

    phosh_user=$(systemctl show phosh.service -p User --value 2>/dev/null || true)
    if valid_desktop_user "$phosh_user"; then
        printf '%s\n' "$phosh_user"
        return
    fi

    getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 && $7 !~ /(nologin|false)$/ { print $1; exit }'
}

desktop_uid() {
    id -u "$1"
}

desktop_gid() {
    id -g "$1"
}

desktop_home() {
    getent passwd "$1" | cut -d: -f6
}

user_systemctl() {
    user=$1
    shift
    uid=$(desktop_uid "$user")
    runuser -u "$user" -- env \
        XDG_RUNTIME_DIR="/run/user/$uid" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
        systemctl --user "$@"
}

run_wayland() {
    user=$1
    shift
    uid=$(desktop_uid "$user")
    runuser -u "$user" -- env \
        XDG_RUNTIME_DIR="/run/user/$uid" \
        WAYLAND_DISPLAY=wayland-0 \
        "$@"
}

wait_for_wayland() {
    user=$1
    uid=$(desktop_uid "$user")
    count=0
    while [ "$count" -lt 60 ]; do
        [ -S "/run/user/$uid/wayland-0" ] && return 0
        sleep 1
        count=$((count + 1))
    done
    return 1
}

mask_phone_units() {
    for unit in $PHONE_UNITS; do
        unit_exists "$unit" || continue
        systemctl mask --now "$unit" >/dev/null 2>&1 || warn "could not mask $unit"
    done
    systemctl disable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true
    unit_exists plymouth-start.service && systemctl mask plymouth-start.service >/dev/null 2>&1 || true
}

restore_phone_units() {
    for unit in $PHONE_UNITS; do
        unit_exists "$unit" || continue
        systemctl unmask "$unit" >/dev/null 2>&1 || warn "could not unmask $unit"
    done
    unit_exists plymouth-start.service && systemctl unmask plymouth-start.service >/dev/null 2>&1 || true
    systemctl enable apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true

    for unit in $GUI_START_UNITS; do
        unit_exists "$unit" || continue
        systemctl start "$unit" >/dev/null 2>&1 || warn "could not start $unit"
    done
}

mask_user_audio() {
    user=$1
    uid=$(desktop_uid "$user")
    gid=$(desktop_gid "$user")
    config_dir=$(desktop_home "$user")/.config/systemd/user

    user_systemctl "$user" stop pulseaudio.service pulseaudio.socket >/dev/null 2>&1 || true
    install -d -o "$uid" -g "$gid" -m 700 "$config_dir"
    ln -sfn /dev/null "$config_dir/pulseaudio.service"
    ln -sfn /dev/null "$config_dir/pulseaudio.socket"
    chown -h "$uid:$gid" "$config_dir/pulseaudio.service" "$config_dir/pulseaudio.socket"
    user_systemctl "$user" daemon-reload >/dev/null 2>&1 || true
}

restore_user_audio() {
    user=$1
    config_dir=$(desktop_home "$user")/.config/systemd/user

    for unit in pulseaudio.service pulseaudio.socket; do
        path=$config_dir/$unit
        if [ -L "$path" ] && [ "$(readlink "$path")" = /dev/null ]; then
            unlink "$path"
        fi
    done

    user_systemctl "$user" daemon-reload >/dev/null 2>&1 || true
    user_systemctl "$user" start pulseaudio.socket pulseaudio.service >/dev/null 2>&1 || true
}

android_hal_set() {
    action=$1
    systemctl is-active --quiet lxc@android.service || systemctl start lxc@android.service
    for service in $ANDROID_HAL_UNITS; do
        lxc-attach -n android -- /system/bin/"$action" "$service" >/dev/null 2>&1 || \
            warn "could not $action Android service $service"
    done
}

save_brightness() {
    [ -r "$BRIGHTNESS_FILE" ] || return 0
    brightness=$(cat "$BRIGHTNESS_FILE" 2>/dev/null || printf 0)
    case "$brightness" in
        ''|*[!0-9]*) return 0 ;;
    esac
    if [ "$brightness" -gt 0 ]; then
        install -d -m 755 "$STATE_DIR"
        printf '%s\n' "$brightness" > "$STATE_DIR/brightness"
    fi
}

restore_brightness() {
    brightness=
    if [ -r "$STATE_DIR/brightness" ]; then
        brightness=$(cat "$STATE_DIR/brightness" 2>/dev/null || true)
    fi
    case "$brightness" in
        ''|*[!0-9]*|0)
            max=$(cat "$MAX_BRIGHTNESS_FILE" 2>/dev/null || printf 2047)
            brightness=$((max / 2))
            ;;
    esac
    [ -w "$BRIGHTNESS_FILE" ] && printf '%s\n' "$brightness" > "$BRIGHTNESS_FILE"
}

display_off() {
    user=$1
    save_brightness
    systemctl start lxc@android.service >/dev/null 2>&1 || true
    systemctl start android-service@hwcomposer.service >/dev/null 2>&1 || true
    systemctl start phosh.service

    if wait_for_wayland "$user"; then
        # The socket appears before Phosh has fully taken ownership of the
        # bootloader overlay. Without this settle time, the panel can remain
        # latched on the boot logo even though brightness reports zero.
        sleep 8
        run_wayland "$user" wlr-randr --output "$DISPLAY_OUTPUT" --off >/dev/null 2>&1 || \
            warn "could not disable $DISPLAY_OUTPUT through Wayland"
    else
        warn "Wayland did not become ready before display shutdown"
    fi

    systemctl stop phosh.service >/dev/null 2>&1 || true
    systemctl stop android-service@hwcomposer.service >/dev/null 2>&1 || true
    [ -w "$FB_BLANK_FILE" ] && printf '1\n' > "$FB_BLANK_FILE"
    [ -w "$BRIGHTNESS_FILE" ] && printf '0\n' > "$BRIGHTNESS_FILE"
    systemctl restart getty@tty1.service >/dev/null 2>&1 || true
}

display_on() {
    user=$1
    systemctl start lxc@android.service
    systemctl start android-service@hwcomposer.service
    [ -w "$FB_BLANK_FILE" ] && printf '0\n' > "$FB_BLANK_FILE"
    restore_brightness
    systemctl start phosh.service

    if ! wait_for_wayland "$user"; then
        warn "Wayland did not become ready"
        return 1
    fi

    run_wayland "$user" wlr-randr --output "$DISPLAY_OUTPUT" --on >/dev/null 2>&1 || \
        warn "could not explicitly enable $DISPLAY_OUTPUT; Phosh may already have enabled it"
    restore_brightness
}

write_mode() {
    install -d -m 755 "$STATE_DIR"
    printf '%s\n' "$1" > "$STATE_FILE"
}

install_units() {
    user=$1
    install -d -m 755 /etc/systemd/system/phosh.service.d
    cat > /etc/systemd/system/phosh.service.d/99-server-mode-user.conf <<EOF
[Service]
User=$user
EOF

    cat > /etc/systemd/system/display-poweroff.service <<'EOF'
[Unit]
Description=Power off the display for server mode
After=lxc@android.service
Wants=lxc@android.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/server-mode display-off
TimeoutStartSec=90

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/android-hal-trim.service <<'EOF'
[Unit]
Description=Stop Android phone HALs in server mode
After=lxc@android.service
Requires=lxc@android.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/server-mode trim-android
TimeoutStartSec=30

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
}

install_command() {
    user=$(desktop_user)
    [ -n "$user" ] || {
        warn "could not determine the desktop user; use install --user NAME"
        exit 1
    }

    source_path=$(readlink -f "$0")
    if [ "$source_path" != "$INSTALLED_COMMAND" ]; then
        install -o root -g root -m 755 "$source_path" "$INSTALLED_COMMAND"
    fi
    ln -sfn ../sbin/server-mode "$COMMAND_LINK"
    printf 'SERVER_MODE_USER=%s\n' "$user" > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    install_units "$user"
    log "Installed server mode command for $user."
    log "Use: server mode on|off|status"
}

mode_on() {
    user=$(desktop_user)
    [ -n "$user" ] || exit 1
    write_mode on
    log "Enabling server mode..."
    systemctl set-default multi-user.target >/dev/null
    systemctl disable --now pbhelper.service >/dev/null 2>&1 || true
    display_off "$user"
    systemctl disable phosh.service >/dev/null 2>&1 || true
    systemctl enable display-poweroff.service android-hal-trim.service >/dev/null
    android_hal_set stop
    mask_user_audio "$user"
    mask_phone_units
    log "Server mode is on. SSH, networking, Cloudflare, and Docker were not changed."
}

mode_off() {
    user=$(desktop_user)
    [ -n "$user" ] || exit 1
    write_mode off
    log "Restoring phone GUI mode..."
    restore_phone_units
    restore_user_audio "$user"
    systemctl disable --now display-poweroff.service android-hal-trim.service >/dev/null 2>&1 || true
    systemctl set-default graphical.target >/dev/null
    systemctl enable phosh.service >/dev/null
    android_hal_set start
    systemctl start graphical.target >/dev/null 2>&1 || true
    display_on "$user"
    if unit_exists pbhelper.service; then
        systemctl enable --now pbhelper.service >/dev/null 2>&1 || warn "could not start pbhelper.service"
    fi
    log "Server mode is off. Display, touch, audio, and phone services are available."
}

mode_status() {
    configured=unknown
    [ -r "$STATE_FILE" ] && configured=$(cat "$STATE_FILE")
    user=$(desktop_user)
    brightness=$(cat "$BRIGHTNESS_FILE" 2>/dev/null || printf unavailable)
    printf 'configured mode: %s\n' "$configured"
    printf 'default target: %s\n' "$(systemctl get-default)"
    printf 'desktop user: %s\n' "${user:-unknown}"
    printf 'phosh: %s\n' "$(systemctl is-active phosh.service 2>/dev/null || true)"
    printf 'hardware composer: %s\n' "$(systemctl is-active android-service@hwcomposer.service 2>/dev/null || true)"
    printf 'power button helper: %s\n' "$(systemctl is-active pbhelper.service 2>/dev/null || true)"
    printf 'display brightness: %s\n' "$brightness"
    if grep -q 'Name="touchpanel"' /proc/bus/input/devices 2>/dev/null; then
        printf 'touch input: present\n'
    else
        printf 'touch input: unavailable\n'
    fi
}

usage() {
    cat <<'EOF'
Usage:
  server mode on       Enable headless server mode
  server mode off      Restore the Phosh phone interface
  server mode status   Show the current mode and hardware state

Installer:
  sudo ./server-mode.sh install [--user NAME]
EOF
}

if [ "${1:-}" = mode ]; then
    shift
fi
action=${1:-status}
shift 2>/dev/null || true

if [ "$action" = install ] && [ "${1:-}" = --user ]; then
    REQUESTED_USER=${2:-}
    valid_desktop_user "$REQUESTED_USER" || {
        warn "invalid desktop user: ${REQUESTED_USER:-missing}"
        exit 2
    }
fi

if [ "$(id -u)" -ne 0 ]; then
    if [ -n "$REQUESTED_USER" ]; then
        exec sudo "$0" install --user "$REQUESTED_USER"
    fi
    exec sudo "$0" "$action"
fi

case "$action" in
    install) install_command ;;
    on) mode_on ;;
    off) mode_off ;;
    status) mode_status ;;
    display-off) display_off "$(desktop_user)" ;;
    trim-android) android_hal_set stop ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 2 ;;
esac
