#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# not needed
#SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

require_command() {
	local command_name="$1"

	command -v "$command_name" >/dev/null 2>&1 ||
		die "required command not found: $command_name"
}

fingerprint_value() {
	local key="$1"

	awk -F= -v wanted="$key" \
		'$1 == wanted {print substr($0, length($1) + 2); exit}' \
		"$BUNDLE_ROOT/target-fingerprint.env"
}

lock_value() {
	local key="$1"

	awk -F= -v wanted="$key" \
		'$1 == wanted {print substr($0, length($1) + 2); exit}' \
		"$WAYDROID_STACK_LOCK"
}

verify_host_package() {
	local package_name="$1"
	local version_key="$2"
	local pkgrel_key="$3"

	local expected_version
	local expected_pkgrel
	local expected_package_version
	local package_file
	local metadata_name
	local metadata_version
	local metadata_arch

	local matches=(
		"$BUNDLE_ROOT/packages/$package_name-"*.pkg.tar.zst
	)

	((${#matches[@]} == 1)) && [[ -f "${matches[0]}" ]] ||
		die "bundle must contain exactly one $package_name package"

	package_file="${matches[0]}"

	expected_version="$(lock_value "$version_key")"
	[[ -n "$expected_version" ]] ||
		die "Waydroid stack lock has no $version_key"

	expected_pkgrel="$(lock_value "$pkgrel_key")"
	[[ -n "$expected_pkgrel" ]] ||
		die "Waydroid stack lock has no $pkgrel_key"

	expected_package_version="${expected_version}-${expected_pkgrel}"

	metadata_name="$(
		bsdtar -xOf "$package_file" .PKGINFO |
			awk -F' = ' '$1 == "pkgname" {print $2; exit}'
	)"

	metadata_version="$(
		bsdtar -xOf "$package_file" .PKGINFO |
			awk -F' = ' '$1 == "pkgver" {print $2; exit}'
	)"

	metadata_arch="$(
		bsdtar -xOf "$package_file" .PKGINFO |
			awk -F' = ' '$1 == "arch" {print $2; exit}'
	)"

	[[ "$metadata_name" == "$package_name" ]] ||
		die "unexpected package metadata in $(basename -- "$package_file")"

	[[ "$metadata_version" == "$expected_package_version" ]] ||
		die "$package_name version $metadata_version does not match Waydroid stack lock $expected_package_version"

	[[ "$metadata_arch" == x86_64 || "$metadata_arch" == any ]] ||
		die "$package_name has unsupported architecture $metadata_arch"
}

