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

[[ -n "$TARGET_WORK_ROOT" ]] ||
	die "target build environment missing; run maintainer/sync-steamos-image-rootfs.sh or maintainer/sync-steamos-rootfs.sh"
ROOTFS_ROOT="$TARGET_WORK_ROOT/rootfs"
SOURCE_ROOT="$BUILD_WORK_ROOT/src"
OUTPUT_ROOT="$BUILD_WORK_ROOT/out"

[[ -x "$ROOTFS_ROOT/usr/bin/bash" ]] ||
	die "SteamOS rootfs not found; run a SteamOS rootfs sync first"
[[ $(stat -c '%u:%g' "$ROOTFS_ROOT") == 0:0 ]] ||
	die "SteamOS rootfs must be owned by root; rerun the rootfs sync"
[[ -r "$ROOTFS_ROOT/.steamos-waydroid-copied-build-root" ]] &&
	grep -Fx 'STEAMOS_WAYDROID_COPIED_BUILD_ROOT=1' \
		"$ROOTFS_ROOT/.steamos-waydroid-copied-build-root" >/dev/null ||
	die "copied-build-root marker is missing; rerun the rootfs sync"

mkdir -p "$SOURCE_ROOT" "$OUTPUT_ROOT"

container_command=(/usr/bin/bash)
if (($# > 0)); then
	container_command=("$@")
fi

printf 'Entering the copied SteamOS rootfs.\n'
printf 'Selected compositor versions:\n'
printf '  wlroots: %s\n' "$WLROOTS_VERSION"
printf '  Cage:    %s\n' "$CAGE_VERSION"
printf 'Selected bundle version:\n'
printf '  Target Bundle:    %s\n' "$BUNDLE_VERSION"
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
	--setenv="WLROOTS_VERSION=$WLROOTS_VERSION" \
	--setenv="CAGE_VERSION=$CAGE_VERSION" \
	--setenv="TARGET_FINGERPRINT_FILE=/work/target-fingerprint.env" \
	--setenv="REPORT_ROOT=/work/out/reports" \
	--setenv="HOST_UID=$(id -u)" \
	--setenv="HOST_GID=$(id -g)" \
	"${container_command[@]}"
