#!/bin/sh

# Post-flash setup for this RMX2001 Droidian port: applies every
# device-specific fix discovered and validated by hand, documented in
# helpers/DEVICE-PROVISIONING.md, as one idempotent script. Safe to re-run;
# every step checks current state first and skips work already done.
#
# Usage:
#   sudo ./setup-rmx2001.sh [--user NAME]
#
# --user defaults to auto-detecting the desktop user the same way
# helpers/server-mode.sh does.

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REQUESTED_USER=

log() {
    printf '==> %s\n' "$*"
}

warn() {
    printf 'warning: %s\n' "$*" >&2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --user)
            REQUESTED_USER=${2:-}
            shift 2
            ;;
        -h|--help)
            printf 'Usage: sudo %s [--user NAME]\n' "$0"
            exit 0
            ;;
        *)
            warn "unknown argument: $1"
            exit 2
            ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    if [ -n "$REQUESTED_USER" ]; then
        exec sudo "$0" --user "$REQUESTED_USER"
    fi
    exec sudo "$0"
fi

valid_desktop_user() {
    [ -n "${1:-}" ] && [ "$1" != root ] && id "$1" >/dev/null 2>&1
}

desktop_user() {
    if valid_desktop_user "$REQUESTED_USER"; then
        printf '%s\n' "$REQUESTED_USER"
        return
    fi
    if [ -r /etc/default/server-mode ]; then
        SERVER_MODE_USER=
        . /etc/default/server-mode
        if valid_desktop_user "${SERVER_MODE_USER:-}"; then
            printf '%s\n' "$SERVER_MODE_USER"
            return
        fi
    fi
    getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 && $7 !~ /(nologin|false)$/ { print $1; exit }'
}

USER=$(desktop_user)
if ! valid_desktop_user "$USER"; then
    warn "could not determine the desktop user; pass --user NAME"
    exit 1
fi
log "Target user: $USER"

# polkit and bluebinder are both members of server-mode.sh's PHONE_UNITS list,
# so once that's installed and server mode is on, it is *correct* for both to
# be masked - do not fight that here, or every run of this script would
# silently break server mode by unmasking phone-only units it just disabled.
SERVER_MODE=off
[ -r /var/lib/server-mode/mode ] && SERVER_MODE=$(cat /var/lib/server-mode/mode)

user_systemctl() {
    uid=$(id -u "$USER")
    runuser -u "$USER" -- env \
        XDG_RUNTIME_DIR="/run/user/$uid" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
        systemctl --user "$@"
}

# ---------------------------------------------------------------------------
log "[1/8] Checking CONFIG_RFKILL"
# ---------------------------------------------------------------------------
if [ -e /dev/rfkill ]; then
    log "  /dev/rfkill present, kernel already has RFKILL support"
else
    warn "/dev/rfkill is missing: this kernel does not have CONFIG_RFKILL"
    warn "install a kernel build with CONFIG_RFKILL=y, e.g.:"
    warn "  https://github.com/Hari-Pi/kernel_realme_RMX2001/releases/tag/rmx2001-magiskboot-kernel-rfkill-20260928"
    warn "bluebinder (Bluetooth) cannot work without this; continuing with the rest of setup."
fi

# ---------------------------------------------------------------------------
log "[2/8] Removing the unregistered camera provider HAL from the VINTF manifest"
# ---------------------------------------------------------------------------
OVERLAY_MANIFEST=/usr/lib/droid-vendor-overlay/etc/vintf/manifest.xml
if [ -f "$OVERLAY_MANIFEST" ] && ! grep -q 'camera.provider' "$OVERLAY_MANIFEST"; then
    log "  override already in place"
elif [ ! -f /vendor/etc/vintf/manifest.xml ]; then
    warn "  /vendor/etc/vintf/manifest.xml not found, skipping"
else
    install -d -m 755 /usr/lib/droid-vendor-overlay/etc/vintf
    cp /vendor/etc/vintf/manifest.xml "$OVERLAY_MANIFEST"
    python3 - "$OVERLAY_MANIFEST" <<'PYEOF'
import re, sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()
pattern = re.compile(
    r'<hal format="hidl">\s*<name>android\.hardware\.camera\.provider</name>.*?</hal>\s*',
    re.DOTALL,
)
new_content, n = pattern.subn("", content, count=1)
if n == 1:
    with open(path, "w") as f:
        f.write(new_content)
PYEOF
    mount -o remount /vendor 2>/dev/null || true
    log "  override written; a reboot is needed for hwservicemanager to pick it up"
fi

# ---------------------------------------------------------------------------
log "[3/8] Making sure polkit is unmasked (required for PackageKit/apt hooks)"
# ---------------------------------------------------------------------------
if [ "$SERVER_MODE" = on ]; then
    log "  server mode is on: polkit is expected to be masked right now, leaving it alone"
elif [ "$(systemctl is-enabled polkit.service 2>/dev/null || true)" = masked ]; then
    systemctl unmask polkit.service
    systemctl start polkit.service
    log "  unmasked and started"
else
    log "  already unmasked"
fi