verify_optional_binder_package() {
	local target_kernel_release="$1"
	local binder_package
	local binder_module_path
	local binder_verify_dir
	local binder_vermagic
	local metadata_name
	local metadata_arch

	local binder_packages=(
		"$BUNDLE_ROOT/packages/steamos-waydroid-binder-"*.pkg.tar.zst
	)

	if ((${#binder_packages[@]} == 0)); then
		printf 'Binder package: not bundled\n'
		return 0
	fi

	((${#binder_packages[@]} == 1)) ||
		die "bundle contains multiple steamos-waydroid-binder packages"

	binder_package="${binder_packages[0]}"

	metadata_name="$(
		bsdtar -xOf "$binder_package" .PKGINFO |
			awk -F' = ' '$1 == "pkgname" {print $2; exit}'
	)"

	metadata_arch="$(
		bsdtar -xOf "$binder_package" .PKGINFO |
			awk -F' = ' '$1 == "arch" {print $2; exit}'
	)"

	[[ "$metadata_name" == "steamos-waydroid-binder" ]] ||
		die "unexpected Binder package metadata in $(basename -- "$binder_package")"

	[[ "$metadata_arch" == x86_64 || "$metadata_arch" == any ]] ||
		die "steamos-waydroid-binder has unsupported architecture $metadata_arch"

	binder_module_path="$(
		bsdtar -tf "$binder_package" |
			grep -E "^usr/lib/modules/${target_kernel_release}/updates/steamos-waydroid/binder_linux\.ko$" |
			head -n1 || true
	)"

	[[ -n "$binder_module_path" ]] ||
		die "Binder package does not contain binder_linux.ko for target kernel $target_kernel_release"

	binder_verify_dir="$(mktemp -d)"
	trap 'rm -rf -- "$binder_verify_dir"' RETURN

	bsdtar -xf "$binder_package" \
		-C "$binder_verify_dir" \
		"$binder_module_path"

	[[ -f "$binder_verify_dir/$binder_module_path" ]] ||
		die "failed to extract Binder module from $(basename -- "$binder_package")"

	binder_vermagic="$(
		modinfo -F vermagic "$binder_verify_dir/$binder_module_path"
	)"

	[[ "$binder_vermagic" == "$target_kernel_release "* ]] ||
		die "Binder module vermagic does not match target kernel: $binder_vermagic"

	printf 'Binder package verified:\n'
	printf '  Package:  %s\n' "$(basename -- "$binder_package")"
	printf '  Module:   %s\n' "$binder_module_path"
	printf '  Vermagic: %s\n' "$binder_vermagic"

	rm -rf -- "$binder_verify_dir"
	trap - RETURN
}

[[ ${STEAMOS_WAYDROID_INTERNAL:-} == 1 ]] ||
	die "this is an internal helper; run ./steamos-waydroid-installer.sh"

for command_name in \
	awk \
	bsdtar \
	file \
	find \
	grep \
	ldd \
	mktemp \
	modinfo \
	readelf \
	realpath \
	rm; do
	require_command "$command_name"
done

BUNDLE_ROOT="${1:-}"
[[ -n "$BUNDLE_ROOT" ]] ||
	die "usage: $0 BUNDLE_DIRECTORY"

[[ -d "$BUNDLE_ROOT" ]] ||
	die "bundle directory does not exist: $BUNDLE_ROOT"

[[ -x "$BUNDLE_ROOT/bin/cage" ]] ||
	die "Cage executable is missing"

[[ -x "$BUNDLE_ROOT/bin/wlr-randr" ]] ||
	die "wlr-randr executable is missing"

[[ -r "$BUNDLE_ROOT/target-fingerprint.env" ]] ||
	die "bundle target fingerprint is missing"

[[ -x "$BUNDLE_ROOT/tools/check-bundle-target.sh" ]] ||
	die "bundle target checker is missing"

[[ -x "$BUNDLE_ROOT/tools/compatibility-report.sh" ]] ||
	die "bundle compatibility reporter is missing"

[[ -r "$BUNDLE_ROOT/tools/target-fingerprint.sh" ]] ||
	die "bundle target fingerprint helper is missing"

[[ -d "$BUNDLE_ROOT/packages" ]] ||
	die "bundle packages directory is missing"

# Package globs below should expand to zero entries when no optional package is
# present rather than remaining as an unexpanded literal pattern.
shopt -s nullglob

#
# Locate the selected Waydroid stack lock copied into the bundle.
#
# Preferred bundled name:
#   packages/waydroid-stack.lock
#
# Also accept one versioned waydroid-stack-*.lock file so builds which preserve
# the source lock filename remain verifiable.
#
if [[ -r "$BUNDLE_ROOT/packages/waydroid-stack.lock" ]]; then
	WAYDROID_STACK_LOCK="$BUNDLE_ROOT/packages/waydroid-stack.lock"
else
	waydroid_stack_locks=(
		"$BUNDLE_ROOT/packages/waydroid-stack-"*.lock
	)

	((${#waydroid_stack_locks[@]} == 1)) ||
		die "bundle must contain exactly one Waydroid stack lock"

	WAYDROID_STACK_LOCK="${waydroid_stack_locks[0]}"
fi

lock_format="$(lock_value format)"
[[ "$lock_format" == "1" ]] ||
	die "unsupported Waydroid stack lock format: ${lock_format:-missing}"

target_kernel_release="$(fingerprint_value KERNEL_RELEASE)"
[[ -n "$target_kernel_release" ]] ||
	die "bundle target fingerprint has no KERNEL_RELEASE"

[[ "$target_kernel_release" != "missing" && "$target_kernel_release" != "unknown" ]] ||
	die "bundle target fingerprint has unusable KERNEL_RELEASE: $target_kernel_release"

printf 'Verifying Waydroid stack:\n'
printf '  Lock: %s\n' "$(basename -- "$WAYDROID_STACK_LOCK")"

verify_host_package \
	libglibutil \
	libglibutil_version \
	libglibutil_pkgrel

verify_host_package \
	libgbinder \
	libgbinder_version \
	libgbinder_pkgrel

verify_host_package \
	python-gbinder \
	python_gbinder_version \
	python_gbinder_pkgrel

verify_host_package \
	waydroid \
	waydroid_version \
	waydroid_pkgrel

waydroid_package=(
	"$BUNDLE_ROOT/packages/waydroid-"*.pkg.tar.zst
)

for required_path in \
	usr/bin/waydroid \
	usr/lib/systemd/system/waydroid-container.service \
	usr/share/dbus-1/system.d/id.waydro.Container.conf \
	usr/share/polkit-1/actions/id.waydro.Container.policy; do

	bsdtar -tf "${waydroid_package[0]}" |
		grep -Fx "$required_path" >/dev/null ||
		die "Waydroid package is missing $required_path"
done

python_package=(
	"$BUNDLE_ROOT/packages/python-gbinder-"*.pkg.tar.zst
)

packaged_python_version="$(
	bsdtar -tf "${python_package[0]}" |
		awk -F/ \
			'$2 == "lib" && $3 ~ /^python[0-9]+\.[0-9]+$/ {
                sub(/^python/, "", $3)
                print $3
                exit
            }'
)"

target_python_package_version="$(fingerprint_value PKG_PYTHON)"

[[ -n "$target_python_package_version" ]] ||
	die "bundle target fingerprint has no PKG_PYTHON"

target_python_version="$(
	printf '%s\n' "$target_python_package_version" |
		sed -E 's/^([0-9]+\.[0-9]+).*/\1/'
)"

[[ -n "$target_python_version" ]] ||
	die "could not determine target Python version from PKG_PYTHON=$target_python_package_version"

[[ "$packaged_python_version" == "$target_python_version" ]] ||
	die "python-gbinder targets Python ${packaged_python_version:-unknown}, but target SteamOS uses Python $target_python_version"
#
# Binder is optional at bundle level because older SteamOS targets may provide
# Binder directly in their kernel. If a Binder package is present, however,
# verify that it contains a module for exactly the captured target kernel and
# that the module vermagic matches that kernel.
#
verify_optional_binder_package "$target_kernel_release"

mapfile -t wlroots_libraries < <(
	find "$BUNDLE_ROOT/lib" -maxdepth 1 \
		\( -type f -o -type l \) \
		-name 'libwlroots-*.so*' \
		-print
)

((${#wlroots_libraries[@]} > 0)) ||
	die "bundled wlroots is missing"

file "$BUNDLE_ROOT/bin/cage" |
	grep -F 'x86-64' >/dev/null ||
	die "Cage is not an x86-64 executable"

readelf -d "$BUNDLE_ROOT/bin/cage" |
	grep -F '$ORIGIN/../lib' >/dev/null ||
	die "Cage does not have the bundle-relative RUNPATH"

bundled_wlroots="${wlroots_libraries[0]}"

readelf -d "$bundled_wlroots" |
	grep -F 'libdisplay-info.so.3' >/dev/null ||
	die "bundled wlroots does not require libdisplay-info.so.3"

for forbidden_dependency in \
	libdisplay-info.so.2 \
	libliftoff.so \
	libvulkan.so; do

	if readelf -d "$bundled_wlroots" |
		grep -F "$forbidden_dependency" >/dev/null; then
		die "bundled wlroots has unwanted dependency: $forbidden_dependency"
	fi
done

if ldd "$BUNDLE_ROOT/bin/cage" |
	grep -F 'not found' >/dev/null; then

	ldd "$BUNDLE_ROOT/bin/cage" >&2
	die "Cage has unresolved runtime dependencies"
fi

resolved_wlroots="$(
	ldd "$BUNDLE_ROOT/bin/cage" |
		awk '/libwlroots-[0-9]+\.[0-9]+\.so/{print $3; exit}'
)"

[[ -n "$resolved_wlroots" ]] ||
	die "Cage did not report a resolved wlroots path"

resolved_wlroots="$(realpath -e -- "$resolved_wlroots")"
bundle_library_root="$(realpath -e -- "$BUNDLE_ROOT/lib")"

case "$resolved_wlroots" in
"$bundle_library_root"/*) ;;
*)
	die "Cage did not resolve wlroots from its bundle"
	;;
esac

if find "$BUNDLE_ROOT" -type f \
	\( \
	-name 'libdisplay-info.so*' \
	-o -name 'libwayland-*.so*' \
	-o -name 'libc.so*' \
	-o -name 'libEGL.so*' \
	-o -name 'libGLES*.so*' \
	-o -name 'libdrm.so*' \
	-o -name 'libinput.so*' \
	\) \
	-print -quit |
	grep -q .; then

	die "bundle contains a forbidden host system library"
fi

printf 'Bundle verification passed: %s\n' "$BUNDLE_ROOT"
