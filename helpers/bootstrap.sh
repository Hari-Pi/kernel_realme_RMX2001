#!/bin/sh

# One-shot post-flash setup for the RMX2001 Droidian port: fetches just the
# adaptation package source (not the whole kernel tree), builds it, installs
# it, and brings up the Phosh phone GUI. Meant to be run via:
#
#   curl -fsSL https://raw.githubusercontent.com/Hari-Pi/kernel_realme_RMX2001/droidian/helpers/bootstrap.sh | bash
#
# on a freshly flashed device with Wi-Fi already connected. Safe to re-run.

set -eu

REPO_URL='https://github.com/Hari-Pi/kernel_realme_RMX2001.git'
BRANCH=droidian

log() {
    printf '==> %s\n' "$*"
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

for cmd in git dpkg-deb sudo; do
    command -v "$cmd" >/dev/null 2>&1 || die "missing required command: $cmd"
done

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

log "Fetching the adaptation package source (not the full kernel tree)"
git clone --quiet --depth 1 --filter=blob:none --sparse --branch "$BRANCH" \
    "$REPO_URL" "$workdir/repo"
git -C "$workdir/repo" sparse-checkout set --no-cone \
    /adaptation /helpers/build-adaptation-deb.sh

log "Building adaptation-realme-rmx2001"
"$workdir/repo/helpers/build-adaptation-deb.sh" "$workdir"

log "Installing it"
sudo apt install -y "$workdir"/adaptation-realme-rmx2001_*.deb

if [ -x /usr/local/sbin/server-mode ]; then
    log "Bringing up the Phosh phone GUI"
    sudo server-mode off
fi

log "Done. A reboot is recommended so the VINTF manifest override and"
log "GStreamer decoder ranking are fully applied: sudo reboot"
