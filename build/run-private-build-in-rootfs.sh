#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

[[ ${EUID:-1} -eq 0 ]] || {
    printf 'error: run inside the copied SteamOS rootfs as root\n' >&2
    exit 1
}

/repo/build/prepare-build-rootfs.sh
/repo/build/build-private-bundle.sh
