#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_non_root
require_command systemd-nspawn
require_command sudo

resolve_bundle_version

[[ -n "$TARGET_WORK_ROOT" ]] || \
    die "target build environment missing; rerun maintainer/sync-steamos-rootfs.sh"
ROOTFS_ROOT="$TARGET_WORK_ROOT/rootfs"
SOURCE_ROOT="$BUILD_WORK_ROOT/src"
OUTPUT_ROOT="$BUILD_WORK_ROOT/out"

[[ -x "$ROOTFS_ROOT/usr/bin/bash" ]] || \
    die "SteamOS rootfs not found; run maintainer/sync-steamos-rootfs.sh first"
[[ $(stat -c '%u:%g' "$ROOTFS_ROOT") == 0:0 ]] || \
    die "SteamOS rootfs must be owned by root; rerun maintainer/sync-steamos-rootfs.sh"
[[ -r "$ROOTFS_ROOT/.steamos-waydroid-copied-build-root" ]] && \
    grep -Fx 'STEAMOS_WAYDROID_COPIED_BUILD_ROOT=1' \
        "$ROOTFS_ROOT/.steamos-waydroid-copied-build-root" > /dev/null || \
    die "copied-build-root marker is missing; rerun maintainer/sync-steamos-rootfs.sh"

mkdir -p "$SOURCE_ROOT" "$OUTPUT_ROOT"

container_command=(/usr/bin/bash)
if (( $# > 0 )); then
    container_command=("$@")
fi

printf 'Entering the copied SteamOS rootfs.\n'
printf 'First prepare with: /repo/maintainer/prepare-build-rootfs.sh\n'
printf 'Then build the bundled compositor and host packages with:\n'
printf '  /repo/maintainer/build-bundle.sh\n\n'

sudo systemd-nspawn \
    --directory="$ROOTFS_ROOT" \
    --bind-ro="$REPO_ROOT:/repo" \
    --bind="$SOURCE_ROOT:/work/src" \
    --bind="$OUTPUT_ROOT:/work/out" \
    --bind-ro="$TARGET_FINGERPRINT_FILE:/work/target-fingerprint.env" \
    --setenv="BUNDLE_VERSION=$BUNDLE_VERSION" \
    --setenv="TARGET_FINGERPRINT_FILE=/work/target-fingerprint.env" \
    --setenv="REPORT_ROOT=/work/out/reports" \
    --setenv="HOST_UID=$(id -u)" \
    --setenv="HOST_GID=$(id -g)" \
    "${container_command[@]}"
