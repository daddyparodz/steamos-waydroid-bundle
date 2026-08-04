#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
ANDROID_HOME="$HOME/Android_Waydroid"
ANDROID_IMAGE="$ANDROID_HOME/waydroid.img"
SHORTCUT_MANAGER="$PROJECT_ROOT/extras/icon.py"
READONLY_DISABLED=false
FULL_PROCESS_RESET=false
KEEP_ANDROID_IMAGE=false
PRESERVED_IMAGE=""
PRESERVATION_ROOT=""

if [[ ${1:-} == --full-process ]]; then
    FULL_PROCESS_RESET=true
elif [[ ${1:-} == --keep-android ]]; then
    KEEP_ANDROID_IMAGE=true
elif [[ $# -ne 0 ]]; then
    printf 'usage: %s [--full-process | --keep-android]\n' "$0" >&2
    exit 1
fi

if [[ ${STEAMOS_WAYDROID_INTERNAL:-} != 1 ]]; then
    printf 'error: run ./steamos-waydroid-installer.sh with a supported reset option\n' >&2
    exit 1
fi

restore_readonly() {
    if [[ "$READONLY_DISABLED" == true ]]; then
        printf '\nRe-enabling the SteamOS read-only filesystem...\n'
        sudo steamos-readonly enable || true
    fi
}

restore_android_image() {
    [[ "$KEEP_ANDROID_IMAGE" == true ]] || return 0
    [[ -n "$PRESERVED_IMAGE" && -e "$PRESERVED_IMAGE" ]] || return 0

    if [[ -e "$ANDROID_IMAGE" ]]; then
        printf 'error: refusing to overwrite Android image while restoring it: %s\n' \
            "$ANDROID_IMAGE" >&2
        printf 'Preserved Android image remains at: %s\n' "$PRESERVED_IMAGE" >&2
        return 1
    fi

    mkdir -p -- "$ANDROID_HOME"
    sudo mv -- "$PRESERVED_IMAGE" "$ANDROID_IMAGE"
    rmdir -- "$PRESERVATION_ROOT" 2> /dev/null || true
    PRESERVED_IMAGE=""
    PRESERVATION_ROOT=""
}

cleanup() {
    restore_android_image || true
    restore_readonly
}
trap cleanup EXIT

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

if [[ "$KEEP_ANDROID_IMAGE" == true ]]; then
    if [[ ! -f "$ANDROID_IMAGE" || -L "$ANDROID_IMAGE" ]]; then
        printf 'error: preservation requires a regular Android image: %s\n' \
            "$ANDROID_IMAGE" >&2
        exit 1
    fi
    preservation_candidate="$HOME/.local/state/steamos-waydroid-preserved-reset"
    if [[ -e "$preservation_candidate" ]]; then
        printf 'error: preservation staging path already exists: %s\n' \
            "$preservation_candidate" >&2
        printf 'Inspect or recover it before retrying this reset.\n' >&2
        exit 1
    fi
    cat <<EOF
This resets all installer-owned SteamOS host state while preserving:
  - $ANDROID_IMAGE
  - this Git checkout

It removes Android launchers and per-user host integration, Waydroid packages,
private Cage/wlroots bundles, artifact configuration, and system integration.
The next normal installer run will exercise first-time host setup and reuse the
preserved Android state, applications and logins.
EOF
else
    cat <<'EOF'
This permanently deletes this installer's Waydroid instance, including:
  - Android applications, settings and files
  - Waydroid packages and installer-owned system integration
  - Waydroid and nested-desktop Steam shortcuts and local artwork

By default it intentionally keeps:
  - this Git checkout
  - ~/.local/opt/steamos-waydroid (the verified target-built bundles)

These retained prerequisites are required to run the installer again.
EOF
fi

if [[ "$FULL_PROCESS_RESET" == true ]]; then
    cat <<'EOF'

Full-process mode also deletes the Git checkout and target-built bundles so the
Deck-side clone, artifact pull, verification and activation can all be tested.
SSH keys and SSH host configuration are retained.
EOF
fi

expected_confirmation="DELETE WAYDROID"
if [[ "$FULL_PROCESS_RESET" == true ]]; then
    expected_confirmation="DELETE EVERYTHING"
elif [[ "$KEEP_ANDROID_IMAGE" == true ]]; then
    expected_confirmation="RESET HOST KEEP ANDROID"
fi
read -r -p "Type $expected_confirmation to continue: " confirmation
if [[ "$confirmation" != "$expected_confirmation" ]]; then
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

if [[ "$KEEP_ANDROID_IMAGE" == true ]]; then
    if findmnt --mountpoint /var/lib/waydroid > /dev/null 2>&1 || \
        sudo losetup -j "$ANDROID_IMAGE" | grep -q .; then
        printf 'error: Android image is still mounted or attached; preservation stopped\n' >&2
        exit 1
    fi
    printf 'Moving the Android image aside during host cleanup...\n'
    PRESERVATION_ROOT="$HOME/.local/state/steamos-waydroid-preserved-reset"
    mkdir -p -- "$(dirname -- "$PRESERVATION_ROOT")"
    mkdir -m 0700 -- "$PRESERVATION_ROOT"
    PRESERVED_IMAGE="$PRESERVATION_ROOT/waydroid.img"
    sudo mv -- "$ANDROID_IMAGE" "$PRESERVED_IMAGE"
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
sudo rm -f -- \
    "$HOME/Desktop/Waydroid-Toolbox" \
    "$HOME/Desktop/Waydroid-Updater" \
    "$HOME/.local/share/kio/servicemenus/open_as_root.desktop" \
    "$PROJECT_ROOT/extras/waydroid.img" \
    "$PROJECT_ROOT/logfile"
# Waydroid and its privileged helpers can leave root-owned files below these
# user directories. Keep the targets explicit, but remove them as root.
sudo rm -rf -- \
    "$ANDROID_HOME" \
    "$HOME/waydroid" \
    "$HOME/.local/share/waydroid"

applications="$HOME/.local/share/applications"
if [[ -d "$applications" ]]; then
    sudo find "$applications" -maxdepth 1 -type f -name 'waydroid*.desktop' -delete
fi

sudo steamos-readonly enable
READONLY_DISABLED=false

if [[ "$KEEP_ANDROID_IMAGE" == true ]]; then
    printf 'Restoring the preserved Android image...\n'
    restore_android_image

    printf 'Removing target-built bundles and machine-local artifact state...\n'
    sudo rm -rf -- \
        "$HOME/.local/opt/steamos-waydroid" \
        "$HOME/.local/share/steamos-waydroid-installer" \
        "$HOME/.local/state/steamos-waydroid"
    sudo rm -f -- "$PROJECT_ROOT/.deck-config.env"
fi

trap - EXIT

if [[ "$FULL_PROCESS_RESET" == true ]]; then
    printf 'Removing Deck-side bootstrap prerequisites...\n'
    sudo rm -rf -- \
        "$HOME/.local/opt/steamos-waydroid" \
        "$HOME/.local/share/steamos-waydroid-installer"
    case "$PROJECT_ROOT" in
        "$HOME"/*)
            if [[ -d "$PROJECT_ROOT/.git" && -f "$PROJECT_ROOT/steamos-waydroid-installer.sh" ]]; then
                sudo rm -rf -- "$PROJECT_ROOT"
            else
                printf 'Checkout retained because it could not be identified safely: %s\n' \
                    "$PROJECT_ROOT" >&2
            fi
            ;;
        *)
            printf 'Checkout retained because it is outside the deck home: %s\n' \
                "$PROJECT_ROOT" >&2
            ;;
    esac
fi

cat <<'EOF'

Reset complete.

Start Steam again before running the installer locally from Desktop Mode.
EOF

if [[ "$FULL_PROCESS_RESET" == true ]]; then
    printf 'Clone the Git repository again, then pull and install the published bundle.\n'
elif [[ "$KEEP_ANDROID_IMAGE" == true ]]; then
    printf 'Android state was preserved at: %s\n' "$ANDROID_IMAGE"
    printf 'Run the normal installer from this checkout to test first-time host setup.\n'
else
    printf 'The Git checkout and verified target-built bundles were retained.\n'
fi
