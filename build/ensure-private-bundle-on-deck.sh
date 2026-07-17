#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

[[ "$(id -un)" == deck ]] || die "run this script as the deck user"
[[ -r /etc/os-release ]] || die "cannot read /etc/os-release"
# shellcheck source=/dev/null
source /etc/os-release
[[ ${ID:-} == steamos ]] || die "this script may only run on SteamOS"

PROJECT_ROOT="$HOME/.local/opt/steamos-waydroid"
BUILDS_ROOT="$PROJECT_ROOT/builds"
CURRENT_LINK="$PROJECT_ROOT/current"
TARGET_MISMATCH_ALLOW_FILE="$PROJECT_ROOT/allow-target-mismatch"

bundle_matches_current_target() {
    local candidate="$1"
    [[ -d "$candidate" ]] || return 1
    [[ -f "$candidate/.verified" ]] || return 1
    [[ -x "$candidate/tools/check-bundle-target.sh" ]] || return 1
    "$SCRIPT_DIR/verify-private-bundle.sh" "$candidate" > /dev/null 2>&1 || return 1
    "$candidate/tools/check-bundle-target.sh" "$candidate" > /dev/null 2>&1
}

activate_bundle() {
    local candidate="$1"
    local bundle_version
    bundle_version="$(basename -- "$candidate")"
    [[ "$bundle_version" =~ ^[A-Za-z0-9._-]+$ ]] || \
        die "unsafe installed bundle directory: $candidate"
    mkdir -p "$BUILDS_ROOT"
    (
        cd "$PROJECT_ROOT"
        ln -sfn "builds/$bundle_version" current
    )
    rm -f -- "$TARGET_MISMATCH_ALLOW_FILE"
    printf 'Activated matching installed bundle: %s\n' "$bundle_version"
}

if bundle_matches_current_target "$CURRENT_LINK"; then
    printf 'Current private bundle already matches this SteamOS target: %s\n' \
        "$(basename -- "$(readlink -f "$CURRENT_LINK")")"
    exit 0
fi

printf 'Current bundle is missing or incompatible; checking installed bundles...\n'
while IFS= read -r candidate; do
    if bundle_matches_current_target "$candidate"; then
        activate_bundle "$candidate"
        exit 0
    fi
done < <(find "$BUILDS_ROOT" -mindepth 1 -maxdepth 1 -type d -print 2> /dev/null | sort -r)

printf 'No matching local bundle is installed; checking the artifact source...\n'
"$SCRIPT_DIR/install-private-bundle-on-deck.sh"

if ! bundle_matches_current_target "$CURRENT_LINK"; then
    die "artifact installation did not activate a bundle matching this SteamOS target"
fi

printf 'A matching private bundle is installed and active.\n'
