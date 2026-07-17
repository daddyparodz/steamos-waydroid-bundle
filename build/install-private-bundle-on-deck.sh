#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="${DECK_CONFIG_FILE:-$REPO_ROOT/.deck-config.env}"

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

[[ "$(id -un)" == deck ]] || die "run this script as the deck user"
[[ -r /etc/os-release ]] || die "cannot read /etc/os-release"
# shellcheck source=/dev/null
source /etc/os-release
[[ ${ID:-} == steamos ]] || die "this script may only run on SteamOS"
[[ -f "$CONFIG_FILE" ]] || \
    die "copy build/deck-config.example.env to .deck-config.env and edit it"
# shellcheck source=/dev/null
source "$CONFIG_FILE"

ARTIFACT_SOURCE="${ARTIFACT_SOURCE:-}"
BUNDLE_VERSION="${BUNDLE_VERSION:-}"
[[ -n "$ARTIFACT_SOURCE" ]] || die "ARTIFACT_SOURCE is not configured"
[[ "$BUNDLE_VERSION" =~ ^[A-Za-z0-9._-]+$ ]] || die "unsafe BUNDLE_VERSION"

for command_name in sha256sum tar; do
    command -v "$command_name" > /dev/null || die "required command not found: $command_name"
done

ARCHIVE_NAME="$BUNDLE_VERSION.tar.gz"
HASH_NAME="$ARCHIVE_NAME.sha256"
PROJECT_ROOT="$HOME/.local/opt/steamos-waydroid"
TARGET_ROOT="$PROJECT_ROOT/builds/$BUNDLE_VERSION"
STAGING_ROOT="$PROJECT_ROOT/.$BUNDLE_VERSION.staging"
mkdir -p "$HOME/.cache"
DOWNLOAD_ROOT="$(mktemp -d "$HOME/.cache/steamos-waydroid-artifact.XXXXXX")"
cleanup() {
    rm -rf -- "$DOWNLOAD_ROOT"
}
trap cleanup EXIT

fetch_file() {
    local filename="$1"
    case "$ARTIFACT_SOURCE" in
        https://*|http://*)
            command -v curl > /dev/null || die "curl is required for an HTTP artifact source"
            curl --fail --location \
                "$ARTIFACT_SOURCE/$filename" \
                --output "$DOWNLOAD_ROOT/$filename"
            ;;
        *:*)
            command -v rsync > /dev/null || die "rsync is required for an SSH artifact source"
            rsync -a -- "$ARTIFACT_SOURCE/$filename" "$DOWNLOAD_ROOT/$filename"
            ;;
        *)
            die "ARTIFACT_SOURCE must be an SSH rsync source or an http(s) URL"
            ;;
    esac
}

printf 'Fetching private bundle %s...\n' "$BUNDLE_VERSION"
fetch_file "$ARCHIVE_NAME"
fetch_file "$HASH_NAME"

printf 'Checking artifact hash...\n'
(
    cd "$DOWNLOAD_ROOT"
    sha256sum --check "$HASH_NAME"
)

printf 'Checking archive paths before extraction...\n'
while IFS= read -r member; do
    case "$member" in
        "$BUNDLE_VERSION"|"$BUNDLE_VERSION/"*) ;;
        *) die "archive contains a path outside $BUNDLE_VERSION: $member" ;;
    esac
    case "/$member/" in
        */../*) die "archive contains parent traversal: $member" ;;
    esac
done < <(tar -tzf "$DOWNLOAD_ROOT/$ARCHIVE_NAME")

mkdir -p "$PROJECT_ROOT/builds"
if [[ -e "$TARGET_ROOT" ]]; then
    printf 'Bundle version already exists; verifying it without overwriting.\n'
else
    [[ ! -e "$STAGING_ROOT" ]] || \
        mv "$STAGING_ROOT" "$STAGING_ROOT.failed-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$DOWNLOAD_ROOT/extracted"
    tar -xzf "$DOWNLOAD_ROOT/$ARCHIVE_NAME" \
        --no-same-owner --no-same-permissions \
        -C "$DOWNLOAD_ROOT/extracted"
    mv "$DOWNLOAD_ROOT/extracted/$BUNDLE_VERSION" "$STAGING_ROOT"
    mv "$STAGING_ROOT" "$TARGET_ROOT"
fi

printf 'Verifying the bundle against this SteamOS host...\n'
"$SCRIPT_DIR/verify-private-bundle.sh" "$TARGET_ROOT"
[[ -f "$TARGET_ROOT/.verified" ]] || die "artifact has no build verification marker"

(
    cd "$PROJECT_ROOT"
    ln -sfn "builds/$BUNDLE_VERSION" current
)

printf '\nPrivate bundle installed and activated:\n  %s\n' "$TARGET_ROOT"
