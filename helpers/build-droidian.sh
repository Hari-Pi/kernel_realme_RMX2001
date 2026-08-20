#!/usr/bin/env bash
set -Eeuo pipefail

readonly IMAGE='quay.io/droidian/build-essential@sha256:53a9ebae9787b2d74c56974ae9b0727aae81409fdff612aca1f97b1083c9fd49'
readonly IMAGE_ID='sha256:cc97ed18ab572816258ee104bbf5433c50e9e00dadfb5251c273be0b0f17247b'
readonly SNIPPETS_VERSION='45+git20260713160329.54d2db9.next.production'
readonly KEY_SHA256='0f8014a75ed6ef25ee00fa8f6142290ee1679fe0c701b48b71ed6e9c57b32f60'
readonly KEY_FINGERPRINT='B03DFCE15F8CCC2B3F4B65945E775B2A27AB0C94'
readonly ABI='4.14.141-realme-rmx2001'
readonly BOOT_PARTITION_SIZE='33554432'
readonly BOOT_CMDLINE='bootopt=64S3,32N2,64N2 buildvariant=userdebug droidian.lvm.prefer systemd.unified_cgroup_hierarchy=0'

root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
mode=build
allow_dirty=0
jobs=${JOBS:-}
output_root=${OUTPUT_DIR:-"$(dirname "$root")/rmx2001-kernel-artifacts"}
key_file=${DROIDIAN_KEY_FILE:-"$root/helpers/keys/droidian.gpg"}
build_tree=
artifact_directory=
build_succeeded=0

