#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -r "$SCRIPT_DIR/lib/target-fingerprint.sh" ]]; then
    # shellcheck source=lib/target-fingerprint.sh
    source "$SCRIPT_DIR/lib/target-fingerprint.sh"
elif [[ -r "$SCRIPT_DIR/target-fingerprint.sh" ]]; then
    # Installed bundle layout.
    # shellcheck source=lib/target-fingerprint.sh
    source "$SCRIPT_DIR/target-fingerprint.sh"
else
    printf 'error: target fingerprint helper is missing\n' >&2
    exit 1
fi

BUNDLE_ROOT="${1:-}"
ALLOW_MISMATCH=false
if [[ ${2:-} == --allow-target-mismatch ]]; then
    ALLOW_MISMATCH=true
elif [[ $# -ne 1 ]]; then
    printf 'usage: %s BUNDLE_DIRECTORY [--allow-target-mismatch]\n' "$0" >&2
    exit 1
fi

EXPECTED="$BUNDLE_ROOT/target-fingerprint.env"
[[ -r "$EXPECTED" ]] || {
    printf 'error: bundle target fingerprint is missing: %s\n' "$EXPECTED" >&2
    exit 1
}

CURRENT="$(mktemp)"
cleanup() {
    rm -f -- "$CURRENT"
}
trap cleanup EXIT
collect_target_fingerprint "$CURRENT"

expected_version="$(fingerprint_value "$EXPECTED" STEAMOS_VERSION_ID)"
expected_build="$(fingerprint_value "$EXPECTED" STEAMOS_BUILD_ID)"
expected_abi="$(fingerprint_value "$EXPECTED" ABI_SHA256)"
current_version="$(fingerprint_value "$CURRENT" STEAMOS_VERSION_ID)"
current_build="$(fingerprint_value "$CURRENT" STEAMOS_BUILD_ID)"
current_abi="$(fingerprint_value "$CURRENT" ABI_SHA256)"

mismatches=()
[[ "$expected_version" == "$current_version" ]] || \
    mismatches+=("SteamOS version: built for $expected_version, running $current_version")
[[ "$expected_build" == "$current_build" ]] || \
    mismatches+=("SteamOS build: built for $expected_build, running $current_build")
[[ "$expected_abi" == "$current_abi" ]] || \
    mismatches+=("userspace ABI fingerprint: built for $expected_abi, running $current_abi")

if (( ${#mismatches[@]} > 0 )); then
    printf 'Private bundle target mismatch:\n' >&2
    printf '  %s\n' "${mismatches[@]}" >&2
    if [[ "$ALLOW_MISMATCH" != true ]]; then
        printf 'Rebuild for this SteamOS target, or explicitly use --allow-target-mismatch for testing.\n' >&2
        exit 1
    fi
    printf 'WARNING: continuing with an explicitly allowed target mismatch.\n' >&2
else
    printf 'Bundle target matches SteamOS %s build %s (ABI %s).\n' \
        "$current_version" "$current_build" "${current_abi:0:12}"
fi
