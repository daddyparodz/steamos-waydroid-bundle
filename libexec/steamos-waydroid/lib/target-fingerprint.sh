#!/usr/bin/env bash

# Shared SteamOS target fingerprint functions. This file may be executed over
# SSH before the repository exists on the Deck.

fingerprint_clean_value() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9@._+:-' '_'
}

fingerprint_package_version() {
    local package_name="$1"
    local version
    if version="$(pacman -Q "$package_name" 2> /dev/null | awk '{print $2}')"; then
        fingerprint_clean_value "$version"
    else
        printf 'missing'
    fi
}

fingerprint_value() {
    local fingerprint_file="$1"
    local key="$2"
    awk -F= -v wanted="$key" '$1 == wanted {sub(/^[^=]*=/, ""); print; exit}' \
        "$fingerprint_file"
}

collect_target_fingerprint() {
    local output_file="$1"
    local os_version build_id kernel_release
    local glibc glib2 python wayland display_info libdrm mesa libinput xkbcommon seatd
    local pixman libglvnd systemd_package hwdata libxcb xcb_renderutil
    local abi_payload abi_sha256 target_environment suggested

    # shellcheck source=/dev/null
    source "${TARGET_OS_RELEASE_FILE:-/etc/os-release}"
    [[ ${ID:-} == steamos ]] || {
        printf 'error: target fingerprint requires SteamOS\n' >&2
        return 1
    }

    os_version="$(fingerprint_clean_value "${VERSION_ID:-unknown}")"
    build_id="$(fingerprint_clean_value "${BUILD_ID:-unknown}")"
    kernel_release="$(fingerprint_clean_value "$(uname -r)")"
    glibc="$(fingerprint_package_version glibc)"
    glib2="$(fingerprint_package_version glib2)"
    python="$(fingerprint_package_version python)"
    wayland="$(fingerprint_package_version wayland)"
    display_info="$(fingerprint_package_version libdisplay-info)"
    libdrm="$(fingerprint_package_version libdrm)"
    pixman="$(fingerprint_package_version pixman)"
    mesa="$(fingerprint_package_version mesa)"
    libglvnd="$(fingerprint_package_version libglvnd)"
    systemd_package="$(fingerprint_package_version systemd)"
    libinput="$(fingerprint_package_version libinput)"
    xkbcommon="$(fingerprint_package_version libxkbcommon)"
    seatd="$(fingerprint_package_version seatd)"
    hwdata="$(fingerprint_package_version hwdata)"
    libxcb="$(fingerprint_package_version libxcb)"
    xcb_renderutil="$(fingerprint_package_version xcb-util-renderutil)"

    abi_payload="glibc=$glibc
glib2=$glib2
python=$python
wayland=$wayland
libdisplay_info=$display_info
libdrm=$libdrm
pixman=$pixman
mesa=$mesa
libglvnd=$libglvnd
systemd=$systemd_package
libinput=$libinput
libxkbcommon=$xkbcommon
seatd=$seatd
hwdata=$hwdata
libxcb=$libxcb
xcb_util_renderutil=$xcb_renderutil"
    abi_sha256="$(printf '%s\n' "$abi_payload" | sha256sum | awk '{print $1}')"
    target_environment="steamos-${os_version}-b${build_id}-abi${abi_sha256:0:12}"
    target_environment="$(fingerprint_clean_value "$target_environment")"
    suggested="steamos-${os_version}-b${build_id}-wlroots${WLROOTS_VERSION:-0.18.2}-${BUNDLE_REVISION:-r1}"
    suggested="$(fingerprint_clean_value "$suggested")"

    cat > "$output_file" <<EOF
FINGERPRINT_FORMAT=2
STEAMOS_VERSION_ID=$os_version
STEAMOS_BUILD_ID=$build_id
KERNEL_RELEASE=$kernel_release
PKG_GLIBC=$glibc
PKG_GLIB2=$glib2
PKG_PYTHON=$python
PKG_WAYLAND=$wayland
PKG_LIBDISPLAY_INFO=$display_info
PKG_LIBDRM=$libdrm
PKG_PIXMAN=$pixman
PKG_MESA=$mesa
PKG_LIBGLVND=$libglvnd
PKG_SYSTEMD=$systemd_package
PKG_LIBINPUT=$libinput
PKG_LIBXKBCOMMON=$xkbcommon
PKG_SEATD=$seatd
PKG_HWDATA=$hwdata
PKG_LIBXCB=$libxcb
PKG_XCB_UTIL_RENDERUTIL=$xcb_renderutil
ABI_SHA256=$abi_sha256
TARGET_ENVIRONMENT_ID=$target_environment
SUGGESTED_BUNDLE_VERSION=$suggested
EOF
}

if [[ ${BASH_SOURCE[0]:-} == "$0" || ${FINGERPRINT_RUN_MAIN:-} == 1 ]]; then
    set -Eeuo pipefail
    IFS=$'\n\t'
    [[ ${1:-} == collect ]] || {
        printf 'usage: %s collect\n' "$0" >&2
        exit 1
    }
    collect_target_fingerprint /dev/stdout
fi
