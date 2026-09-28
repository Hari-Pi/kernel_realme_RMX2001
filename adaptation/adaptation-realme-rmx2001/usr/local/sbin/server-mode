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

# ofono, ModemManager: no SIM will ever be used on this device, kept masked permanently.
PHONE_UNITS="cups cups-browsed cups.socket cups.path bluetooth bluebinder nfcd geoclue iio-sensor-proxy sensorfwd openvpn strongswan-starter lm-sensors vnstat udisks2 accounts-daemon NetworkManager-wait-online polkit upower avahi-daemon avahi-daemon.socket serial-getty@ttyS0"
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

# Reads LoadState, ActiveState and UnitFileState for every listed unit with a
# single systemctl call, instead of forking systemctl once per unit per
# question. Prints one line per unit: "<unit> <load> <active> <unitfile>".
# Units that don't exist come back as "not-found ... ...".
unit_table() {
    [ "$#" -eq 0 ] && return 0
    systemctl show "$@" --property=Id,LoadState,ActiveState,UnitFileState 2>/dev/null | awk '
        function flush() { if (id != "") printf "%s %s %s %s\n", id, load, active, ufs }
        /^Id=/          { flush(); split($0, a, "="); id = a[2]; load = "?"; active = "?"; ufs = "?" }
        /^LoadState=/   { split($0, a, "="); load = a[2] }
        /^ActiveState=/ { split($0, a, "="); active = a[2] }
        /^UnitFileState=/ { split($0, a, "="); ufs = a[2] }
        END { flush() }
    '
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

# Draws a "[####----] 2/5 steps done (3s)" bar in place on one line.
# Portable POSIX: no printf '%*s' (not supported by every /bin/sh), just
# plain loops building the fill/empty runs.
draw_progress() {
    done_count=$1
    total=$2
    elapsed=$3
    width=24
    filled=$((done_count * width / total))
    bar=
    i=0
    while [ "$i" -lt "$filled" ]; do bar="${bar}#"; i=$((i + 1)); done
    while [ "$i" -lt "$width" ]; do bar="${bar}-"; i=$((i + 1)); done
    printf '\r[%s] %d/%d steps done (%ds)\033[K' "$bar" "$done_count" "$total" "$elapsed"
}

# Runs a set of independent steps concurrently, shows a live progress bar
# while they run, then prints each step's output grouped and labelled once
# everything has finished. Ctrl+C stops any steps still running and exits
# cleanly instead of leaving orphaned processes or a stuck terminal.
# Usage: run_parallel "label 1" "shell command 1" "label 2" "shell command 2" ...
run_parallel() {
    tmp=$(mktemp -d)
    n=0
    pid_list=
    while [ "$#" -ge 2 ]; do
        n=$((n + 1))
        label=$1
        cmd=$2
        shift 2
        printf '%s\n' "$label" > "$tmp/$n.label"
        ( eval "$cmd" ) > "$tmp/$n.out" 2>&1 &
        eval "pid_$n=$!"
        pid_list="$pid_list $n"
    done

    cancel_run() {
        printf '\r\033[K'
        warn "cancelled - stopping steps still running..."
        for idx in $pid_list; do
            eval "pid=\$pid_$idx"
            # Kill the step's own command first (a child of the subshell
            # tracked by $pid) then the subshell itself, otherwise the
            # subshell dies but leaves its still-running child behind.
            pkill -TERM -P "$pid" 2>/dev/null
            kill -TERM "$pid" 2>/dev/null
        done
        for idx in $pid_list; do
            eval "pid=\$pid_$idx"
            wait "$pid" 2>/dev/null
        done
        printf '\033[?25h'
        rm -rf "$tmp"
        trap - INT TERM
        exit 130
    }
    trap cancel_run INT TERM

    printf '\033[?25l'
    start=$(date +%s)
    while :; do
        done_count=0
        for idx in $pid_list; do
            eval "pid=\$pid_$idx"
            kill -0 "$pid" 2>/dev/null || done_count=$((done_count + 1))
        done
        draw_progress "$done_count" "$n" "$(($(date +%s) - start))"
        [ "$done_count" -eq "$n" ] && break
        sleep 0.2
    done
    printf '\n'
    printf '\033[?25h'
    trap - INT TERM

    status=0
    for idx in $pid_list; do
        eval "pid=\$pid_$idx"
        wait "$pid" || status=1
    done

    i=1
    while [ "$i" -le "$n" ]; do
        log "$(cat "$tmp/$i.label")"
        sed 's/^/  /' "$tmp/$i.out"
        i=$((i + 1))
    done

    rm -rf "$tmp"
    return "$status"
}

mask_phone_units() {
    table=$(unit_table $PHONE_UNITS plymouth-start.service)
    to_mask=$(printf '%s\n' "$table" | awk '$1 != "plymouth-start.service" && $2 != "not-found" && $4 != "masked" {print $1}')
    printf '%s\n' "$table" | awk '$1 != "plymouth-start.service" && $2 != "not-found" && $4 == "masked" {print "  " $1 " is already masked"}'

    if [ -n "$to_mask" ]; then
        log "  masking:$to_mask"
        # shellcheck disable=SC2086
        systemctl mask --now $to_mask >/dev/null 2>&1 || warn "could not mask one or more units:$to_mask"
    fi

    log "  disabling automatic package timers"
    systemctl disable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true

    plymouth_ufs=$(printf '%s\n' "$table" | awk '$1 == "plymouth-start.service" {print $4}')
    if [ "$plymouth_ufs" = masked ]; then
        log "  plymouth-start.service is already masked"
    elif [ -n "$plymouth_ufs" ] && [ "$plymouth_ufs" != not-found ]; then
        log "  masking plymouth-start.service"
        systemctl mask plymouth-start.service >/dev/null 2>&1 || true
    fi
}

restore_phone_units() {
    # Every GUI_START_UNITS member is already a member of PHONE_UNITS, so one
    # query covers both the mask state and the active state needed below.
    table=$(unit_table $PHONE_UNITS plymouth-start.service)
    to_unmask=$(printf '%s\n' "$table" | awk '$1 != "plymouth-start.service" && $2 != "not-found" && $4 == "masked" {print $1}')
    printf '%s\n' "$table" | awk '$1 != "plymouth-start.service" && $2 != "not-found" && $4 != "masked" {print "  " $1 " is already unmasked"}'

    if [ -n "$to_unmask" ]; then
        log "  unmasking:$to_unmask"
        # shellcheck disable=SC2086
        systemctl unmask $to_unmask >/dev/null 2>&1 || warn "could not unmask one or more units:$to_unmask"
    fi

    plymouth_ufs=$(printf '%s\n' "$table" | awk '$1 == "plymouth-start.service" {print $4}')
    if [ -n "$plymouth_ufs" ] && [ "$plymouth_ufs" != not-found ] && [ "$plymouth_ufs" = masked ]; then
        systemctl unmask plymouth-start.service >/dev/null 2>&1 || true
    fi

    systemctl enable apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true

    to_start=$(printf '%s\n' "$table" | awk -v gui=" $GUI_START_UNITS " '
        gui ~ " " $1 " " && $2 != "not-found" && $3 != "active" {print $1}
    ')
    printf '%s\n' "$table" | awk -v gui=" $GUI_START_UNITS " '
        gui ~ " " $1 " " && $3 == "active" {print "  " $1 " is already running"}
    '

    if [ -n "$to_start" ]; then
        log "  starting:$to_start"
        # shellcheck disable=SC2086
        systemctl start $to_start >/dev/null 2>&1 || warn "could not start one or more units:$to_start"
    fi
}

# audiosystem-passthrough bridges PulseAudio to the Android audio HAL. It
# only has a weak After=pulseaudio.service ordering, not a real dependency,
# so masking pulseaudio alone does not stop it - it keeps running (and
# holding the Android audio HAL open) even in server mode unless masked here
# too.
USER_AUDIO_UNITS="pulseaudio.service pulseaudio.socket audiosystem-passthrough.service"

mask_user_audio() {
    user=$1
    uid=$(desktop_uid "$user")
    gid=$(desktop_gid "$user")
    config_dir=$(desktop_home "$user")/.config/systemd/user

    already_masked=1
    for unit in $USER_AUDIO_UNITS; do
        [ -L "$config_dir/$unit" ] && [ "$(readlink "$config_dir/$unit")" = /dev/null ] || already_masked=0
    done
    if [ "$already_masked" -eq 1 ]; then
        log "  audio services are already disabled for $user"
        return 0
    fi

    log "  stopping audio services for $user"
    # shellcheck disable=SC2086
    user_systemctl "$user" stop $USER_AUDIO_UNITS >/dev/null 2>&1 || true
    install -d -o "$uid" -g "$gid" -m 700 "$config_dir"
    for unit in $USER_AUDIO_UNITS; do
        ln -sfn /dev/null "$config_dir/$unit"
        chown -h "$uid:$gid" "$config_dir/$unit"
    done
    user_systemctl "$user" daemon-reload >/dev/null 2>&1 || true
}

restore_user_audio() {
    user=$1
    config_dir=$(desktop_home "$user")/.config/systemd/user

    need_restore=0
    for unit in $USER_AUDIO_UNITS; do
        path=$config_dir/$unit
        if [ -L "$path" ] && [ "$(readlink "$path")" = /dev/null ]; then
            need_restore=1
            unlink "$path"
        fi
    done

    if [ "$need_restore" -eq 0 ]; then
        log "  audio services are already enabled for $user"
        return 0
    fi

    log "  restoring audio services for $user"
    user_systemctl "$user" daemon-reload >/dev/null 2>&1 || true
    # Ordering (audiosystem-passthrough After=pulseaudio.service) is handled
    # by systemd itself from a single start invocation.
    # shellcheck disable=SC2086
    user_systemctl "$user" start $USER_AUDIO_UNITS >/dev/null 2>&1 || true
}

# Reads and changes every Android HAL unit's state with one container attach
# each (instead of one attach per service) and skips services already in the
# requested state.
android_hal_set() {
    action=$1
    systemctl is-active --quiet lxc@android.service || systemctl start lxc@android.service

    states=$(lxc-attach -n android -- sh -c '
        for s in '"$ANDROID_HAL_UNITS"'; do
            printf "%s %s\n" "$s" "$(getprop init.svc."$s")"
        done
    ' 2>/dev/null)

    pending=
    for service in $ANDROID_HAL_UNITS; do
        current=$(printf '%s\n' "$states" | awk -v s="$service" '$1 == s {print $2}')
        if [ "$action" = start ] && [ "$current" = running ]; then
            log "  $service is already running"
            continue
        fi
        if [ "$action" = stop ] && { [ "$current" = stopped ] || [ -z "$current" ]; }; then
            log "  $service is already stopped"
            continue
        fi
        pending="$pending $service"
    done

    if [ -n "$pending" ]; then
        log "  $action:$pending"
        lxc-attach -n android -- sh -c '
            for s in '"$pending"'; do
                '"$action"' "$s"
            done
        ' >/dev/null 2>&1 || warn "could not $action one or more Android services:$pending"
    fi
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
    log "  starting Android hardware composer"
    save_brightness
    systemctl start lxc@android.service >/dev/null 2>&1 || true
    systemctl start android-service@hwcomposer.service >/dev/null 2>&1 || true
    log "  starting Phosh to take ownership of the panel"
    systemctl start phosh.service

    log "  waiting for the Wayland display"
    if wait_for_wayland "$user"; then
        # The socket appears before Phosh has fully taken ownership of the
        # bootloader overlay. Without this settle time, the panel can remain
        # latched on the boot logo even though brightness reports zero.
        log "  allowing the bootloader overlay to settle (8 seconds)"
        sleep 8
        log "  disabling $DISPLAY_OUTPUT"
        run_wayland "$user" wlr-randr --output "$DISPLAY_OUTPUT" --off >/dev/null 2>&1 || \
            warn "could not disable $DISPLAY_OUTPUT through Wayland"
    else
        warn "Wayland did not become ready before display shutdown"
    fi

    log "  stopping Phosh and the hardware composer"
    systemctl stop phosh.service >/dev/null 2>&1 || true
    systemctl stop android-service@hwcomposer.service >/dev/null 2>&1 || true
    [ -w "$FB_BLANK_FILE" ] && printf '4\n' > "$FB_BLANK_FILE"
    [ -w "$BRIGHTNESS_FILE" ] && printf '0\n' > "$BRIGHTNESS_FILE"
    systemctl restart getty@tty1.service >/dev/null 2>&1 || true
}

display_on() {
    user=$1
    log "  starting Android hardware composer"
    systemctl start lxc@android.service
    systemctl start android-service@hwcomposer.service
    [ -w "$FB_BLANK_FILE" ] && printf '0\n' > "$FB_BLANK_FILE"
    restore_brightness
    log "  starting Phosh"
    systemctl start phosh.service

    log "  waiting for the Wayland display"
    if ! wait_for_wayland "$user"; then
        warn "Wayland did not become ready"
        return 1
    fi

    log "  enabling $DISPLAY_OUTPUT"
    run_wayland "$user" wlr-randr --output "$DISPLAY_OUTPUT" --on >/dev/null 2>&1 || \
        warn "could not explicitly enable $DISPLAY_OUTPUT; Phosh may already have enabled it"
    restore_brightness
}

write_mode() {
    install -d -m 755 "$STATE_DIR"
    printf '%s\n' "$1" > "$STATE_FILE"
}

disable_graphical_startup() {
    systemctl disable phosh.service >/dev/null 2>&1 || true
    systemctl enable display-poweroff.service android-hal-trim.service >/dev/null
}

prepare_graphical_boot() {
    systemctl disable --now display-poweroff.service android-hal-trim.service >/dev/null 2>&1 || true
    systemctl set-default graphical.target >/dev/null
    systemctl enable phosh.service >/dev/null
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
    log "[1/2] Setting the default boot target"
    systemctl set-default multi-user.target >/dev/null
    log "[2/2] Running independent shutdown steps in parallel"
    run_parallel \
        "  Powering off the display" "display_off '$user'" \
        "  Disabling graphical startup" "disable_graphical_startup" \
        "  Stopping unused Android phone HALs" "android_hal_set stop" \
        "  Disabling desktop audio" "mask_user_audio '$user'" \
        "  Disabling phone-only background services" "mask_phone_units"
    log "Server mode is on. SSH, networking, Cloudflare, and Docker were not changed."
}

mode_off() {
    user=$(desktop_user)
    [ -n "$user" ] || exit 1
    write_mode off
    log "Restoring phone GUI mode..."
    log "[1/2] Running independent restore steps in parallel"
    run_parallel \
        "  Restoring phone background services" "restore_phone_units" \
        "  Restoring desktop audio" "restore_user_audio '$user'" \
        "  Preparing the graphical boot target" "prepare_graphical_boot" \
        "  Starting Android phone HALs" "android_hal_set start" \
        "  Restoring the display and touch interface" "display_on '$user'"
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
