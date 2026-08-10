#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

if [[ -n ${HOST_PACKAGE_LOG:-} ]]; then
    mkdir -p "$(dirname -- "$HOST_PACKAGE_LOG")"
    exec > >(tee -a "$HOST_PACKAGE_LOG") 2>&1
fi

require_copied_build_root

for command_name in bsdtar cython getent grep groupadd make makepkg pacman patch pkg-config python readelf setpriv tee useradd; do
    require_command "$command_name"
done

[[ -n ${HOST_UID:-} && -n ${HOST_GID:-} ]] || \
    die "HOST_UID and HOST_GID were not passed by enter-build-rootfs.sh"
[[ ${BUNDLE_VERSION:-} =~ ^[A-Za-z0-9._-]+$ ]] || \
    die "unsafe or missing BUNDLE_VERSION"

BUILDER_USER="$(getent passwd "$HOST_UID" 2> /dev/null | cut -d: -f1 || true)"
if [[ -z "$BUILDER_USER" ]]; then
    BUILDER_USER=steamos-waydroid-build
    if getent passwd "$BUILDER_USER" >/dev/null; then
        die "$BUILDER_USER exists with an unexpected UID"
    fi
    BUILDER_GROUP="$(getent group "$HOST_GID" 2> /dev/null | cut -d: -f1 || true)"
    if [[ -z "$BUILDER_GROUP" ]]; then
        BUILDER_GROUP=steamos-waydroid-build
        groupadd --gid "$HOST_GID" "$BUILDER_GROUP"
    fi
    useradd --uid "$HOST_UID" --gid "$BUILDER_GROUP" --no-create-home \
        --home-dir /work/src --shell /usr/bin/nologin "$BUILDER_USER"
fi
[[ "$BUILDER_USER" != root ]] || die "host UID must not resolve to root"
python -c 'import Cython, setuptools' || \
    die "Cython and setuptools must be installed in the copied rootfs"
python_header="$(python -c 'import sysconfig; print(sysconfig.get_config_var("INCLUDEPY"))')/Python.h"
[[ -r "$python_header" ]] || die "target Python header is missing: $python_header"

PACKAGE_RECIPE_ROOT="$SCRIPT_DIR/packages"
SOURCE_CACHE="${SOURCE_ROOT:-/work/src}/host-package-sources"
PACKAGE_WORK_ROOT="${SOURCE_ROOT:-/work/src}/host-package-work/$BUNDLE_VERSION"
PACKAGE_OUTPUT_ROOT="${PACKAGE_OUTPUT_ROOT:-/work/out/.host-packages-$BUNDLE_VERSION}"

# use waydroid 1.5.4 as tested default
WAYDROID_STACK_LOCK="${WAYDROID_STACK_LOCK:-maintainer/packages/locks/waydroid-stack-1.5.4.lock}"

