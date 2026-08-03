#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

[[ ${EUID:-1} -eq 0 ]] || {
    printf 'error: run inside the copied SteamOS rootfs as root\n' >&2
    exit 1
}
[[ -r /.steamos-waydroid-copied-build-root ]] && \
    grep -Fx 'STEAMOS_WAYDROID_COPIED_BUILD_ROOT=1' \
        /.steamos-waydroid-copied-build-root > /dev/null || {
    printf 'error: copied-build-root marker is missing; refusing to run on the live Steam Deck\n' >&2
    exit 1
}

/repo/maintainer/prepare-build-rootfs.sh
/repo/maintainer/build-private-bundle.sh