# ---------------------------------------------------------------------------
log "[4/8] Ranking down the broken droidvdec/droidadec GStreamer decoders"
# ---------------------------------------------------------------------------
GST_RANK_CONF=/etc/environment.d/80-gstreamer-video-decode.conf
if [ -f "$GST_RANK_CONF" ]; then
    log "  already in place"
else
    install -d -m 755 /etc/environment.d
    cat > "$GST_RANK_CONF" <<'EOF'
# The droid/hybris video and audio decoder bridge (droidvdec/droidadec) is
# ranked above the real hardware V4L2 M2M decoder and software fallbacks by
# default, but its underlying Android HAL bridge does not actually decode on
# this device (confirmed: real H.264 content fails with "No valid frames
# decoded before end of stream"), and GStreamer never falls back once it has
# committed to a decoder element. This breaks all GStreamer-based video
# playback (e.g. WebKitGTK/Epiphany, GNOME video apps) including YouTube.
# Ranking droidvdec/droidadec to 0 makes decodebin skip them and pick the
# working v4l2h264dec/v4l2vp9dec (hardware) or software decoders instead.
GST_PLUGIN_FEATURE_RANK=droidvdec:0,droidadec:0
EOF
    log "  written; takes effect on next login/reboot"
fi

# ---------------------------------------------------------------------------
log "[5/8] Fixing bluebinder_post.sh's POSIX-sh bashism and missing-address stall"
# ---------------------------------------------------------------------------
BT_POST=/usr/bin/droid/bluebinder_post.sh
if [ -f "$BT_POST" ]; then
    if grep -q '"\$bt_addr_file" == ""' "$BT_POST"; then
        cp "$BT_POST" "$BT_POST.orig-bashism-bug"
        sed -i 's/\[ "\$bt_addr_file" == "" \]/[ "$bt_addr_file" = "" ]/' "$BT_POST"
        log "  fixed == -> = bashism (backup: $BT_POST.orig-bashism-bug)"
    else
        log "  bashism already fixed"
    fi
else
    warn "  $BT_POST not found, skipping"
fi

BT_DROPIN_DIR=/etc/systemd/system/bluebinder.service.d
BT_DROPIN=$BT_DROPIN_DIR/99-ignore-missing-bdaddr.conf
if [ -f "$BT_DROPIN" ]; then
    log "  missing-bdaddr drop-in already in place"
else
    install -d -m 755 "$BT_DROPIN_DIR"
    cat > "$BT_DROPIN" <<'EOF'
[Service]
ExecStartPost=
ExecStartPost=-/usr/bin/droid/bluebinder_post.sh
EOF
    systemctl daemon-reload
    log "  missing-bdaddr drop-in written (this device has no Bluetooth address in any Android property; BlueZ uses the controller's own default instead)"
fi

if [ "$SERVER_MODE" = on ]; then
    log "  server mode is on: bluebinder is expected to be masked right now, leaving it alone"
elif [ -e /dev/rfkill ] && [ "$(systemctl is-enabled bluebinder.service 2>/dev/null || true)" = masked ]; then
    systemctl unmask bluebinder.service
    log "  unmasked bluebinder.service (RFKILL is present, it can work now)"
fi

# ---------------------------------------------------------------------------
log "[6/8] Disabling cellular permanently (this device will never have a SIM)"
# ---------------------------------------------------------------------------
for unit in ofono.service ModemManager.service; do
    if [ "$(systemctl is-enabled "$unit" 2>/dev/null || true)" = masked ]; then
        log "  $unit already masked"
    else
        systemctl mask --now "$unit" >/dev/null 2>&1 || true
        log "  masked $unit"
    fi
done

MM_DBUS=/usr/share/dbus-1/system-services/org.freedesktop.ModemManager1.service
if [ -f "$MM_DBUS" ]; then
    mv "$MM_DBUS" "$MM_DBUS.disabled-no-sim"
    systemctl reload dbus.service 2>/dev/null || true
    log "  disabled ModemManager's D-Bus activation file (was causing gnome-control-center's WWAN panel to stall)"
else
    log "  ModemManager D-Bus activation file already disabled"
fi

for unit in mmsd-tng.service calls-daemon.service; do
    if ! user_systemctl cat "$unit" >/dev/null 2>&1; then
        continue
    fi
    if [ "$(user_systemctl is-enabled "$unit" 2>/dev/null || true)" = masked ]; then
        log "  $unit already masked"
    else
        user_systemctl mask --now "$unit" >/dev/null 2>&1 || true
        log "  masked $unit"
    fi
done

# ---------------------------------------------------------------------------
log "[7/8] Installing the server-mode toggle"
# ---------------------------------------------------------------------------
if [ -f "$SCRIPT_DIR/server-mode.sh" ]; then
    if cmp -s "$SCRIPT_DIR/server-mode.sh" /usr/local/sbin/server-mode 2>/dev/null; then
        log "  already installed and up to date"
    else
        "$SCRIPT_DIR/server-mode.sh" install --user "$USER"
        log "  installed (server mode on|off|status)"
    fi
else
    warn "  server-mode.sh not found next to this script, skipping"
fi

# ---------------------------------------------------------------------------
log "[8/8] Done"
# ---------------------------------------------------------------------------
log "Reboot to make sure everything (VINTF manifest override, bluebinder"
log "unmask, GStreamer decoder ranking) is fully applied."
