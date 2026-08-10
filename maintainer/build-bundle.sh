#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
DECK_RUNTIME_ROOT="$REPO_ROOT/libexec/steamos-waydroid"

enable_build_failure_report
set_build_report_stage preflight

require_copied_build_root

for command_name in git makepkg meson ninja patchelf pkg-config readelf ldd; do
	require_command "$command_name"
done

[[ -r "$TARGET_FINGERPRINT_FILE" ]] ||
	die "target fingerprint is missing: $TARGET_FINGERPRINT_FILE"
[[ ${BUNDLE_VERSION:-} =~ ^[A-Za-z0-9._-]+$ ]] ||
	die "unsafe or missing BUNDLE_VERSION"

required_system_headers=(
	stdio.h
	stdint.h
	features.h
	sys/eventfd.h
	linux/dma-buf.h
)

missing_system_headers=()
for header in "${required_system_headers[@]}"; do
	if [[ ! -r "/usr/include/$header" ]]; then
		missing_system_headers+=("$header")
	fi
done
if ((${#missing_system_headers[@]} > 0)); then
	printf 'Missing system headers in the minified SteamOS rootfs:\n' >&2
	printf '  %s\n' "${missing_system_headers[@]}" >&2
	die "reinstall the same glibc and linux-api-headers versions in the copied rootfs"
fi

required_pkg_config_dependencies=(
	glib-2.0
	gobject-2.0
	libpcre2-8
	sysprof-capture-4
	wayland-server
	libdrm
	xkbcommon
	pixman-1
	egl
	gbm
	glesv2
	hwdata
	libdisplay-info
	libudev
	libseat
	libinput
	xcb
	xcb-dri3
	xcb-present
	xcb-render
	xcb-renderutil
	xcb-shm
	xcb-xfixes
	xcb-xinput
)

missing_pkg_config_dependencies=()
for dependency in "${required_pkg_config_dependencies[@]}"; do
	if ! pkg-config --exists "$dependency"; then
		missing_pkg_config_dependencies+=("$dependency")
	fi
done
if ((${#missing_pkg_config_dependencies[@]} > 0)); then
	printf 'Missing development metadata in the minified SteamOS rootfs:\n' >&2
	printf '  %s\n' "${missing_pkg_config_dependencies[@]}" >&2
	printf 'pkg-config dependency details:\n' >&2
	for dependency in "${missing_pkg_config_dependencies[@]}"; do
		pkg-config --print-errors --exists "$dependency" 2>&1 || true
	done
	die "restore the development payloads described in maintainer/README.md"
fi

SOURCE_ROOT="${SOURCE_ROOT:-/work/src}"
OUTPUT_ROOT="${OUTPUT_ROOT:-/work/out}"
BUNDLE_PREFIX="${BUNDLE_PREFIX:-/opt/steamos-waydroid-build}"
BUNDLE_ROOT="$OUTPUT_ROOT/$BUNDLE_VERSION"
STAGING_ROOT="$OUTPUT_ROOT/.$BUNDLE_VERSION.staging"

# CAGE version is now supplied by common.sh
WLR_RANDR_VERSION="${WLR_RANDR_VERSION:-v0.5.0}"

clone_at_tag() {
	local url="$1"
	local tag="$2"
	local destination="$3"
	local current_commit expected_commit

	if [[ ! -d "$destination/.git" ]]; then
		git clone --depth=1 --branch "$tag" "$url" "$destination"
	else
		if ! git -C "$destination" rev-parse \
			--verify --quiet "refs/tags/$tag^{commit}" >/dev/null; then
			printf 'Fetching %s for %s...\n' "$tag" "$destination"
			git -C "$destination" fetch \
				--depth=1 \
				origin \
				"refs/tags/$tag:refs/tags/$tag"
		fi

		git -C "$destination" checkout --detach "$tag"
	fi

	current_commit="$(git -C "$destination" rev-parse HEAD)"
	expected_commit="$(git -C "$destination" rev-list -n 1 "$tag")"

	[[ "$current_commit" == "$expected_commit" ]] ||
		die "$destination is not checked out at $tag"
}

setup_build_directory() {
	local source_directory="$1"
	shift

	if [[ -d "$source_directory/build-bundle" ]]; then
		meson setup --wipe "$source_directory/build-bundle" "$source_directory" "$@"
	else
		meson setup "$source_directory/build-bundle" "$source_directory" "$@"
	fi
}

archive_incomplete_output() {
	local incomplete_path="$1"
	local archive_path

	[[ -e "$incomplete_path" ]] || return 0
	archive_path="$OUTPUT_ROOT/$(basename -- "$incomplete_path").failed-$(date +%Y%m%d-%H%M%S)"
	mv "$incomplete_path" "$archive_path"
	printf 'Archived incomplete output at %s\n' "$archive_path" >&2
}

mkdir -p "$SOURCE_ROOT" "$OUTPUT_ROOT"

set_build_report_stage host-packages
mkdir -p "$REPORT_ROOT"
HOST_PACKAGE_LOG="$REPORT_ROOT/$BUNDLE_VERSION-host-packages.log"
: >"$HOST_PACKAGE_LOG"
HOST_PACKAGE_LOG="$HOST_PACKAGE_LOG" \
	PACKAGE_OUTPUT_ROOT="$OUTPUT_ROOT/.host-packages-$BUNDLE_VERSION" \
	"$SCRIPT_DIR/build-host-packages.sh"

set_build_report_stage source-checkout
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

set_build_report_stage wlroots
printf 'Building wlroots %s...\n' "$WLROOTS_VERSION"
setup_build_directory "$SOURCE_ROOT/wlroots" \
	--prefix="$BUNDLE_PREFIX" \
	--libdir=lib \
	--buildtype=release \
	--wrap-mode=nofallback \
	-Dwerror=false \
	-Dexamples=false \
	-Dxwayland=disabled \
	-Dxcb-errors=disabled \
	-Drenderers=gles2 \
	-Dlibliftoff=disabled \
	-Dcolor-management=disabled
meson compile -C "$SOURCE_ROOT/wlroots/build-bundle"
meson install -C "$SOURCE_ROOT/wlroots/build-bundle"

WLROOTS_LIBRARY="$(find "$BUNDLE_PREFIX/lib" -maxdepth 1 \
	-type f -name "libwlroots-${WLROOTS_API_VERSION}.so*" -print -quit)"
[[ -n "$WLROOTS_LIBRARY" ]] || die "bundled wlroots library was not installed"

readelf -d "$WLROOTS_LIBRARY" | grep -F 'libdisplay-info.so.3' >/dev/null ||
	die "bundled wlroots does not require libdisplay-info.so.3"
if readelf -d "$WLROOTS_LIBRARY" | grep -F 'libdisplay-info.so.2' >/dev/null; then
	die "bundled wlroots incorrectly requires libdisplay-info.so.2"
fi

export PKG_CONFIG_PATH="$BUNDLE_PREFIX/lib/pkgconfig"
export LD_LIBRARY_PATH="$BUNDLE_PREFIX/lib"

set_build_report_stage cage
printf 'Building Cage %s...\n' "$CAGE_VERSION"
setup_build_directory "$SOURCE_ROOT/cage" \
	--prefix="$BUNDLE_PREFIX" \
	--libdir=lib \
	--buildtype=release \
	--wrap-mode=nofallback \
	-Dwerror=false
meson compile -C "$SOURCE_ROOT/cage/build-bundle"
meson install -C "$SOURCE_ROOT/cage/build-bundle"

set_build_report_stage wlr-randr
printf 'Building wlr-randr %s...\n' "$WLR_RANDR_VERSION"
setup_build_directory "$SOURCE_ROOT/wlr-randr" \
	--prefix="$BUNDLE_PREFIX" \
	--libdir=lib \
	--buildtype=release \
	--wrap-mode=nofallback \
	-Dwerror=false
meson compile -C "$SOURCE_ROOT/wlr-randr/build-bundle"
meson install -C "$SOURCE_ROOT/wlr-randr/build-bundle"

if [[ -e "$BUNDLE_ROOT" ]]; then
	if [[ -f "$BUNDLE_ROOT/.verified" ]]; then
		die "verified output already exists: $BUNDLE_ROOT (choose a new BUNDLE_VERSION)"
	fi
	archive_incomplete_output "$BUNDLE_ROOT"
fi
archive_incomplete_output "$STAGING_ROOT"

set_build_report_stage bundle-assembly
install -d \
	"$STAGING_ROOT/bin" \
	"$STAGING_ROOT/lib" \
	"$STAGING_ROOT/licenses" \
	"$STAGING_ROOT/packages" \
	"$STAGING_ROOT/tools"
install -m 0755 "$BUNDLE_PREFIX/bin/cage" "$STAGING_ROOT/bin/cage"
install -m 0755 "$BUNDLE_PREFIX/bin/wlr-randr" "$STAGING_ROOT/bin/wlr-randr"
cp -a "$BUNDLE_PREFIX/lib/libwlroots-${WLROOTS_API_VERSION}.so"* "$STAGING_ROOT/lib/"
cp -a "$OUTPUT_ROOT/.host-packages-$BUNDLE_VERSION"/. "$STAGING_ROOT/packages/"
install -m 0644 "$TARGET_FINGERPRINT_FILE" "$STAGING_ROOT/target-fingerprint.env"
install -m 0755 \
	"$DECK_RUNTIME_ROOT/check-bundle-target.sh" \
	"$STAGING_ROOT/tools/check-bundle-target.sh"
install -m 0755 \
	"$DECK_RUNTIME_ROOT/compatibility-report.sh" \
	"$STAGING_ROOT/tools/compatibility-report.sh"
install -m 0644 \
	"$DECK_RUNTIME_ROOT/lib/target-fingerprint.sh" \
	"$STAGING_ROOT/tools/target-fingerprint.sh"

patchelf --set-rpath '$ORIGIN/../lib' "$STAGING_ROOT/bin/cage"

cp "$SOURCE_ROOT/wlroots/LICENSE" "$STAGING_ROOT/licenses/wlroots.txt"
cp "$SOURCE_ROOT/cage/LICENSE" "$STAGING_ROOT/licenses/cage.txt"
cp "$SOURCE_ROOT/wlr-randr/LICENSE" "$STAGING_ROOT/licenses/wlr-randr.txt"

# Build-only lookup paths must not influence runtime verification. Cage must
# resolve wlroots through its relative RUNPATH from the staged bundle.
unset LD_LIBRARY_PATH PKG_CONFIG_PATH
set_build_report_stage bundle-verification
STEAMOS_WAYDROID_INTERNAL=1 \
	"$DECK_RUNTIME_ROOT/verify-bundle.sh" "$STAGING_ROOT"
"$DECK_RUNTIME_ROOT/check-bundle-target.sh" "$STAGING_ROOT"
printf 'verified\n' >"$STAGING_ROOT/.verified"
mv "$STAGING_ROOT" "$BUNDLE_ROOT"

if [[ -n ${HOST_UID:-} && -n ${HOST_GID:-} ]]; then
	chown -R "$HOST_UID:$HOST_GID" "$BUNDLE_ROOT"
fi

printf '\nTarget-built bundle created at:\n  %s\n' "$BUNDLE_ROOT"
