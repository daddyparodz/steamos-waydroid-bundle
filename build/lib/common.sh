#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

BUILD_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd -- "$BUILD_SCRIPT_DIR/.." && pwd)"
BUILD_CONFIG_FILE="${BUILD_CONFIG_FILE:-$REPO_ROOT/.build-config.env}"
CALLER_BUNDLE_VERSION="${BUNDLE_VERSION:-}"

if [[ -f "$BUILD_CONFIG_FILE" ]]; then
    # This file is user-owned local configuration and is never run as root on
    # the Steam Deck.
    # shellcheck source=/dev/null
    source "$BUILD_CONFIG_FILE"
fi

BUILD_WORK_ROOT="${BUILD_WORK_ROOT:-$HOME/steamos-waydroid-personal}"
BUNDLE_VERSION="${CALLER_BUNDLE_VERSION:-${BUNDLE_VERSION:-auto}}"
BUNDLE_REVISION="${BUNDLE_REVISION:-r1}"
WLROOTS_VERSION="${WLROOTS_VERSION:-0.18.2}"
PUBLISH_ROOT="${PUBLISH_ROOT:-$BUILD_WORK_ROOT/publish}"
TARGET_FINGERPRINT_FILE="${TARGET_FINGERPRINT_FILE:-$BUILD_WORK_ROOT/target-fingerprint.env}"
TARGETS_ROOT="${TARGETS_ROOT:-$BUILD_WORK_ROOT/targets}"
TARGET_WORK_ROOT="${TARGET_WORK_ROOT:-}"

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

resolve_bundle_version() {
    local candidate candidate_version selected_fingerprint target_environment
    selected_fingerprint="$TARGET_FINGERPRINT_FILE"
    if [[ "$BUNDLE_VERSION" == auto ]]; then
        [[ -r "$selected_fingerprint" ]] || \
            die "target fingerprint missing; run build/sync-steamos-rootfs.sh first"
        # shellcheck source=target-fingerprint.sh
        source "$BUILD_SCRIPT_DIR/lib/target-fingerprint.sh"
        BUNDLE_VERSION="$(fingerprint_value \
            "$selected_fingerprint" SUGGESTED_BUNDLE_VERSION)"
    else
        # Locate retained target metadata when selecting an older manual
        # bundle version rather than the most recently synced target.
        for candidate in "$TARGETS_ROOT"/*/target-fingerprint.env; do
            [[ -r "$candidate" ]] || continue
            candidate_version="$(awk -F= \
                '$1 == "SUGGESTED_BUNDLE_VERSION" {print $2; exit}' "$candidate")"
            if [[ "$candidate_version" == "$BUNDLE_VERSION" ]]; then
                selected_fingerprint="$candidate"
                break
            fi
        done
    fi
    [[ "$BUNDLE_VERSION" =~ ^[A-Za-z0-9._-]+$ ]] || \
        die "unsafe BUNDLE_VERSION: $BUNDLE_VERSION"
    target_environment="$(awk -F= \
        '$1 == "TARGET_ENVIRONMENT_ID" {print $2; exit}' "$selected_fingerprint")"
    if [[ -n "$target_environment" ]] && \
        [[ -r "$TARGETS_ROOT/$target_environment/target-fingerprint.env" ]]; then
        TARGET_WORK_ROOT="$TARGETS_ROOT/$target_environment"
        TARGET_FINGERPRINT_FILE="$TARGET_WORK_ROOT/target-fingerprint.env"
    fi
}

require_steamos_root() {
    [[ -r /etc/os-release ]] || die "cannot read /etc/os-release"
    # shellcheck source=/dev/null
    source /etc/os-release
    [[ ${ID:-} == steamos ]] || \
        die "this build step must run inside the copied SteamOS rootfs"
    [[ $(uname -m) == x86_64 ]] || die "only x86_64 is supported"
}
