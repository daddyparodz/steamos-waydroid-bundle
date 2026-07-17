#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_non_root
require_command systemd-nspawn
require_command sudo

ROOTFS_ROOT="$BUILD_WORK_ROOT/rootfs"
SOURCE_ROOT="$BUILD_WORK_ROOT/src"
OUTPUT_ROOT="$BUILD_WORK_ROOT/out"

[[ -x "$ROOTFS_ROOT/usr/bin/bash" ]] || \
    die "SteamOS rootfs not found; run build/sync-steamos-rootfs.sh first"

mkdir -p "$SOURCE_ROOT" "$OUTPUT_ROOT"

printf 'Entering the copied SteamOS rootfs.\n'
printf 'Build with: /repo/build/build-private-bundle.sh\n\n'

sudo systemd-nspawn \
    --directory="$ROOTFS_ROOT" \
    --bind-ro="$REPO_ROOT:/repo" \
    --bind="$SOURCE_ROOT:/work/src" \
    --bind="$OUTPUT_ROOT:/work/out" \
    --setenv="BUNDLE_VERSION=$BUNDLE_VERSION" \
    --setenv="HOST_UID=$(id -u)" \
    --setenv="HOST_GID=$(id -g)" \
    /usr/bin/bash

