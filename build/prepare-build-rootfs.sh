#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_steamos_root
[[ $EUID -eq 0 ]] || die "run this script as root inside the copied SteamOS rootfs"

for command_name in pacman pacman-key update-ca-trust; do
    require_command "$command_name"
done

build_tool_packages=(
    base-devel git meson ninja patchelf scdoc wayland-protocols
)

development_payload_packages=(
    glibc linux-api-headers
    wayland libdisplay-info libdrm libxkbcommon pixman mesa libglvnd
    systemd-libs seatd libinput hwdata libxcb xcb-util-renderutil
    libffi libxau libxdmcp xorgproto
)

required_pkg_config_dependencies=(
    wayland-server libdrm xkbcommon pixman-1 egl gbm glesv2 hwdata
    libdisplay-info libudev libseat libinput
    xcb xcb-dri3 xcb-present xcb-render xcb-renderutil
    xcb-shm xcb-xfixes xcb-xinput
)

required_system_headers=(
    stdio.h stdint.h features.h sys/eventfd.h linux/dma-buf.h
)

printf 'Preparing the copied SteamOS rootfs for the private build.\n'
printf 'The live Steam Deck is not modified by this script.\n\n'

if [[ ! -s /etc/ssl/certs/ca-certificates.crt ]]; then
    printf 'Creating the local CA trust bundle...\n'
    install -d -m 0755 /etc/ssl/certs/java
    update-ca-trust
fi

if [[ ! -s /etc/pacman.d/gnupg/pubring.gpg ]]; then
    printf 'Initialising the copied rootfs package keyring...\n'
    pacman-key --init
    pacman-key --populate archlinux holo
fi

printf '\nChecking that development payload reinstalls will not change versions...\n'
version_mismatch=false
for package_name in "${development_payload_packages[@]}"; do
    installed_version="$(pacman -Q "$package_name" 2> /dev/null | awk '{print $2}' || true)"
    repository_version="$(LC_ALL=C pacman -Si "$package_name" 2> /dev/null | awk \
        '/^Version[[:space:]]*:/ {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}' || true)"
    if [[ -z "$installed_version" || -z "$repository_version" || \
        "$installed_version" != "$repository_version" ]]; then
        printf '  MISMATCH %-24s installed=%s repository=%s\n' \
            "$package_name" "${installed_version:-missing}" "${repository_version:-missing}" >&2
        version_mismatch=true
    else
        printf '  OK       %-24s %s\n' "$package_name" "$installed_version"
    fi
done

if [[ "$version_mismatch" == true ]]; then
    die "development packages no longer match the copied SteamOS target; do not upgrade this rootfs"
fi

printf '\nInstalling build-only tools. Review the transaction before accepting it.\n'
pacman -S --needed "${build_tool_packages[@]}"
require_command pkg-config

printf '\nRestoring headers and pkg-config metadata omitted from SteamOS.\n'
printf 'Review the transaction: it should reinstall the same versions.\n'
pacman -S "${development_payload_packages[@]}"

printf '\nVerifying build dependencies...\n'
verification_failed=false
for dependency in "${required_pkg_config_dependencies[@]}"; do
    if dependency_version="$(pkg-config --modversion "$dependency" 2> /dev/null)"; then
        printf '  OK      %-22s %s\n' "$dependency" "$dependency_version"
    else
        printf '  MISSING %s\n' "$dependency" >&2
        verification_failed=true
    fi
done

for header in "${required_system_headers[@]}"; do
    if [[ ! -r "/usr/include/$header" ]]; then
        printf '  MISSING /usr/include/%s\n' "$header" >&2
        verification_failed=true
    fi
done

[[ "$verification_failed" == false ]] || \
    die "copied rootfs preparation is incomplete; do not start the private build"

printf '\nRootfs preparation passed. Build with:\n'
printf '  /repo/build/build-private-bundle.sh\n'
