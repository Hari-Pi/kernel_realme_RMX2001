#!/usr/bin/env bash
set -Eeuo pipefail

readonly ABI='4.14.141-realme-rmx2001'
readonly DEVICE='RMX2001'
readonly BOOT_SIZE='33554432'
readonly STOCK_SHA256='ce5d48e4802398ceb2cd0dd8c84e04dd944cac08bb540ace87f1c26a9ffe14c2'
readonly MAGISKBOOT_SHA256='a18ecbd7981179494b7d281453d6c4e25b5c719e7d2ef7f6eba3c6be3043c58e'

root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mode=build
allow_dirty=0
jobs=${JOBS:-}
stock_boot=${STOCK_BOOT_IMAGE:-}
magiskboot=${MAGISKBOOT:-}
output_root=${OUTPUT_DIR:-"$(dirname "$root")/rmx2001-magiskboot-artifacts"}
compiler_artifact_input=

usage() {
    cat <<'EOF'
Usage: ./helpers/build-magiskboot-deb.sh [OPTIONS]

Compiles the RMX2001 kernel with the pinned Droidian toolchain, replaces only
the kernel in a known-good stock boot image with MagiskBoot, verifies all
preserved components, and creates a guarded boot-image Debian package.

Options:
  --check-only       Validate inputs and build prerequisites only
  --allow-dirty      Permit a dirty source tree and pass it to the compiler
  --jobs N           Limit build CPUs (default: all available host CPUs)
  --stock-boot FILE  Known-good 32 MiB stock boot image
  --magiskboot FILE  Pinned x86_64 MagiskBoot binary
  --compiler-artifact DIR
                     Reuse a verified compiler artifact instead of recompiling
  --output DIR       Artifact root outside the source tree
  -h, --help         Show this help

On the established build host, stock boot and MagiskBoot are discovered from
/home/dazai/kernel-build automatically. This script never installs the package,
flashes a partition, reboots a device, or includes a recovery image.
EOF
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
note() { printf '==> %s\n' "$*"; }
require() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }
hash_file() { sha256sum "$1" | awk '{print $1}'; }
detect_jobs() {
    if command -v nproc >/dev/null 2>&1; then
        nproc
    elif command -v getconf >/dev/null 2>&1; then
        getconf _NPROCESSORS_ONLN
    else
        die 'unable to detect available CPUs; pass --jobs N'
    fi
}
resolve_file() {
    local path=$1
    [[ -f $path ]] || return 1
    (cd "$(dirname "$path")" && printf '%s/%s\n' "$PWD" "$(basename "$path")")
}

