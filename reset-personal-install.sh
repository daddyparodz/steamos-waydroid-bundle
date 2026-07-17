#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ANDROID_HOME="$HOME/Android_Waydroid"
ANDROID_IMAGE="$ANDROID_HOME/waydroid.img"
SHORTCUT_MANAGER="$SCRIPT_DIR/extras/icon.py"
READONLY_DISABLED=false

restore_readonly() {
    if [[ "$READONLY_DISABLED" == true ]]; then
        printf '\nRe-enabling the SteamOS read-only filesystem...\n'
        sudo steamos-readonly enable || true
    fi
}
trap restore_readonly EXIT

if [[ "$(id -un)" != deck ]]; then
    printf 'error: run this script as the deck user, not as root\n' >&2
    exit 1
fi

if [[ ! -r /etc/os-release ]] || ! grep -q '^ID=steamos$' /etc/os-release; then
    printf 'error: this reset script may only be run on SteamOS\n' >&2
    exit 1
fi

if pgrep -x steam > /dev/null; then
    printf 'error: exit Steam completely before running this reset script\n' >&2
    printf 'Use Steam > Exit in Desktop Mode, then run it again from Konsole.\n' >&2
    exit 1
fi

cat <<'EOF'
This permanently deletes this installer's Waydroid instance, including:
  - Android applications, settings and files
  - Waydroid packages and installer-owned system integration
  - Waydroid and nested-desktop Steam shortcuts and local artwork

It intentionally keeps:
  - this Git checkout
  - ~/.local/opt/steamos-waydroid (the verified private Cage bundle)

These retained prerequisites are required to run the personal installer again.
EOF

read -r -p 'Type DELETE WAYDROID to continue: ' confirmation
if [[ "$confirmation" != "DELETE WAYDROID" ]]; then
    printf 'Reset cancelled.\n'
    exit 0
fi

sudo -v

printf 'Stopping Waydroid and detaching its private image...\n'
sudo systemctl stop waydroid-container.service 2> /dev/null || true
if findmnt --mountpoint /var/lib/waydroid > /dev/null 2>&1; then
    sudo umount /var/lib/waydroid
fi
if [[ -f "$ANDROID_IMAGE" ]]; then
    while IFS=: read -r loop_device _; do
        if [[ "$loop_device" == /dev/loop* ]]; then
            sudo losetup -d "$loop_device"
        fi
    done < <(sudo losetup -j "$ANDROID_IMAGE")
fi

printf 'Removing Steam shortcuts and their local artwork...\n'
python3 "$SHORTCUT_MANAGER" remove waydroid
python3 "$SHORTCUT_MANAGER" remove nested-desktop

printf 'Removing the firewall rules added by the installer...\n'
sudo systemctl start firewalld.service 2> /dev/null || true
sudo firewall-cmd --zone=trusted --remove-interface=waydroid0 > /dev/null 2>&1 || true
sudo firewall-cmd --zone=trusted --remove-port=53/udp > /dev/null 2>&1 || true
sudo firewall-cmd --zone=trusted --remove-port=67/udp > /dev/null 2>&1 || true
sudo firewall-cmd --zone=trusted --remove-forward > /dev/null 2>&1 || true
sudo firewall-cmd --runtime-to-permanent > /dev/null 2>&1 || true
sudo systemctl stop firewalld.service 2> /dev/null || true

printf 'Unlocking SteamOS for package and system-file cleanup...\n'
sudo steamos-readonly disable
READONLY_DISABLED=true

packages=()
for package in waydroid python-gbinder libgbinder libglibutil binder_linux-dkms; do
    if pacman -Qq "$package" > /dev/null 2>&1; then
        packages+=("$package")
    fi
done
if (( ${#packages[@]} > 0 )); then
    sudo pacman -Rns --noconfirm "${packages[@]}"
fi

sudo rm -f -- \
    /etc/sudoers.d/zzzzzzzz-waydroid \
    /etc/modules-load.d/waydroid.conf \
    /etc/modules-load.d/waydroid_binder.conf \
    /etc/modprobe.d/waydroid_binder.conf \
    /usr/bin/waydroid-startup-scripts \
    /usr/bin/waydroid-shutdown-scripts \
    /usr/bin/waydroid-mount \
    /usr/bin/waydroid-firewall
sudo rm -rf -- /var/lib/waydroid /usr/lib/waydroid /etc/waydroid-extra

printf 'Removing Android data and per-user integration...\n'
rm -f -- \
    "$HOME/Desktop/Waydroid-Toolbox" \
    "$HOME/Desktop/Waydroid-Updater" \
    "$HOME/.local/share/kio/servicemenus/open_as_root.desktop" \
    "$SCRIPT_DIR/extras/waydroid.img" \
    "$SCRIPT_DIR/logfile"
rm -rf -- \
    "$ANDROID_HOME" \
    "$HOME/waydroid" \
    "$HOME/.local/share/waydroid"

applications="$HOME/.local/share/applications"
if [[ -d "$applications" ]]; then
    find "$applications" -maxdepth 1 -type f -name 'waydroid*.desktop' -delete
fi

sudo steamos-readonly enable
READONLY_DISABLED=false
trap - EXIT

cat <<'EOF'

Reset complete.

The Git checkout and verified private Cage bundle were retained. Start Steam
again, then run steamos-waydroid-installer.sh locally from Desktop Mode to test
the same path as a new personal installation.
EOF
