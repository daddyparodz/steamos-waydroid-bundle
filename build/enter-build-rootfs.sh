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
    die "target build environment missing; rerun build/sync-steamos-rootfs.sh"
ROOTFS_ROOT="$TARGET_WORK_ROOT/rootfs"
SOURCE_ROOT="$BUILD_WORK_ROOT/src"
OUTPUT_ROOT="$BUILD_WORK_ROOT/out"

[[ -x "$ROOTFS_ROOT/usr/bin/bash" ]] || \
    die "SteamOS rootfs not found; run build/sync-steamos-rootfs.sh first"
[[ $(stat -c '%u:%g' "$ROOTFS_ROOT") == 0:0 ]] || \
    die "SteamOS rootfs must be owned by root; rerun build/sync-steamos-rootfs.sh"

mkdir -p "$SOURCE_ROOT" "$OUTPUT_ROOT"

printf 'Entering the copied SteamOS rootfs.\n'
printf 'First prepare with: /repo/build/prepare-build-rootfs.sh\n'
printf 'Then build with:    /repo/build/build-private-bundle.sh\n\n'

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
    /usr/bin/bash