while (($#)); do
    case $1 in
        --check-only) mode=check; shift ;;
        --allow-dirty) allow_dirty=1; shift ;;
        --jobs) (($# >= 2)) || die '--jobs requires a value'; jobs=$2; shift 2 ;;
        --stock-boot) (($# >= 2)) || die '--stock-boot requires a file'; stock_boot=$2; shift 2 ;;
        --magiskboot) (($# >= 2)) || die '--magiskboot requires a file'; magiskboot=$2; shift 2 ;;
        --compiler-artifact) (($# >= 2)) || die '--compiler-artifact requires a directory'; compiler_artifact_input=$2; shift 2 ;;
        --output) (($# >= 2)) || die '--output requires a directory'; output_root=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

[[ -n $jobs ]] || jobs=$(detect_jobs)
[[ $jobs =~ ^[1-9][0-9]*$ ]] || die '--jobs must be a positive integer'

if [[ -z $stock_boot && -f /home/dazai/kernel-build/input/stock-boot.img ]]; then
    stock_boot=/home/dazai/kernel-build/input/stock-boot.img
fi
if [[ -z $magiskboot ]]; then
    if command -v magiskboot >/dev/null 2>&1; then
        magiskboot=$(command -v magiskboot)
    elif [[ -x /home/dazai/kernel-build/tools/magisk-v30.7/magiskboot ]]; then
        magiskboot=/home/dazai/kernel-build/tools/magisk-v30.7/magiskboot
    fi
fi

stock_boot=$(resolve_file "${stock_boot:-}") || die 'known-good stock boot image not found; use --stock-boot FILE'
magiskboot=$(resolve_file "${magiskboot:-}") || die 'MagiskBoot not found; use --magiskboot FILE'
[[ -x $magiskboot ]] || die "MagiskBoot is not executable: $magiskboot"

for command in awk cmp cp dd dpkg-deb find git grep install mktemp od sed sha256sum stat tr; do
    require "$command"
done
[[ $(uname -s) == Linux ]] || die 'build host must be Linux (WSL 2 is supported)'
[[ $(uname -m) == x86_64 ]] || die 'build host must be x86_64/amd64'
[[ $(stat -c %s "$stock_boot") == "$BOOT_SIZE" ]] || die 'stock boot image must be exactly 32 MiB'
[[ $(hash_file "$stock_boot") == "$STOCK_SHA256" ]] || die 'stock boot image is not the validated known-good image'
[[ $(dd if="$stock_boot" bs=8 count=1 status=none) == 'ANDROID!' ]] || die 'stock boot image has invalid Android magic'
[[ $(hash_file "$magiskboot") == "$MAGISKBOOT_SHA256" ]] || die 'MagiskBoot checksum mismatch'

compile_args=(--check-only --jobs "$jobs" --output "$output_root/.preflight")
[[ $allow_dirty -eq 0 ]] || compile_args+=(--allow-dirty)
"$root/build.sh" "${compile_args[@]}"

note "stock boot SHA-256: $STOCK_SHA256"
note "MagiskBoot SHA-256: $MAGISKBOOT_SHA256"
note "jobs: $jobs"
note 'MagiskBoot package preflight passed'
[[ $mode == build ]] || exit 0

mkdir -p "$output_root"
output_root=$(cd "$output_root" && pwd)
source_commit=$(git -C "$root" rev-parse HEAD)
source_short=$(git -C "$root" rev-parse --short=12 HEAD)
source_epoch=$(git -C "$root" show -s --format=%ct HEAD)
source_date=$(date -u -d "@$source_epoch" +%Y%m%d%H%M%S)
build_id="$(date -u +%Y%m%dT%H%M%SZ)-$source_short-magiskboot"
artifact_directory="$output_root/$build_id"
compile_root="$artifact_directory/compiler"
mkdir "$artifact_directory"

cleanup_root=$(mktemp -d "$(dirname "$root")/.rmx2001-magiskboot.XXXXXX")
package_root=
cleanup() {
    status=$?
    if [[ $status -ne 0 && -n ${package_root:-} && -d $package_root ]]; then
        cp -a "$package_root" "$artifact_directory/FAILED-package-root"
    fi
    rm -rf -- "$cleanup_root"
}
trap cleanup EXIT

if [[ -n $compiler_artifact_input ]]; then
    compiler_artifact=$(cd "$compiler_artifact_input" && pwd)
    compiler_source_commit=$(sed -n 's/^Source commit: //p' "$compiler_artifact/MANIFEST.txt")
    [[ $compiler_source_commit =~ ^[0-9a-f]{40}$ ]] || die 'compiler artifact has an invalid source commit'
    git -C "$root" merge-base --is-ancestor "$compiler_source_commit" "$source_commit" ||
        die 'compiler artifact is not an ancestor of the current source'
    git -C "$root" diff --quiet "$compiler_source_commit" "$source_commit" -- . \
        ':(exclude)helpers/build-magiskboot-deb.sh' \
        ':(exclude)helpers/BUILDING.md' ||
        die 'kernel or compiler inputs changed after the reused artifact was built'
    note "reusing verified compiler artifact: $compiler_artifact"
else
    note 'compiling raw kernel with the pinned Droidian toolchain'
    compile_args=(--jobs "$jobs" --output "$compile_root")
    [[ $allow_dirty -eq 0 ]] || compile_args+=(--allow-dirty)
    "$root/build.sh" "${compile_args[@]}"
    compiler_artifact=$(find "$compile_root" -mindepth 1 -maxdepth 1 -type d -print)
    [[ -n $compiler_artifact && $compiler_artifact != *$'\n'* ]] || die 'expected exactly one compiler artifact directory'
    compiler_source_commit=$source_commit
fi
raw_kernel="$compiler_artifact/kernel-Image"
[[ -s $raw_kernel ]] || die 'compiler did not publish the raw kernel Image'
[[ $(od -An -tx1 -j56 -N4 "$raw_kernel" | tr -d ' \n') == '41524d64' ]] || die 'raw kernel Image has invalid arm64 magic'

stock_unpack="$cleanup_root/stock"
verify_unpack="$cleanup_root/verify"
mkdir "$stock_unpack" "$verify_unpack"
install -m 0644 "$stock_boot" "$stock_unpack/boot.img"

note 'unpacking the validated stock boot image'
(cd "$stock_unpack" && "$magiskboot" unpack boot.img > unpack-stock.log)
for component in kernel ramdisk.cpio dtb kernel_dtb; do
    [[ -s $stock_unpack/$component ]] || die "stock boot component is missing: $component"
done
cp "$stock_unpack/kernel" "$stock_unpack/kernel.stock"
install -m 0644 "$raw_kernel" "$stock_unpack/kernel"

candidate="$artifact_directory/boot.img"
note 'repacking stock boot layout with only the kernel replaced'
(cd "$stock_unpack" && "$magiskboot" repack boot.img "$candidate" > repack.log)
sync
[[ $(stat -c %s "$candidate") == "$BOOT_SIZE" ]] || die 'repacked boot image is not exactly 32 MiB'
[[ $(dd if="$candidate" bs=8 count=1 status=none) == 'ANDROID!' ]] || die 'repacked boot image has invalid Android magic'

note 're-unpacking and comparing every preserved boot component'
install -m 0644 "$candidate" "$verify_unpack/boot.img"
(cd "$verify_unpack" && "$magiskboot" unpack boot.img > unpack-candidate.log)
cmp "$verify_unpack/kernel" "$raw_kernel"
for component in ramdisk.cpio dtb kernel_dtb; do
    cmp "$verify_unpack/$component" "$stock_unpack/$component"
done

candidate_hash=$(hash_file "$candidate")
raw_kernel_hash=$(hash_file "$raw_kernel")
component_report="$artifact_directory/PRESERVED-COMPONENTS.txt"
{
    printf 'Stock boot SHA-256: %s\n' "$STOCK_SHA256"
    printf 'Candidate boot SHA-256: %s\n' "$candidate_hash"
    printf 'Compiled kernel SHA-256: %s\n' "$raw_kernel_hash"
    for component in ramdisk.cpio dtb kernel_dtb; do
        printf '%s SHA-256: %s\n' "$component" "$(hash_file "$stock_unpack/$component")"
    done
} > "$component_report"

package=linux-bootimage-$ABI
version="0.0.0+magiskboot.git${source_date}.${source_short}"
package_root="$cleanup_root/package"
mkdir -p "$package_root/DEBIAN" "$package_root/boot" \
    "$package_root/usr/share/doc/$package"
install -m 0644 "$candidate" "$package_root/boot/boot.img-$ABI"

cat > "$package_root/DEBIAN/control" <<EOF
Package: $package
Version: $version
Architecture: arm64
Maintainer: Hari Pi <noreply@hari-pi.com>
Pre-Depends: coreutils, util-linux
Section: kernel
Priority: optional
Description: MagiskBoot-preserved RMX2001 kernel boot image
 Contains a raw kernel compiled with Droidian's pinned toolchain and repacked
 into the validated stock RMX2001 boot layout. It contains no recovery image.
EOF

cat > "$package_root/DEBIAN/preinst" <<EOF
#!/bin/sh
set -eu
target=/dev/disk/by-partlabel/boot
expected_current=$STOCK_SHA256
expected_size=$BOOT_SIZE
record=/run/rmx2001-magiskboot-kernel-backup
[ "\$1" = install ] || [ "\$1" = upgrade ] || exit 0
[ "\$(uname -m)" = aarch64 ] || { echo 'Refusing: expected aarch64.' >&2; exit 1; }
[ "\$(getprop ro.product.vendor.model 2>/dev/null)" = '$DEVICE' ] || { echo 'Refusing: device model mismatch.' >&2; exit 1; }
[ -b "\$target" ] || { echo 'Refusing: boot partition not found.' >&2; exit 1; }
[ "\$(blockdev --getsize64 "\$target")" = "\$expected_size" ] || { echo 'Refusing: boot partition size mismatch.' >&2; exit 1; }
current=\$(sha256sum "\$target" | awk '{print \$1}')
[ "\$current" = "\$expected_current" ] || { echo "Refusing: current boot SHA-256 is not known-good: \$current" >&2; exit 1; }
backup=/userdata/kernel-backups/pre-magiskboot-kernel-\$(date -u +%Y%m%dT%H%M%SZ).img
install -d -m 700 /userdata/kernel-backups
dd if="\$target" of="\$backup" bs=1M status=none
sync
[ "\$(sha256sum "\$backup" | awk '{print \$1}')" = "\$expected_current" ] || { rm -f "\$backup"; echo 'Refusing: backup verification failed.' >&2; exit 1; }
chmod 600 "\$backup"
printf '%s\n' "\$backup" > "\$record"
echo "Verified rollback image: \$backup"
EOF

cat > "$package_root/DEBIAN/postinst" <<EOF
#!/bin/sh
set -eu
target=/dev/disk/by-partlabel/boot
payload=/boot/boot.img-$ABI
expected_hash=$candidate_hash
expected_size=$BOOT_SIZE
record=/run/rmx2001-magiskboot-kernel-backup
[ "\$1" = configure ] || exit 0
[ -f "\$record" ] || { echo 'Refusing: verified backup record is missing.' >&2; exit 1; }
[ "\$(stat -c %s "\$payload")" = "\$expected_size" ] || { echo 'Payload size mismatch.' >&2; exit 1; }
[ "\$(sha256sum "\$payload" | awk '{print \$1}')" = "\$expected_hash" ] || { echo 'Payload checksum mismatch.' >&2; exit 1; }
[ "\$(dd if="\$payload" bs=8 count=1 status=none)" = ANDROID! ] || { echo 'Payload Android magic mismatch.' >&2; exit 1; }
backup=\$(cat "\$record")
restore() {
    code=\$?
    if [ "\$code" -ne 0 ] && [ -f "\$backup" ]; then
        echo 'Installation failed after write began; restoring verified boot backup.' >&2
        dd if="\$backup" of="\$target" bs=1M conv=fsync status=none || true
    fi
    exit "\$code"
}
trap restore EXIT HUP INT TERM
dd if="\$payload" of="\$target" bs=1M conv=fsync status=progress
written=\$(sha256sum "\$target" | awk '{print \$1}')
[ "\$written" = "\$expected_hash" ] || { echo "Post-write checksum mismatch: \$written" >&2; exit 1; }
rm -f "\$record"
trap - EXIT HUP INT TERM
echo "Boot partition verified at \$expected_hash; reboot was not requested."
EOF
chmod 0755 "$package_root/DEBIAN/preinst" "$package_root/DEBIAN/postinst"

cat > "$package_root/usr/share/doc/$package/README.magiskboot" <<EOF
This package contains a boot image made by replacing only the kernel inside the
validated stock RMX2001 boot image with MagiskBoot. Recovery is not included or
modified. Installation requires the boot partition to match the known-good
stock SHA-256 and creates a verified backup before writing. It does not reboot.
EOF

deb="$artifact_directory/${package}_${version}_arm64.deb"
note 'building guarded boot-only Debian package'
dpkg-deb --root-owner-group --build "$package_root" "$deb"

audit_root="$cleanup_root/package-audit"
dpkg-deb -e "$deb" "$audit_root/control"
dpkg-deb -x "$deb" "$audit_root/data"
cmp "$audit_root/data/boot/boot.img-$ABI" "$candidate"
[[ ! -e $audit_root/data/boot/recovery.img-$ABI ]] || die 'package unexpectedly contains a recovery image'
grep -Fq 'target=/dev/disk/by-partlabel/boot' "$audit_root/control/postinst"
grep -Fq "expected_hash=$candidate_hash" "$audit_root/control/postinst"

install -m 0644 "$raw_kernel" "$artifact_directory/kernel-Image"
install -m 0644 "$stock_unpack/unpack-stock.log" "$artifact_directory/unpack-stock.log"
install -m 0644 "$stock_unpack/repack.log" "$artifact_directory/repack.log"
install -m 0644 "$verify_unpack/unpack-candidate.log" "$artifact_directory/unpack-candidate.log"
dpkg-deb --info "$deb" > "$artifact_directory/package-info.txt"
dpkg-deb --contents "$deb" > "$artifact_directory/package-contents.txt"

cat > "$artifact_directory/MANIFEST.txt" <<EOF
Build ID: $build_id
Source commit: $source_commit
Compiled source commit: $compiler_source_commit
Compiler artifact: $compiler_artifact
Stock boot SHA-256: $STOCK_SHA256
Stock boot size: $BOOT_SIZE bytes
MagiskBoot SHA-256: $MAGISKBOOT_SHA256
Raw kernel SHA-256: $raw_kernel_hash
Candidate boot SHA-256: $candidate_hash
Candidate boot size: $(stat -c %s "$candidate") bytes
Package: $(basename "$deb")
Package SHA-256: $(hash_file "$deb")
Preserved byte-for-byte: ramdisk.cpio, dtb, kernel_dtb
Boot layout source: MagiskBoot repack of the validated stock image
Recovery image included: no
Automatic reboot: no
Status: built and structurally verified; not installed or boot-tested
EOF
(cd "$artifact_directory" && sha256sum boot.img kernel-Image linux-bootimage-*.deb \
    PRESERVED-COMPONENTS.txt package-info.txt package-contents.txt MANIFEST.txt > SHA256SUMS)

note "MagiskBoot Debian package completed: $artifact_directory"
cat "$artifact_directory/MANIFEST.txt"
