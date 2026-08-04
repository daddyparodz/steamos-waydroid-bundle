#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

require_command() {
    local command_name="$1"
    command -v "$command_name" > /dev/null 2>&1 || \
        die "required command not found: $command_name"
}

[[ ${STEAMOS_WAYDROID_INTERNAL:-} == 1 ]] || \
    die "this is an internal helper; run ./steamos-waydroid-installer.sh"

for command_name in bsdtar find grep readelf ldd file python3 realpath; do
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
[[ -r "$BUNDLE_ROOT/packages/sources.lock" ]] || \
    die "host package source lock is missing"

lock_value() {
    local key="$1"
    awk -F= -v wanted="$key" '$1 == wanted {print $2; exit}' \
        "$BUNDLE_ROOT/packages/sources.lock"
}

verify_host_package() {
    local package_name="$1"
    local version_key="$2"
    local expected_version package_file metadata_name metadata_version metadata_arch
    local matches=("$BUNDLE_ROOT/packages/$package_name-"*.pkg.tar.zst)

    (( ${#matches[@]} == 1 )) && [[ -f "${matches[0]}" ]] || \
        die "bundle must contain exactly one $package_name package"
    package_file="${matches[0]}"
    expected_version="$(lock_value "$version_key")"
    [[ -n "$expected_version" ]] || die "source lock has no $version_key"
    metadata_name="$(bsdtar -xOf "$package_file" .PKGINFO | \
        awk -F' = ' '$1 == "pkgname" {print $2; exit}')"
    metadata_version="$(bsdtar -xOf "$package_file" .PKGINFO | \
        awk -F' = ' '$1 == "pkgver" {print $2; exit}')"
    metadata_arch="$(bsdtar -xOf "$package_file" .PKGINFO | \
        awk -F' = ' '$1 == "arch" {print $2; exit}')"
    [[ "$metadata_name" == "$package_name" ]] || \
        die "unexpected package metadata in $(basename -- "$package_file")"
    [[ "$metadata_version" == "$expected_version-"* ]] || \
        die "$package_name version $metadata_version does not match source lock $expected_version"
    [[ "$metadata_arch" == x86_64 || "$metadata_arch" == any ]] || \
        die "$package_name has unsupported architecture $metadata_arch"
}

verify_host_package libglibutil libglibutil_version
verify_host_package libgbinder libgbinder_version
verify_host_package python-gbinder python_gbinder_version
verify_host_package waydroid waydroid_version

waydroid_package=("$BUNDLE_ROOT/packages/waydroid-"*.pkg.tar.zst)
for required_path in \
    usr/bin/waydroid \
    usr/lib/systemd/system/waydroid-container.service \
    usr/share/dbus-1/system.d/id.waydro.Container.conf \
    usr/share/polkit-1/actions/id.waydro.Container.policy; do
    bsdtar -tf "${waydroid_package[0]}" | grep -Fx "$required_path" >/dev/null || \
        die "Waydroid package is missing $required_path"
done

python_package=("$BUNDLE_ROOT/packages/python-gbinder-"*.pkg.tar.zst)
packaged_python_version="$(bsdtar -tf "${python_package[0]}" | \
    awk -F/ '$2 == "lib" && $3 ~ /^python[0-9]+\.[0-9]+$/ {sub(/^python/, "", $3); print $3; exit}')"
host_python_version="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
[[ "$packaged_python_version" == "$host_python_version" ]] || \
    die "python-gbinder targets Python ${packaged_python_version:-unknown}, not $host_python_version"

mapfile -t wlroots_libraries < <(
    find "$BUNDLE_ROOT/lib" -maxdepth 1 \
        \( -type f -o -type l \) -name 'libwlroots-0.18.so*' -print
)
(( ${#wlroots_libraries[@]} > 0 )) || die "bundled wlroots is missing"

file "$BUNDLE_ROOT/bin/cage" | grep -F 'x86-64' >/dev/null || \
    die "Cage is not an x86-64 executable"

readelf -d "$BUNDLE_ROOT/bin/cage" | \
    grep -F '$ORIGIN/../lib' >/dev/null || \
    die "Cage does not have the bundle-relative RUNPATH"

bundled_wlroots="${wlroots_libraries[0]}"
readelf -d "$bundled_wlroots" | grep -F 'libdisplay-info.so.3' >/dev/null || \
    die "bundled wlroots does not require libdisplay-info.so.3"

for forbidden_dependency in \
    libdisplay-info.so.2 \
    libliftoff.so \
    libvulkan.so; do
    if readelf -d "$bundled_wlroots" | grep -F "$forbidden_dependency" >/dev/null; then
        die "bundled wlroots has unwanted dependency: $forbidden_dependency"
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
    *) die "Cage did not resolve wlroots from its bundle" ;;
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