if [[ "$WAYDROID_STACK_LOCK" = /* ]]; then
    WAYDROID_STACK_LOCK_PATH="$WAYDROID_STACK_LOCK"
else
    WAYDROID_STACK_LOCK_PATH="$REPO_ROOT/$WAYDROID_STACK_LOCK"
fi

[[ -r "$WAYDROID_STACK_LOCK_PATH" ]] || \
    die "Waydroid stack lock is missing: $WAYDROID_STACK_LOCK_PATH"

# shellcheck disable=SC1090
source "$WAYDROID_STACK_LOCK_PATH"

[[ "${format:-}" == "1" ]] || \
    die "unsupported Waydroid stack lock format: ${format:-missing}"

for required_var in \
    libglibutil_version \
    libglibutil_pkgrel \
    libglibutil_sha256 \
    libgbinder_version \
    libgbinder_pkgrel \
    libgbinder_sha256 \
    python_gbinder_version \
    python_gbinder_pkgrel \
    python_gbinder_sha256 \
    waydroid_version \
    waydroid_pkgrel \
    waydroid_sha256
do
    [[ -n "${!required_var:-}" ]] || \
        die "Waydroid stack lock is missing $required_var"
done

# check all pkgrel values are positive integers
for pkgrel_var in \
    libglibutil_pkgrel \
    libgbinder_pkgrel \
    python_gbinder_pkgrel \
    waydroid_pkgrel
do
    [[ "${!pkgrel_var}" =~ ^[1-9][0-9]*$ ]] || \
        die "invalid $pkgrel_var in Waydroid stack lock: ${!pkgrel_var}"
done

# check if patch files are given for libgbinder
if [[ -n "${libgbinder_patch:-}" ]]; then
    [[ -n "${libgbinder_patch_sha256:-}" ]] || \
        die "Waydroid stack selects libgbinder patch '$libgbinder_patch' but has no libgbinder_patch_sha256"

    [[ -r "$PACKAGE_RECIPE_ROOT/libgbinder/$libgbinder_patch" ]] || \
        die "selected libgbinder patch is missing: $PACKAGE_RECIPE_ROOT/libgbinder/$libgbinder_patch"
elif [[ -n "${libgbinder_patch_sha256:-}" ]]; then
    die "Waydroid stack defines libgbinder_patch_sha256 without libgbinder_patch"
fi

printf 'Using Waydroid stack lock:\n  %s\n' "$WAYDROID_STACK_LOCK_PATH"
printf '  Waydroid:       %s-%s\n' "$waydroid_version" "$waydroid_pkgrel"
printf '  libglibutil:    %s-%s\n' "$libglibutil_version" "$libglibutil_pkgrel"
printf '  libgbinder:     %s-%s\n' "$libgbinder_version" "$libgbinder_pkgrel"
printf '  python-gbinder: %s-%s\n' "$python_gbinder_version" "$python_gbinder_pkgrel"

rm -rf -- "$PACKAGE_WORK_ROOT" "$PACKAGE_OUTPUT_ROOT"
install -d -o "$HOST_UID" -g "$HOST_GID" \
    "$SOURCE_CACHE" "$PACKAGE_WORK_ROOT" "$PACKAGE_OUTPUT_ROOT"

build_package() {
    local package_name="$1"
    local recipe_source="$PACKAGE_RECIPE_ROOT/$package_name"
    local package_work="$PACKAGE_WORK_ROOT/$package_name"

    [[ -r "$recipe_source/PKGBUILD" ]] || \
        die "missing PKGBUILD for $package_name"
    install -d -o "$HOST_UID" -g "$HOST_GID" "$package_work"
    cp -a "$recipe_source"/. "$package_work"/
    chown -R "$HOST_UID:$HOST_GID" "$package_work"

    printf 'Building host package %s...\n' "$package_name"
    (
        cd "$package_work"
        setpriv --reuid="$HOST_UID" --regid="$HOST_GID" --clear-groups \
            env \
            HOME="$PACKAGE_WORK_ROOT" \
            USER="$BUILDER_USER" \
            LOGNAME="$BUILDER_USER" \
            SRCDEST="$SOURCE_CACHE" \
            PKGDEST="$PACKAGE_OUTPUT_ROOT" \
            BUILDDIR="$package_work/build" \
            WAYDROID_LIBGLIBUTIL_VERSION="$libglibutil_version" \
            WAYDROID_LIBGLIBUTIL_PKGREL="$libglibutil_pkgrel" \
            WAYDROID_LIBGLIBUTIL_SHA256="$libglibutil_sha256" \
            WAYDROID_LIBGBINDER_VERSION="$libgbinder_version" \
            WAYDROID_LIBGBINDER_PKGREL="$libgbinder_pkgrel" \
            WAYDROID_LIBGBINDER_SHA256="$libgbinder_sha256" \
            WAYDROID_LIBGBINDER_PATCH="${libgbinder_patch:-}" \
            WAYDROID_LIBGBINDER_PATCH_SHA256="${libgbinder_patch_sha256:-}" \
            WAYDROID_PYTHON_GBINDER_VERSION="$python_gbinder_version" \
            WAYDROID_PYTHON_GBINDER_PKGREL="$python_gbinder_pkgrel" \
            WAYDROID_PYTHON_GBINDER_SHA256="$python_gbinder_sha256" \
            WAYDROID_VERSION="$waydroid_version" \
            WAYDROID_PKGREL="$waydroid_pkgrel" \
            WAYDROID_SHA256="$waydroid_sha256" \
            makepkg --cleanbuild --clean --force --nodeps --noconfirm
    )
}

install_built_package() {
    local package_name="$1"
    local matches=("$PACKAGE_OUTPUT_ROOT/$package_name-"*.pkg.tar.zst)
    (( ${#matches[@]} == 1 )) && [[ -f "${matches[0]}" ]] || \
        die "expected exactly one built package for $package_name"
    pacman -U --noconfirm "${matches[0]}"
}

build_package libglibutil
install_built_package libglibutil
pkg-config --exists libglibutil || die "built libglibutil development metadata is unusable"

build_package libgbinder
install_built_package libgbinder
pkg-config --exists libgbinder || die "built libgbinder development metadata is unusable"

build_package python-gbinder
install_built_package python-gbinder
python -c 'import gbinder' || die "built python-gbinder cannot be imported"

build_package waydroid

for package_name in libglibutil libgbinder python-gbinder waydroid; do
    package_matches=("$PACKAGE_OUTPUT_ROOT/$package_name-"*.pkg.tar.zst)
    (( ${#package_matches[@]} == 1 )) && [[ -f "${package_matches[0]}" ]] || \
        die "host package set is incomplete for $package_name"
    metadata_name="$(bsdtar -xOf "${package_matches[0]}" .PKGINFO | \
        awk -F' = ' '$1 == "pkgname" {print $2; exit}')"
    [[ "$metadata_name" == "$package_name" ]] || \
        die "package metadata mismatch for $package_name"
    # check verions match
    metadata_version="$(
    bsdtar -xOf "${package_matches[0]}" .PKGINFO |
        awk -F' = ' '$1 == "pkgver" {print $2; exit}'
    )"
    case "$package_name" in
        libglibutil)
            expected_version="${libglibutil_version}-${libglibutil_pkgrel}"
            ;;
        libgbinder)
            expected_version="${libgbinder_version}-${libgbinder_pkgrel}"
            ;;
        python-gbinder)
            expected_version="${python_gbinder_version}-${python_gbinder_pkgrel}"
            ;;
        waydroid)
            expected_version="${waydroid_version}-${waydroid_pkgrel}"
            ;;
    esac

    [[ "$metadata_version" == "$expected_version" ]] || \
        die "package version mismatch for $package_name: expected $expected_version, got $metadata_version"
    
done

waydroid_package=("$PACKAGE_OUTPUT_ROOT/waydroid-"*.pkg.tar.zst)
for required_path in \
    usr/bin/waydroid \
    usr/lib/systemd/system/waydroid-container.service \
    usr/share/dbus-1/system.d/id.waydro.Container.conf \
    usr/share/polkit-1/actions/id.waydro.Container.policy; do
    bsdtar -tf "${waydroid_package[0]}" | grep -Fx "$required_path" >/dev/null || \
        die "Waydroid package is missing $required_path"
done

libgbinder_package=("$PACKAGE_OUTPUT_ROOT/libgbinder-"*.pkg.tar.zst)
libgbinder_library="$(bsdtar -tf "${libgbinder_package[0]}" | \
    awk '/^usr\/lib\/libgbinder\.so\.1\.[0-9]+\.[0-9]+$/ {print; exit}')"
[[ -n "$libgbinder_library" ]] || die "libgbinder package has no versioned shared library"

python_package=("$PACKAGE_OUTPUT_ROOT/python-gbinder-"*.pkg.tar.zst)
packaged_python_version="$(bsdtar -tf "${python_package[0]}" | \
    awk -F/ '$2 == "lib" && $3 ~ /^python[0-9]+\.[0-9]+$/ {sub(/^python/, "", $3); print $3; exit}')"
host_python_version="$(python -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
[[ "$packaged_python_version" == "$host_python_version" ]] || \
    die "python-gbinder targets Python $packaged_python_version, not $host_python_version"

install -m 0644 "$WAYDROID_STACK_LOCK_PATH" \
    "$PACKAGE_OUTPUT_ROOT/waydroid-stack.lock"
chown -R "$HOST_UID:$HOST_GID" "$PACKAGE_OUTPUT_ROOT"

printf '\nVerified host packages created at:\n  %s\n' "$PACKAGE_OUTPUT_ROOT"
