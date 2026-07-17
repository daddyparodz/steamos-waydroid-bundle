#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_steamos_root

for command_name in git meson ninja patchelf readelf ldd; do
    require_command "$command_name"
done

SOURCE_ROOT="${SOURCE_ROOT:-/work/src}"
OUTPUT_ROOT="${OUTPUT_ROOT:-/work/out}"
PRIVATE_PREFIX="${PRIVATE_PREFIX:-/opt/steamos-waydroid-build}"
BUNDLE_ROOT="$OUTPUT_ROOT/$BUNDLE_VERSION"

WLROOTS_VERSION="0.18.2"
CAGE_VERSION="v0.2.0"
WLR_RANDR_VERSION="v0.5.0"

clone_at_tag() {
    local url="$1"
    local tag="$2"
    local destination="$3"

    if [[ ! -d "$destination/.git" ]]; then
        git clone --depth=1 --branch "$tag" "$url" "$destination"
    fi

    local current_commit expected_commit
    current_commit="$(git -C "$destination" rev-parse HEAD)"
    expected_commit="$(git -C "$destination" rev-list -n 1 "$tag")"
    [[ "$current_commit" == "$expected_commit" ]] || \
        die "$destination is not checked out at $tag"
}

setup_build_directory() {
    local source_directory="$1"
    shift

    if [[ -d "$source_directory/build-private" ]]; then
        meson setup --wipe "$source_directory/build-private" "$source_directory" "$@"
    else
        meson setup "$source_directory/build-private" "$source_directory" "$@"
    fi
}

mkdir -p "$SOURCE_ROOT" "$OUTPUT_ROOT"

clone_at_tag \
    https://gitlab.freedesktop.org/wlroots/wlroots.git \
    "$WLROOTS_VERSION" \
    "$SOURCE_ROOT/wlroots"
clone_at_tag \
    https://github.com/cage-kiosk/cage.git \
    "$CAGE_VERSION" \
    "$SOURCE_ROOT/cage"
clone_at_tag \
    https://gitlab.freedesktop.org/emersion/wlr-randr.git \
    "$WLR_RANDR_VERSION" \
    "$SOURCE_ROOT/wlr-randr"

printf 'Building wlroots %s...\n' "$WLROOTS_VERSION"
setup_build_directory "$SOURCE_ROOT/wlroots" \
    --prefix="$PRIVATE_PREFIX" \
    --libdir=lib \
    --buildtype=release \
    --wrap-mode=nofallback \
    -Dwerror=false \
    -Dexamples=false \
    -Dxwayland=disabled \
    -Drenderers=gles2 \
    -Dlibliftoff=disabled \
    -Dcolor-management=disabled
meson compile -C "$SOURCE_ROOT/wlroots/build-private"
meson install -C "$SOURCE_ROOT/wlroots/build-private"

WLROOTS_LIBRARY="$(find "$PRIVATE_PREFIX/lib" -maxdepth 1 \
    -type f -name 'libwlroots-0.18.so*' -print -quit)"
[[ -n "$WLROOTS_LIBRARY" ]] || die "private wlroots library was not installed"

readelf -d "$WLROOTS_LIBRARY" | grep -F 'libdisplay-info.so.3' >/dev/null || \
    die "private wlroots does not require libdisplay-info.so.3"
if readelf -d "$WLROOTS_LIBRARY" | grep -F 'libdisplay-info.so.2' >/dev/null; then
    die "private wlroots incorrectly requires libdisplay-info.so.2"
fi

export PKG_CONFIG_PATH="$PRIVATE_PREFIX/lib/pkgconfig"
export LD_LIBRARY_PATH="$PRIVATE_PREFIX/lib"

printf 'Building Cage %s...\n' "$CAGE_VERSION"
setup_build_directory "$SOURCE_ROOT/cage" \
    --prefix="$PRIVATE_PREFIX" \
    --libdir=lib \
    --buildtype=release \
    --wrap-mode=nofallback \
    -Dwerror=false
meson compile -C "$SOURCE_ROOT/cage/build-private"
meson install -C "$SOURCE_ROOT/cage/build-private"

printf 'Building wlr-randr %s...\n' "$WLR_RANDR_VERSION"
setup_build_directory "$SOURCE_ROOT/wlr-randr" \
    --prefix="$PRIVATE_PREFIX" \
    --libdir=lib \
    --buildtype=release \
    --wrap-mode=nofallback \
    -Dwerror=false
meson compile -C "$SOURCE_ROOT/wlr-randr/build-private"
meson install -C "$SOURCE_ROOT/wlr-randr/build-private"

if [[ -e "$BUNDLE_ROOT" ]]; then
    die "output already exists: $BUNDLE_ROOT (choose a new BUNDLE_VERSION)"
fi

install -d "$BUNDLE_ROOT/bin" "$BUNDLE_ROOT/lib" "$BUNDLE_ROOT/licenses"
install -m 0755 "$PRIVATE_PREFIX/bin/cage" "$BUNDLE_ROOT/bin/cage"
install -m 0755 "$PRIVATE_PREFIX/bin/wlr-randr" "$BUNDLE_ROOT/bin/wlr-randr"
cp -a "$PRIVATE_PREFIX"/lib/libwlroots-0.18.so* "$BUNDLE_ROOT/lib/"

patchelf --set-rpath '$ORIGIN/../lib' "$BUNDLE_ROOT/bin/cage"

cp "$SOURCE_ROOT/wlroots/LICENSE" "$BUNDLE_ROOT/licenses/wlroots.txt"
cp "$SOURCE_ROOT/cage/LICENSE" "$BUNDLE_ROOT/licenses/cage.txt"
cp "$SOURCE_ROOT/wlr-randr/LICENSE" "$BUNDLE_ROOT/licenses/wlr-randr.txt"

"$SCRIPT_DIR/verify-private-bundle.sh" "$BUNDLE_ROOT"

if [[ -n ${HOST_UID:-} && -n ${HOST_GID:-} ]]; then
    chown -R "$HOST_UID:$HOST_GID" "$BUNDLE_ROOT"
fi

printf '\nPrivate bundle created at:\n  %s\n' "$BUNDLE_ROOT"
