#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

BUILD_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd -- "$BUILD_SCRIPT_DIR/.." && pwd)"
BUILD_CONFIG_FILE="${BUILD_CONFIG_FILE:-$REPO_ROOT/.build-config.env}"

if [[ -f "$BUILD_CONFIG_FILE" ]]; then
    # This file is user-owned local configuration and is never run as root on
    # the Steam Deck.
    # shellcheck source=/dev/null
    source "$BUILD_CONFIG_FILE"
fi

BUILD_WORK_ROOT="${BUILD_WORK_ROOT:-$HOME/steamos-waydroid-personal}"
BUNDLE_VERSION="${BUNDLE_VERSION:-personal-1}"

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    local command_name="$1"
    command -v "$command_name" >/dev/null 2>&1 || \
        die "required command not found: $command_name"
}

require_non_root() {
    [[ $EUID -ne 0 ]] || die "run this command as your normal Fedora user"
}

require_steamos_root() {
    [[ -r /etc/os-release ]] || die "cannot read /etc/os-release"
    # shellcheck source=/dev/null
    source /etc/os-release
    [[ ${ID:-} == steamos ]] || \
        die "this build step must run inside the copied SteamOS rootfs"
    [[ $(uname -m) == x86_64 ]] || die "only x86_64 is supported"
}

