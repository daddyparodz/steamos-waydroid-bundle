#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_non_root
require_command rsync
require_command ssh

DECK_HOST="${DECK_HOST:-}"
[[ -n "$DECK_HOST" ]] || \
    die "set DECK_HOST in $BUILD_CONFIG_FILE (see build/config.example.env)"
[[ "$BUNDLE_VERSION" =~ ^[A-Za-z0-9._-]+$ ]] || \
    die "BUNDLE_VERSION may contain only letters, numbers, dots, underscores, and hyphens"

LOCAL_BUNDLE="$BUILD_WORK_ROOT/out/$BUNDLE_VERSION"
REMOTE_PROJECT_ROOT=".local/opt/steamos-waydroid"
REMOTE_BUILD="$REMOTE_PROJECT_ROOT/builds/$BUNDLE_VERSION"
REMOTE_STAGING="$REMOTE_PROJECT_ROOT/.$BUNDLE_VERSION.staging"
REMOTE_TOOLS="$REMOTE_PROJECT_ROOT/tools"

[[ -d "$LOCAL_BUNDLE" ]] || die "local bundle not found: $LOCAL_BUNDLE"
[[ -f "$LOCAL_BUNDLE/.verified" ]] || \
    die "local bundle has no verification marker: $LOCAL_BUNDLE"

printf 'Checking SSH access to %s...\n' "$DECK_HOST"
ssh "$DECK_HOST" 'test "$(id -un)" = deck'

printf 'Installing the bundle verifier under the deck user home...\n'
ssh "$DECK_HOST" "mkdir -p '$REMOTE_TOOLS'"
rsync -a \
    "$SCRIPT_DIR/verify-private-bundle.sh" \
    "$SCRIPT_DIR/lib" \
    "$DECK_HOST:$REMOTE_TOOLS/"

if ssh "$DECK_HOST" "test -e '$REMOTE_BUILD'"; then
    printf 'Version %s already exists on the Deck; verifying it without overwriting.\n' \
        "$BUNDLE_VERSION"
else
    printf 'Uploading bundle %s to a staging directory...\n' "$BUNDLE_VERSION"
    ssh "$DECK_HOST" "\
        if test -e '$REMOTE_STAGING'; then
            mv '$REMOTE_STAGING' '$REMOTE_STAGING.failed-\$(date +%Y%m%d-%H%M%S)'
        fi
        mkdir -p '$REMOTE_STAGING' '$REMOTE_PROJECT_ROOT/builds'"

    rsync -a "$LOCAL_BUNDLE/" "$DECK_HOST:$REMOTE_STAGING/"
    ssh "$DECK_HOST" "mv '$REMOTE_STAGING' '$REMOTE_BUILD'"
fi

printf 'Verifying the bundle against the real SteamOS host...\n'
ssh "$DECK_HOST" "\
    '$REMOTE_TOOLS/verify-private-bundle.sh' \
    '$REMOTE_BUILD'"

printf 'Activating bundle %s...\n' "$BUNDLE_VERSION"
ssh "$DECK_HOST" "\
    cd '$REMOTE_PROJECT_ROOT'
    ln -sfn 'builds/$BUNDLE_VERSION' current"

printf '\nPrivate bundle deployed and activated:\n'
printf '  %s:%s\n' "$DECK_HOST" "~/$REMOTE_BUILD"

