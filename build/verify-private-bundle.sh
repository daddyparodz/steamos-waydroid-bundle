#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

for command_name in find readelf ldd file realpath; do
    require_command "$command_name"
done

BUNDLE_ROOT="${1:-}"
[[ -n "$BUNDLE_ROOT" ]] || die "usage: $0 BUNDLE_DIRECTORY"
[[ -x "$BUNDLE_ROOT/bin/cage" ]] || die "Cage executable is missing"
[[ -x "$BUNDLE_ROOT/bin/wlr-randr" ]] || die "wlr-randr executable is missing"
[[ -r "$BUNDLE_ROOT/target-fingerprint.env" ]] || \
    die "bundle target fingerprint is missing"
[[ -x "$BUNDLE_ROOT/tools/check-bundle-target.sh" ]] || \
    die "bundle target checker is missing"
[[ -x "$BUNDLE_ROOT/tools/compatibility-report.sh" ]] || \
    die "bundle compatibility reporter is missing"
[[ -r "$BUNDLE_ROOT/tools/target-fingerprint.sh" ]] || \
    die "bundle target fingerprint helper is missing"

mapfile -t wlroots_libraries < <(
    find "$BUNDLE_ROOT/lib" -maxdepth 1 \
        \( -type f -o -type l \) -name 'libwlroots-0.18.so*' -print
)
(( ${#wlroots_libraries[@]} > 0 )) || die "private wlroots is missing"

file "$BUNDLE_ROOT/bin/cage" | grep -F 'x86-64' >/dev/null || \
    die "Cage is not an x86-64 executable"

readelf -d "$BUNDLE_ROOT/bin/cage" | \
    grep -F '$ORIGIN/../lib' >/dev/null || \
    die "Cage does not have the private relative RUNPATH"

private_wlroots="${wlroots_libraries[0]}"
readelf -d "$private_wlroots" | grep -F 'libdisplay-info.so.3' >/dev/null || \
    die "private wlroots does not require libdisplay-info.so.3"

for forbidden_dependency in \
    libdisplay-info.so.2 \
    libliftoff.so \
    libvulkan.so; do
    if readelf -d "$private_wlroots" | grep -F "$forbidden_dependency" >/dev/null; then
        die "private wlroots has unwanted dependency: $forbidden_dependency"
    fi
done

if ldd "$BUNDLE_ROOT/bin/cage" | grep -F 'not found' >/dev/null; then
    ldd "$BUNDLE_ROOT/bin/cage" >&2
    die "Cage has unresolved runtime dependencies"
fi

resolved_wlroots="$(ldd "$BUNDLE_ROOT/bin/cage" | \
    awk '/libwlroots-0.18/{print $3; exit}')"
[[ -n "$resolved_wlroots" ]] || die "Cage did not report a resolved wlroots path"
resolved_wlroots="$(realpath -e -- "$resolved_wlroots")"
bundle_library_root="$(realpath -e -- "$BUNDLE_ROOT/lib")"
case "$resolved_wlroots" in
    "$bundle_library_root"/*) ;;
    *) die "Cage did not resolve wlroots from its private bundle" ;;
esac

if find "$BUNDLE_ROOT" -type f \
    \( -name 'libdisplay-info.so*' \
       -o -name 'libwayland-*.so*' \
       -o -name 'libc.so*' \
       -o -name 'libEGL.so*' \
       -o -name 'libGLES*.so*' \
       -o -name 'libdrm.so*' \
       -o -name 'libinput.so*' \) \
    -print -quit | grep -q .; then
    die "bundle contains a forbidden host system library"
fi

printf 'Bundle verification passed: %s\n' "$BUNDLE_ROOT"
