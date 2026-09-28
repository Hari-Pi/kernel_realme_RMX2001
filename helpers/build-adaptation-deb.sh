#!/bin/sh

# Builds the device adaptation package from adaptation/adaptation-realme-rmx2001/
# (a plain dpkg-deb binary package tree, not a debhelper source package - simple
# and sufficient for a handful of config files, scripts, and maintainer
# hooks). Must run somewhere with dpkg-deb, e.g. the target device itself.
#
# Usage: ./helpers/build-adaptation-deb.sh [OUTPUT_DIR]

set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
src="$root/adaptation/adaptation-realme-rmx2001"
output_dir=${1:-$root}

command -v dpkg-deb >/dev/null 2>&1 || {
    echo 'error: dpkg-deb not found (run this on a Debian-based host, e.g. the device itself)' >&2
    exit 1
}

version=$(sed -n 's/^Version: //p' "$src/DEBIAN/control")
[ -n "$version" ] || { echo 'error: could not read Version from DEBIAN/control' >&2; exit 1; }

build_tree=$(mktemp -d)
trap 'rm -rf "$build_tree"' EXIT
cp -R "$src" "$build_tree/pkgroot"
find "$build_tree/pkgroot" -type f -exec chmod 644 {} \;
chmod 755 \
    "$build_tree/pkgroot/DEBIAN/preinst" \
    "$build_tree/pkgroot/DEBIAN/postinst" \
    "$build_tree/pkgroot/DEBIAN/postrm" \
    "$build_tree/pkgroot/usr/bin/droid/bluebinder_post.sh" \
    "$build_tree/pkgroot/usr/local/sbin/server-mode"

for script in preinst postinst postrm; do
    sh -n "$build_tree/pkgroot/DEBIAN/$script"
done

out="$output_dir/adaptation-realme-rmx2001_${version}_all.deb"
dpkg-deb --build --root-owner-group "$build_tree/pkgroot" "$out"
echo "built: $out"