usage() {
    cat <<'EOF'
Usage: ./build.sh [OPTIONS]

Checks the RMX2001 Droidian build environment and builds a verified boot-image
Debian package in an isolated clean checkout.

Options:
  --check-only       Validate prerequisites without compiling
  --allow-dirty      Permit a dirty source tree (recorded in the manifest)
  --jobs N           Limit build CPUs (default: all available host CPUs)
  --key FILE         Override the bundled Droidian archive public key
  --output DIR       Artifact root outside the source tree
  -h, --help         Show this help

The invoking user must be able to run Docker. The script never flashes a device.
EOF
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
note() { printf '==> %s\n' "$*"; }
require() { command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"; }
detect_jobs() {
    if command -v nproc >/dev/null 2>&1; then
        nproc
    elif command -v getconf >/dev/null 2>&1; then
        getconf _NPROCESSORS_ONLN
    else
        die 'unable to detect available CPUs; install coreutils or pass --jobs N'
    fi
}

while (($#)); do
    case $1 in
        --check-only) mode=check; shift ;;
        --allow-dirty) allow_dirty=1; shift ;;
        --jobs) (($# >= 2)) || die '--jobs requires a value'; jobs=$2; shift 2 ;;
        --key) (($# >= 2)) || die '--key requires a value'; key_file=$2; shift 2 ;;
        --output) (($# >= 2)) || die '--output requires a value'; output_root=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

[[ -n $jobs ]] || jobs=$(detect_jobs)
[[ $jobs =~ ^[1-9][0-9]*$ ]] || die '--jobs must be a positive integer'
[[ $(uname -s) == Linux ]] || die 'build host must be Linux (WSL 2 is supported)'
[[ $(uname -m) == x86_64 ]] || die 'build host must be x86_64/amd64'

for command in awk df docker git grep sha256sum stat tar; do require "$command"; done
docker info >/dev/null 2>&1 || die 'Docker daemon is unavailable; run with Docker access or appropriate privileges'
git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die 'source is not a Git checkout'

dirty=$(git -C "$root" status --porcelain --untracked-files=normal)
if [[ -n $dirty && $allow_dirty -ne 1 ]]; then
    printf '%s\n' "$dirty" >&2
    die 'source tree is dirty; commit/stash changes or pass --allow-dirty'
fi

[[ -f $key_file ]] || die "Droidian archive key is missing: $key_file (use --key FILE)"
[[ $(sha256sum "$key_file" | awk '{print $1}') == "$KEY_SHA256" ]] || die 'Droidian archive key checksum mismatch'
docker run --rm \
    -e KEY_FINGERPRINT="$KEY_FINGERPRINT" \
    -v "$key_file:/tmp/droidian.gpg:ro" \
    "$IMAGE" sh -eu -c \
    'gpg --show-keys --with-colons /tmp/droidian.gpg 2>/dev/null | grep -q "fpr:::::::::$KEY_FINGERPRINT:"' || \
    die 'Droidian archive key fingerprint mismatch'

[[ -f $root/arch/arm64/configs/RMX2001_defconfig ]] || die 'RMX2001_defconfig is missing'
[[ -f $root/arch/arm64/boot/dts/mediatek/mt6785.dts ]] || die 'mt6785.dts is missing'
grep -Eq '^DEVICE_HAS_INIT_BOOT[[:space:]]*=[[:space:]]*0([[:space:]]*)$' "$root/debian/kernel-info.mk" || die 'DEVICE_HAS_INIT_BOOT must be 0'
grep -Eq '^KERNEL_BOOTIMAGE_VERSION[[:space:]]*=[[:space:]]*2([[:space:]]*)$' "$root/debian/kernel-info.mk" || die 'boot header version must be 2'
grep -Fqx "KERNEL_BOOTIMAGE_CMDLINE = $BOOT_CMDLINE" "$root/debian/kernel-info.mk" || die 'boot command line does not match the validated RMX2001 layout'
grep -Eq '^FLASH_IS_AONLY[[:space:]]*=[[:space:]]*1([[:space:]]*)$' "$root/debian/kernel-info.mk" || die 'RMX2001 flashing must use the A-only boot partition layout'
grep -Eq '^CLANG_VERSION[[:space:]]*=[[:space:]]*6\.0-4691093([[:space:]]*)$' "$root/debian/kernel-info.mk" || die 'CLANG_VERSION must select Droidian Clang 6'
grep -Eq '^BUILD_PATH[[:space:]]*=[[:space:]]*/usr/lib/llvm-android-6\.0-4691093/bin([[:space:]]*)$' "$root/debian/kernel-info.mk" || die 'BUILD_PATH must use Droidian packaged Clang 6'
grep -q '^out/KERNEL_OBJ/init_boot-default\.img:' "$root/debian/rules" || die 'header-v2 init_boot workaround is missing'

space_path=$output_root
while [[ ! -e $space_path ]]; do
    parent=$(dirname "$space_path")
    [[ $parent != "$space_path" ]] || die "cannot find an existing parent for output path: $output_root"
    space_path=$parent
done
available_kib=$(df -Pk "$space_path" | awk 'NR==2 {print $4}')
if [[ $available_kib -lt 26214400 ]]; then
    die 'at least 25 GiB free space is required at the artifact destination'
fi

note "source commit: $(git -C "$root" rev-parse HEAD)"
note "container: $IMAGE"
note "Droidian snippets: $SNIPPETS_VERSION"
note "jobs: $jobs"
note "preflight checks passed"
[[ $mode == build ]] || exit 0

docker pull "$IMAGE" >/dev/null
actual_image_id=$(docker image inspect "$IMAGE" --format '{{.Id}}')
[[ $actual_image_id == "$IMAGE_ID" ]] || die "container image ID mismatch: $actual_image_id"

mkdir -p "$output_root"
output_root=$(cd "$output_root" && pwd)
build_id="$(date -u +%Y%m%dT%H%M%SZ)-$(git -C "$root" rev-parse --short=12 HEAD)"
artifact_directory="$output_root/$build_id"
mkdir "$artifact_directory"
build_temp_root=${BUILD_TMPDIR:-$(dirname "$root")}
[[ -d $build_temp_root ]] || die "build temporary directory does not exist: $build_temp_root"
build_tree=$(mktemp -d "$build_temp_root/.rmx2001-kernel-build.XXXXXX")
host_uid=$(id -u)
host_gid=$(id -g)

cleanup() {
    if [[ $build_succeeded -ne 1 && -n ${artifact_directory:-} && -d $artifact_directory ]]; then
        docker run --rm -v "$artifact_directory:/artifacts" "$IMAGE" \
            sh -c 'rm -f /artifacts/boot.img /artifacts/MANIFEST.txt /artifacts/SHA256SUMS; printf "%s\n" "Build did not pass final validation. See build.log." > /artifacts/FAILED.txt; chown -R "$1:$2" /artifacts' sh "$host_uid" "$host_gid" >/dev/null 2>&1 || true
    fi
    if [[ -n ${build_tree:-} && -d $build_tree && ${KEEP_BUILD_TREE:-0} != 1 ]]; then
        docker run --rm -v "$build_tree:/cleanup" "$IMAGE" \
            chown -R "$host_uid:$host_gid" /cleanup >/dev/null 2>&1 || true
        rm -rf -- "$build_tree"
    fi
}
trap cleanup EXIT

note "creating isolated source checkout"
git clone --quiet --local --no-checkout "$root" "$build_tree/source"
git -C "$build_tree/source" checkout --quiet --detach "$(git -C "$root" rev-parse HEAD)"
if [[ $allow_dirty -eq 1 && -n $dirty ]]; then
    git -C "$root" diff --binary HEAD | git -C "$build_tree/source" apply
    git -C "$root" ls-files --others --exclude-standard | while IFS= read -r file; do
        mkdir -p "$build_tree/source/$(dirname "$file")"
        cp -a "$root/$file" "$build_tree/source/$file"
    done
fi

note "building official Droidian packages"
docker run --rm \
    --cpus "$jobs" \
    -e RELENG_HOST_ARCH=arm64 \
    -e HOST_UID="$host_uid" \
    -e HOST_GID="$host_gid" \
    -e BUILD_JOBS="$jobs" \
    -e SNIPPETS_VERSION="$SNIPPETS_VERSION" \
    -e KEY_SHA256="$KEY_SHA256" \
    -e KEY_FINGERPRINT="$KEY_FINGERPRINT" \
    -e ABI="$ABI" \
    -e BOOT_PARTITION_SIZE="$BOOT_PARTITION_SIZE" \
    -e BOOT_CMDLINE="$BOOT_CMDLINE" \
    -v "$artifact_directory:/buildd" \
    -v "$build_tree/source:/buildd/sources" \
    -v "$key_file:/tmp/droidian.gpg:ro" \
    "$IMAGE" bash -Eeuo pipefail -c '
        test "$(sha256sum /tmp/droidian.gpg | awk "{print \$1}")" = "$KEY_SHA256"
        gpg --show-keys --with-colons /tmp/droidian.gpg | grep -q "fpr:::::::::$KEY_FINGERPRINT:"
        install -m 0644 /tmp/droidian.gpg /etc/apt/trusted.gpg.d/droidian.gpg
        mkdir -p /etc/apt/sources.disabled
        for source in /etc/apt/sources.list.d/*; do
            case "$(basename "$source")" in
                debian.sources|droidian.sources) ;;
                *) mv "$source" /etc/apt/sources.disabled/ ;;
            esac
        done
        apt-get update
        apt-get install -y "linux-packaging-snippets=$SNIPPETS_VERSION"
        test "$(dpkg-query -W -f="\${Version}" linux-packaging-snippets)" = "$SNIPPETS_VERSION"

        cd /buildd/sources
        git config --global --add safe.directory /buildd/sources
        rm -f debian/control debian/files
        debian/rules debian/control
        grep -q "clang-android-6.0-4691093" debian/control
        if grep -q "clang-android-," debian/control; then
            echo "Generated control contains an empty clang package version." >&2
            exit 1
        fi
        echo "Starting releng build; source metadata finalization may be quiet for several minutes."
        mkdir -p /tmp/releng-build-tools
        printf "#!/bin/sh\nprintf '\''%%s\\n'\'' '\''%s'\''\n" "$BUILD_JOBS" > /tmp/releng-build-tools/nproc
        chmod +x /tmp/releng-build-tools/nproc
        export PATH="/tmp/releng-build-tools:$PATH"
        export DEB_BUILD_OPTIONS="parallel=$BUILD_JOBS"
        RELENG_HOST_ARCH=arm64 releng-build-package &
        releng_pid=$!
        while kill -0 "$releng_pid" 2>/dev/null; do
            sleep 30
            if kill -0 "$releng_pid" 2>/dev/null; then
                echo "Build still active at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
            fi
        done
        wait "$releng_pid"
        echo "Droidian package build complete; validating artifacts."

        set -- /buildd/linux-bootimage-"$ABI"_*_arm64.deb
        test "$#" -eq 1
        test -f "$1"
        package=$1
        extract=$(mktemp -d)
        echo "Extracting boot image from $(basename "$package")."
        dpkg-deb -x "$package" "$extract"
        boot="$extract/boot/boot.img-$ABI"
        flash_config="$extract/lib/flash-bootimage/$ABI.conf"
        test -s "$boot"
        test -s "$flash_config"
        grep -Fqx "DEVICE_IS_AB=no" "$flash_config"
        grep -Fqx "BOOTIMAGE_SLOT_A=\"/dev/disk/by-partlabel/boot\"" "$flash_config"
        grep -Fqx "DEVICE_HAS_DTBO_PARTITION=no" "$flash_config"
        grep -Fqx "DEVICE_HAS_VBMETA_PARTITION=no" "$flash_config"
        size=$(stat -c %s "$boot")
        test "$size" -le "$BOOT_PARTITION_SIZE"
        test "$(dd if="$boot" bs=8 count=1 status=none)" = "ANDROID!"
        audit=$(mktemp -d)
        header=$(unpack_bootimg --boot_img "$boot" --out "$audit" 2>&1)
        printf "%s\n" "$header"
        printf "%s\n" "$header" | grep -Fqx "boot image header version: 2"
        printf "%s\n" "$header" | grep -Fqx "page size: 2048"
        printf "%s\n" "$header" | grep -Fqx "kernel load address: 0x40080000"
        printf "%s\n" "$header" | grep -Fqx "ramdisk load address: 0x47c80000"
        printf "%s\n" "$header" | grep -Fqx "kernel tags load address: 0x4bc80000"
        printf "%s\n" "$header" | grep -Fqx "dtb address: 0x000000004bc80000"
        printf "%s\n" "$header" | grep -Fqx "command line args: $BOOT_CMDLINE"
        test -s "$audit/kernel"
        test -s "$audit/ramdisk"
        test -s "$audit/dtb"
        test "$(od -An -tx1 -N2 "$audit/kernel" | tr -d " \n")" = 1f8b
        test "$(od -An -tx1 -N2 "$audit/ramdisk" | tr -d " \n")" = 1f8b
        test "$(od -An -tx1 -N4 "$audit/dtb" | tr -d " \n")" = d00dfeed
        install -m 0644 "$boot" /buildd/boot.img
        dpkg-deb --info "$package" > /buildd/package-info.txt
        dpkg-deb --contents "$package" > /buildd/package-contents.txt
        printf "%s\n" "$SNIPPETS_VERSION" > /buildd/linux-packaging-snippets.version
        test -x /usr/lib/llvm-android-6.0-4691093/bin/clang
        dpkg-query -W -f="\${Package} \${Version}\n" clang-android-6.0-4691093 > /buildd/compiler.version
        test -s /buildd/compiler.version
        chown -R "$HOST_UID:$HOST_GID" /buildd
    ' 2>&1 | tee "$artifact_directory/build.log"

boot="$artifact_directory/boot.img"
package=$(find "$artifact_directory" -maxdepth 1 -type f -name "linux-bootimage-${ABI}_*_arm64.deb" -print)
[[ -n $package && $package != *$'\n'* ]] || die 'expected exactly one boot-image package'
[[ $(dd if="$boot" bs=8 count=1 status=none) == 'ANDROID!' ]] || die 'final boot image header check failed'

source_commit=$(git -C "$root" rev-parse HEAD)
source_state=clean
[[ -z $dirty ]] || source_state=dirty
cat > "$artifact_directory/MANIFEST.txt" <<EOF
Build ID: $build_id
Source commit: $source_commit
Source state: $source_state
Container: $IMAGE
Container image ID: $IMAGE_ID
linux-packaging-snippets: $SNIPPETS_VERSION
Compiler: $(cat "$artifact_directory/compiler.version")
Boot image: $(basename "$boot")
Boot image size: $(stat -c %s "$boot") bytes
Boot partition limit: $BOOT_PARTITION_SIZE bytes
Boot image SHA-256: $(sha256sum "$boot" | awk '{print $1}')
Package: $(basename "$package")
Package SHA-256: $(sha256sum "$package" | awk '{print $1}')
Status: built and structurally verified; not boot-tested
EOF
(cd "$artifact_directory" && sha256sum boot.img linux-bootimage-*.deb package-info.txt package-contents.txt compiler.version linux-packaging-snippets.version MANIFEST.txt > SHA256SUMS)
rm -f "$artifact_directory/FAILED.txt"
build_succeeded=1

note "build completed: $artifact_directory"
cat "$artifact_directory/MANIFEST.txt"
