#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_non_root
require_command rsync
require_command ssh
require_command sudo

DECK_HOST="${DECK_HOST:-}"
[[ -n "$DECK_HOST" ]] || \
    die "set DECK_HOST in $BUILD_CONFIG_FILE (see build/config.example.env)"

SNAPSHOT_ROOT="$BUILD_WORK_ROOT/snapshot"
ROOTFS_ROOT="$BUILD_WORK_ROOT/rootfs"

mkdir -p \
    "$SNAPSHOT_ROOT/usr" \
    "$SNAPSHOT_ROOT/etc" \
    "$ROOTFS_ROOT"

printf 'Checking SSH access to %s...\n' "$DECK_HOST"
ssh "$DECK_HOST" 'test "$(id -un)" = deck'

printf 'Detecting the SteamOS pacman database path...\n'
PACMAN_DB_PATH="$(ssh "$DECK_HOST" 'pacman-conf DBPath' | head -n 1)"
PACMAN_DB_PATH="${PACMAN_DB_PATH%/}"
case "$PACMAN_DB_PATH" in
    /var/*|/usr/*) ;;
    *) die "Deck returned an unsafe or unsupported pacman DBPath: $PACMAN_DB_PATH" ;;
esac
if [[ "$PACMAN_DB_PATH" == *'/../'* || "$PACMAN_DB_PATH" == */.. ]]; then
    die "Deck returned an unsafe pacman DBPath: $PACMAN_DB_PATH"
fi
mkdir -p "$SNAPSHOT_ROOT$PACMAN_DB_PATH"
printf 'Pacman database: %s\n' "$PACMAN_DB_PATH"

printf 'Copying /usr from the Deck (read-only source)...\n'
rsync -aH --info=progress2 \
    --exclude='/bin/cupsd' \
    --exclude='/bin/groupmems' \
    --exclude='/bin/mount.nfs' \
    --exclude='/lib/dbus-daemon-launch-helper' \
    --exclude='/lib/cups/backend/cups-pdf' \
    --exclude='/lib/ssh/ssh-keysign' \
    --exclude='/share/ModemManager/' \
    --exclude='/share/factory/' \
    "$DECK_HOST:/usr/" \
    "$SNAPSHOT_ROOT/usr/"

printf 'Copying the pacman database from the Deck...\n'
rsync -aH --info=progress2 \
    "$DECK_HOST:$PACMAN_DB_PATH/" \
    "$SNAPSHOT_ROOT$PACMAN_DB_PATH/"

printf 'Copying only build-relevant system configuration from the Deck...\n'
rsync -aH --info=progress2 \
    --exclude='/pacman.d/gnupg/' \
    --include='/os-release' \
    --include='/arch-release' \
    --include='/passwd' \
    --include='/group' \
    --include='/nsswitch.conf' \
    --include='/hosts' \
    --include='/hostname' \
    --include='/resolv.conf' \
    --include='/localtime' \
    --include='/mtab' \
    --include='/pacman.conf' \
    --include='/pacman.d/***' \
    --include='/makepkg.conf' \
    --include='/makepkg.conf.d/***' \
    --include='/ld.so.conf' \
    --include='/ld.so.conf.d/***' \
    --include='/ssl/' \
    --include='/ssl/cert.pem' \
    --include='/ssl/certs/' \
    --include='/ssl/certs/ca-bundle.crt' \
    --include='/ssl/certs/ca-certificates.crt' \
    --include='/ssl/certs/java/' \
    --include='/ssl/certs/java/README' \
    --include='/ca-certificates/' \
    --include='/ca-certificates/***' \
    --exclude='*' \
    "$DECK_HOST:/etc/" \
    "$SNAPSHOT_ROOT/etc/"

printf 'Materialising the rootfs with root ownership on Fedora...\n'
sudo rsync -aH "$SNAPSHOT_ROOT/" "$ROOTFS_ROOT/"
sudo chown -R root:root "$ROOTFS_ROOT"

sudo install -d -m 0755 \
    "$ROOTFS_ROOT/dev" \
    "$ROOTFS_ROOT/proc" \
    "$ROOTFS_ROOT/sys" \
    "$ROOTFS_ROOT/run" \
    "$ROOTFS_ROOT/home" \
    "$ROOTFS_ROOT/root" \
    "$ROOTFS_ROOT/opt"
sudo install -d -m 1777 "$ROOTFS_ROOT/tmp"

sudo ln -sfn usr/bin "$ROOTFS_ROOT/bin"
sudo ln -sfn usr/bin "$ROOTFS_ROOT/sbin"
sudo ln -sfn usr/lib "$ROOTFS_ROOT/lib"
sudo ln -sfn usr/lib "$ROOTFS_ROOT/lib64"

printf '\nSteamOS build root created at:\n  %s\n' "$ROOTFS_ROOT"
printf 'The live Steam Deck was only read over SSH.\n'
