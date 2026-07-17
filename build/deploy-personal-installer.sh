#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_non_root
for command_name in git mktemp rsync ssh tar; do
    require_command "$command_name"
done

DECK_HOST="${DECK_HOST:-}"
[[ -n "$DECK_HOST" ]] || \
    die "set DECK_HOST in $BUILD_CONFIG_FILE (see build/config.example.env)"

git -C "$REPO_ROOT" diff --quiet || \
    die "tracked files have uncommitted changes; commit them before deployment"
git -C "$REPO_ROOT" diff --cached --quiet || \
    die "the Git index has uncommitted changes; commit them before deployment"

SOURCE_REVISION="$(git -C "$REPO_ROOT" rev-parse --short=12 HEAD)"
REMOTE_ROOT=".local/share/steamos-waydroid-installer"
REMOTE_BUILD="$REMOTE_ROOT/builds/$SOURCE_REVISION"
REMOTE_STAGING="$REMOTE_ROOT/.$SOURCE_REVISION.staging"
LOCAL_STAGING="$(mktemp -d)"

cleanup() {
    rm -rf -- "$LOCAL_STAGING"
}
trap cleanup EXIT HUP INT TERM

git -C "$REPO_ROOT" archive --format=tar HEAD | tar -xf - -C "$LOCAL_STAGING"
printf '%s\n' "$SOURCE_REVISION" > "$LOCAL_STAGING/.source-version"

printf 'Checking SSH access to %s...\n' "$DECK_HOST"
ssh "$DECK_HOST" 'test "$(id -un)" = deck'

if ssh "$DECK_HOST" "test -e '$REMOTE_BUILD'"; then
    printf 'Installer revision %s already exists; leaving it unchanged.\n' \
        "$SOURCE_REVISION"
else
    ssh "$DECK_HOST" "\
        if test -e '$REMOTE_STAGING'; then
            mv '$REMOTE_STAGING' '$REMOTE_STAGING.failed-\$(date +%Y%m%d-%H%M%S)'
        fi
        mkdir -p '$REMOTE_STAGING' '$REMOTE_ROOT/builds'"

    rsync -a "$LOCAL_STAGING/" "$DECK_HOST:$REMOTE_STAGING/"
    ssh "$DECK_HOST" "mv '$REMOTE_STAGING' '$REMOTE_BUILD'"
fi

ssh "$DECK_HOST" "\
    cd '$REMOTE_ROOT'
    ln -sfn 'builds/$SOURCE_REVISION' current
    cd
    ln -sfn '$REMOTE_ROOT/current' steamos-waydroid-personal-installer"

printf '\nPersonal installer deployed. In SteamOS Desktop Mode, open Konsole and run:\n\n'
printf '  cd ~/steamos-waydroid-personal-installer\n'
printf '  ./steamos-waydroid-installer.sh\n\n'
printf 'Do not launch the privileged installer over SSH.\n'

