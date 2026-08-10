#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
ANDROID_HOME="$HOME/Android_Waydroid"
ANDROID_IMAGE="$ANDROID_HOME/waydroid.img"
WAYDROID_USER_STATE="$HOME/.local/share/waydroid"
WAYDROID_LEGACY_USER_STATE="$HOME/waydroid"
SHORTCUT_MANAGER="$PROJECT_ROOT/extras/icon.py"
READONLY_DISABLED=false
FULL_PROCESS_RESET=false
KEEP_ANDROID_STATE=false
RESET_ARTIFACT_STATE=false
PRESERVATION_ROOT=""
PRESENT_ANDROID_USER_STATE=()
ANDROID_STATE_FILES=()
PRESERVED_ANDROID_FILES=()
MANUAL_SHORTCUT_REMOVAL=false

if [[ ${1:-} == --full-process ]]; then
    FULL_PROCESS_RESET=true
elif [[ ${1:-} == --keep-android ]]; then
    KEEP_ANDROID_STATE=true
elif [[ ${1:-} == --reset-host-keep-android ]]; then
    KEEP_ANDROID_STATE=true
    RESET_ARTIFACT_STATE=true
elif [[ ${1:-} == --purge-android ]]; then
    :
elif [[ $# -ne 0 ]]; then
    printf 'usage: %s [--full-process | --keep-android | --reset-host-keep-android | --purge-android]\n' "$0" >&2
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

restore_android_files() {
    local index preserved_file destination_file

    [[ "$KEEP_ANDROID_STATE" == true ]] || return 0
    (( ${#PRESERVED_ANDROID_FILES[@]} > 0 )) || return 0

    for index in "${!PRESERVED_ANDROID_FILES[@]}"; do
        preserved_file=${PRESERVED_ANDROID_FILES[$index]}
        destination_file=${ANDROID_STATE_FILES[$index]}
        if [[ -e "$destination_file" || -L "$destination_file" ]]; then
            printf 'error: refusing to overwrite Android state while restoring it: %s\n' \
                "$destination_file" >&2
            printf 'Preserved Android state remains at: %s\n' "$preserved_file" >&2
            return 1
        fi
    done
    mkdir -p -- "$ANDROID_HOME"
    for index in "${!PRESERVED_ANDROID_FILES[@]}"; do
        preserved_file=${PRESERVED_ANDROID_FILES[$index]}
        destination_file=${ANDROID_STATE_FILES[$index]}
        sudo mv -- "$preserved_file" "$destination_file"
    done
    rmdir -- "$PRESERVATION_ROOT" 2> /dev/null || true
    PRESERVATION_ROOT=""
    PRESERVED_ANDROID_FILES=()
}

cleanup() {
    restore_android_files || true
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

if [[ "$KEEP_ANDROID_STATE" == true ]]; then
    if [[ ( -e "$ANDROID_IMAGE" || -L "$ANDROID_IMAGE" ) && \
        ( ! -f "$ANDROID_IMAGE" || -L "$ANDROID_IMAGE" ) ]]; then
        printf 'error: preservation requires a regular Android image: %s\n' \
            "$ANDROID_IMAGE" >&2
        exit 1
    fi
    shopt -s nullglob
    for android_state_file in \
        "$ANDROID_IMAGE" \
        "$ANDROID_HOME"/waydroid.img.pre-reinstall-* \
        "$ANDROID_HOME"/waydroid.img.failed-reinstall-*
    do
        if [[ -L "$android_state_file" ]]; then
            printf 'error: preservation refuses a symlinked Android state file: %s\n' \
                "$android_state_file" >&2
            exit 1
        fi
        if [[ -f "$android_state_file" ]]; then
            ANDROID_STATE_FILES+=("$android_state_file")
        fi
    done
    shopt -u nullglob
    if (( ${#ANDROID_STATE_FILES[@]} > 0 )); then
        preservation_candidate="$HOME/.local/state/steamos-waydroid-preserved-reset"
        if [[ -e "$preservation_candidate" ]]; then
            printf 'error: preservation staging path already exists: %s\n' \
                "$preservation_candidate" >&2
            printf 'Inspect or recover it before retrying this reset.\n' >&2
            exit 1
        fi
    fi
    for user_state_path in "$WAYDROID_USER_STATE" "$WAYDROID_LEGACY_USER_STATE"; do
        if [[ -e "$user_state_path" || -L "$user_state_path" ]]; then
            PRESENT_ANDROID_USER_STATE+=("$user_state_path")
        fi
    done
    cat <<'EOF'
This removes installed SteamOS host integration while preserving:
EOF
    if [[ -f "$ANDROID_IMAGE" ]]; then
        printf '  - %s\n' "$ANDROID_IMAGE"
    fi
    printf '  - %s (Android applications, settings and logins)\n' \
        "$WAYDROID_USER_STATE"
    printf '  - %s when present (legacy Android user state)\n' \
        "$WAYDROID_LEGACY_USER_STATE"
    cat <<'EOF'
  - this Git checkout

It removes Android launchers and per-user host integration, Waydroid packages,
and installer-owned system integration. Steam shortcuts are removed when Steam
is closed; otherwise they are left for safe manual removal. The next normal
installer run reuses the preserved Android state, applications and logins.
EOF
    if [[ "$RESET_ARTIFACT_STATE" == true ]]; then
        cat <<'EOF'
Clean host-reset mode also removes installed Cage/wlroots bundles, artifact
configuration, and compatibility reports so artifact setup is exercised again.
EOF
    else
        cat <<'EOF'
The verified target-built bundles and artifact configuration are retained.
EOF
    fi
else
    cat <<'EOF'
This permanently deletes this installer's Waydroid instance, including:
  - Android applications, settings and files
  - Waydroid packages and installer-owned system integration
  - Waydroid and nested-desktop Steam shortcuts and local artwork when Steam
    is closed; otherwise remove them manually afterward

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

expected_confirmation="DELETE ANDROID DATA"
if [[ "$FULL_PROCESS_RESET" == true ]]; then
    expected_confirmation="DELETE EVERYTHING"
elif [[ "$RESET_ARTIFACT_STATE" == true ]]; then
    expected_confirmation="RESET HOST KEEP ANDROID"
elif [[ "$KEEP_ANDROID_STATE" == true ]]; then
    expected_confirmation="UNINSTALL HOST KEEP ANDROID"
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

# Waydroid normally bind-mounts the host-side Android data directory below
# /var/lib/waydroid/data. Never let the later directory cleanup traverse that
# data if container shutdown left a nested mount behind.
if findmnt -rn -o TARGET | grep -Eq '^/var/lib/waydroid(/|$)'; then
    printf 'error: a Waydroid mount is still active below /var/lib/waydroid; reset stopped\n' >&2
    findmnt -R /var/lib/waydroid >&2 || true
    exit 1
fi

if [[ "$KEEP_ANDROID_STATE" == true && ${#ANDROID_STATE_FILES[@]} -gt 0 ]]; then
    for android_state_file in "${ANDROID_STATE_FILES[@]}"; do
        if sudo losetup -j "$android_state_file" | grep -q .; then
            printf 'error: Android state is still attached; preservation stopped: %s\n' \
                "$android_state_file" >&2
            exit 1
        fi
    done
    printf 'Moving Android image state aside during host cleanup...\n'
    PRESERVATION_ROOT="$HOME/.local/state/steamos-waydroid-preserved-reset"
    mkdir -p -- "$(dirname -- "$PRESERVATION_ROOT")"
    mkdir -m 0700 -- "$PRESERVATION_ROOT"
    for android_state_file in "${ANDROID_STATE_FILES[@]}"; do
        preserved_file="$PRESERVATION_ROOT/$(basename -- "$android_state_file")"
        sudo mv -- "$android_state_file" "$preserved_file"
        PRESERVED_ANDROID_FILES+=("$preserved_file")
    done
fi

if pgrep -x steam > /dev/null; then
    MANUAL_SHORTCUT_REMOVAL=true
    cat >&2 <<'EOF'
WARNING: Steam is running, so its shortcuts database will not be modified.
The Waydroid or Nested Desktop shortcut and artwork may remain after cleanup.
Remove any remaining entry manually from Steam in Gaming Mode.
EOF
else
    printf 'Removing Steam shortcuts and their local artwork...\n'
    shortcut_cleanup_failed=false
    python3 "$SHORTCUT_MANAGER" remove waydroid || shortcut_cleanup_failed=true
    python3 "$SHORTCUT_MANAGER" remove nested-desktop || shortcut_cleanup_failed=true
    if [[ "$shortcut_cleanup_failed" == true ]]; then
        MANUAL_SHORTCUT_REMOVAL=true
        cat >&2 <<'EOF'
WARNING: Steam shortcut cleanup was incomplete, but uninstall will continue.
Remove any remaining Waydroid or Nested Desktop entry manually from Steam.
EOF
    fi
fi

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

# Remove both the current prebuilt Binder package and the legacy DKMS package.
# The kernel module itself is named binder_linux. Older SteamOS targets with
# Binder built into the kernel do not install either of these packages.
binder_package_installed=false
for binder_package in steamos-waydroid-binder binder_linux-dkms; do
    if pacman -Qq "$binder_package" > /dev/null 2>&1; then
        binder_package_installed=true
        break
    fi
done

# Waydroid has already been stopped above, so unload our out-of-tree Binder
# module before removing its package. Do not touch the in-tree "binder" driver
# used by SteamOS kernels that provide Binder themselves.
if [[ "$binder_package_installed" == true ]] &&     lsmod | awk '$1 == "binder_linux" {found=1} END {exit !found}'; then
    printf 'Unloading the bundled Binder kernel module...
'
    if ! sudo modprobe -r binder_linux; then
        printf 'error: binder_linux is still in use; Binder package removal stopped
' >&2
        exit 1
    fi
fi

packages=()
for package in     waydroid     python-gbinder     libgbinder     libglibutil     steamos-waydroid-binder     binder_linux-dkms
do
    if pacman -Qq "$package" > /dev/null 2>&1; then
        packages+=("$package")
    fi
done

if (( ${#packages[@]} > 0 )); then
    sudo pacman -Rns --noconfirm "${packages[@]}"
fi

# Refresh the module dependency/index files after removing an out-of-tree
# Binder package so modprobe cannot resolve a stale binder_linux entry.
if [[ "$binder_package_installed" == true ]]; then
    printf 'Refreshing kernel module indexes...
'
    sudo depmod -a "$(uname -r)"
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

if [[ "$KEEP_ANDROID_STATE" == true ]]; then
    printf 'Removing per-user host integration while retaining Android user data...\n'
else
    printf 'Removing Android data and per-user integration...\n'
fi
sudo rm -f -- \
    "$HOME/Desktop/Waydroid-Toolbox" \
    "$HOME/Desktop/Waydroid-Updater" \
    "$HOME/.local/share/kio/servicemenus/open_as_root.desktop" \
    "$PROJECT_ROOT/extras/waydroid.img" \
    "$PROJECT_ROOT/logfile"
# Waydroid and its privileged helpers can leave root-owned files below these
# user directories. Keep the targets explicit, but remove them as root.
sudo rm -rf -- \
    "$ANDROID_HOME"
if [[ "$KEEP_ANDROID_STATE" != true ]]; then
    sudo rm -rf -- \
        "$WAYDROID_LEGACY_USER_STATE" \
        "$WAYDROID_USER_STATE"
    if [[ -d "$HOME/.local/share" ]]; then
        sudo find "$HOME/.local/share" -mindepth 1 -maxdepth 1 \
            \( -name 'waydroid.pre-reinstall-*' -o \
               -name 'waydroid.failed-reinstall-*' \) \
            -exec rm -rf -- {} +
    fi
    sudo find "$HOME" -mindepth 1 -maxdepth 1 \
        \( -name 'waydroid.pre-reinstall-*' -o \
           -name 'waydroid.failed-reinstall-*' \) \
        -exec rm -rf -- {} +
fi

applications="$HOME/.local/share/applications"
if [[ -d "$applications" ]]; then
    sudo find "$applications" -maxdepth 1 -type f -name 'waydroid*.desktop' -delete
fi

sudo steamos-readonly enable
READONLY_DISABLED=false

if [[ "$KEEP_ANDROID_STATE" == true ]]; then
    printf 'Restoring the preserved Android image...\n'
    restore_android_files

    for user_state_path in "${PRESENT_ANDROID_USER_STATE[@]}"; do
        if [[ ! -e "$user_state_path" && ! -L "$user_state_path" ]]; then
            printf 'error: preserved Android user state disappeared during reset: %s\n' \
                "$user_state_path" >&2
            exit 1
        fi
    done

    if [[ "$RESET_ARTIFACT_STATE" == true ]]; then
        printf 'Removing target-built bundles and machine-local artifact state...\n'
        sudo rm -rf -- \
            "$HOME/.local/opt/steamos-waydroid" \
            "$HOME/.local/share/steamos-waydroid-installer" \
            "$HOME/.local/state/steamos-waydroid"
        sudo rm -f -- "$PROJECT_ROOT/.deck-config.env"
    fi
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

Run the installer locally from Desktop Mode when you are ready to reinstall.
EOF

if [[ "$MANUAL_SHORTCUT_REMOVAL" == true ]]; then
    cat >&2 <<'EOF'

Reminder: shortcut cleanup was skipped or incomplete. Remove any remaining
Waydroid or Nested Desktop entry manually from Steam in Gaming Mode.
EOF
fi

if [[ "$FULL_PROCESS_RESET" == true ]]; then
    printf 'Clone the Git repository again, then pull and install the published bundle.\n'
elif [[ "$KEEP_ANDROID_STATE" == true ]]; then
    if [[ -f "$ANDROID_IMAGE" ]]; then
        printf 'Android image was preserved at: %s\n' "$ANDROID_IMAGE"
    else
        printf 'No Android image was present; existing host-side Android user data was retained.\n'
    fi
    printf 'Android applications, settings and logins were preserved at: %s\n' \
        "$WAYDROID_USER_STATE"
    if [[ "$RESET_ARTIFACT_STATE" == true ]]; then
        printf 'Configure artifacts, then run the normal installer to test first-time host setup.\n'
    else
        printf 'Run the normal installer from this checkout to restore host integration.\n'
    fi
else
    printf 'Android data was deleted. The Git checkout and verified target-built bundles were retained.\n'
fi
