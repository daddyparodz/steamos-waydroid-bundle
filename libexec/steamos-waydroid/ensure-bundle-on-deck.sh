#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

[[ ${STEAMOS_WAYDROID_INTERNAL:-} == 1 ]] ||
	die "this is an internal helper; run ./steamos-waydroid-installer.sh"

[[ "$(id -un)" == deck ]] || die "run this script as the deck user"
[[ -r /etc/os-release ]] || die "cannot read /etc/os-release"
# shellcheck source=/dev/null
source /etc/os-release
[[ ${ID:-} == steamos ]] || die "this script may only run on SteamOS"

PROJECT_ROOT="$HOME/.local/opt/steamos-waydroid"
BUILDS_ROOT="$PROJECT_ROOT/builds"
CURRENT_LINK="$PROJECT_ROOT/current"
TARGET_MISMATCH_ALLOW_FILE="$PROJECT_ROOT/allow-target-mismatch"

bundle_compatibility_state() {
	local candidate="$1"
	local state
	[[ -d "$candidate" ]] || {
		printf 'incompatible\n'
		return
	}
	[[ -f "$candidate/.verified" ]] || {
		printf 'incompatible\n'
		return
	}
	[[ -x "$candidate/tools/check-bundle-target.sh" ]] || {
		printf 'incompatible\n'
		return
	}
	"$SCRIPT_DIR/verify-bundle.sh" "$candidate" >/dev/null 2>&1 || {
		printf 'incompatible\n'
		return
	}
	if state=$("$candidate/tools/check-bundle-target.sh" \
		"$candidate" --compatibility-state 2>/dev/null); then
		printf '%s\n' "$state"
	elif "$candidate/tools/check-bundle-target.sh" "$candidate" >/dev/null 2>&1; then
		# Bundles made before compatibility states supported exact checks only.
		printf 'exact\n'
	else
		printf 'incompatible\n'
	fi
}

activate_bundle() {
	local candidate="$1"
	local bundle_version
	bundle_version="$(basename -- "$candidate")"
	[[ "$bundle_version" =~ ^[A-Za-z0-9._-]+$ ]] ||
		die "unsafe installed bundle directory: $candidate"
	mkdir -p "$BUILDS_ROOT"
	(
		cd "$PROJECT_ROOT"
		ln -sfn "builds/$bundle_version" current
	)
	rm -f -- "$TARGET_MISMATCH_ALLOW_FILE"
	printf 'Activated %s installed bundle: %s\n' "$2" "$bundle_version"
}

if [[ "$(bundle_compatibility_state "$CURRENT_LINK")" == exact ]]; then
	printf 'Current bundle is an exact match: %s\n' \
		"$(basename -- "$(readlink -f "$CURRENT_LINK")")"
	exit 0
fi

printf 'Current bundle is missing or incompatible; checking installed bundles...\n'
while IFS= read -r candidate; do
	if [[ "$(bundle_compatibility_state "$candidate")" == exact ]]; then
		activate_bundle "$candidate" exact
		exit 0
	fi
done < <(find "$BUILDS_ROOT" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort -r)

while IFS= read -r candidate; do
	if [[ "$(bundle_compatibility_state "$candidate")" == abi-compatible ]]; then
		activate_bundle "$candidate" ABI-compatible
		printf 'Userspace ABI matches and the running kernel provides Binder.\n'
		exit 0
	fi
done < <(find "$BUILDS_ROOT" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort -r)

printf 'No matching local bundle is installed; checking the artifact source...\n'
"$SCRIPT_DIR/install-bundle-on-deck.sh"

if [[ "$(bundle_compatibility_state "$CURRENT_LINK")" == incompatible ]]; then
	die "artifact installation did not activate a bundle matching this SteamOS target"
fi

printf 'A matching target-built bundle is installed and active.\n'
