#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/package-ownership.sh
source "$SCRIPT_DIR/lib/package-ownership.sh"
# shellcheck source=../libexec/steamos-waydroid/lib/target-fingerprint.sh
source "$REPO_ROOT/libexec/steamos-waydroid/lib/target-fingerprint.sh"
# shellcheck source=lib/kernel-support.sh
source "$SCRIPT_DIR/lib/kernel-support.sh"

require_copied_build_root

for command_name in pacman pacman-key update-ca-trust; do
	require_command "$command_name"
done

build_tool_packages=(
	base-devel git meson ninja patchelf scdoc wayland-protocols
	cython python-setuptools
)

development_payload_packages=(
	glibc linux-api-headers glib2 libsysprof-capture pcre2 python
	wayland libdisplay-info libdrm libxkbcommon pixman mesa libglvnd
	systemd-libs seatd libinput hwdata libxcb xcb-util-renderutil
	libffi libxau libxdmcp xorgproto
)

required_pkg_config_dependencies=(
	glib-2.0 gobject-2.0 libpcre2-8 sysprof-capture-4
	wayland-server libdrm xkbcommon pixman-1 egl gbm glesv2 hwdata
	libdisplay-info libudev libseat libinput
	xcb xcb-dri3 xcb-present xcb-render xcb-renderutil
	xcb-shm xcb-xfixes xcb-xinput
)

required_system_headers=(
	stdio.h stdint.h features.h sys/eventfd.h linux/dma-buf.h glib-2.0/glib.h
)

bundle_owned_packages=(
	libglibutil
	libgbinder
	python-gbinder
	waydroid
)

printf 'Preparing the copied SteamOS rootfs for the bundle build.\n'
printf 'The live Steam Deck is not modified by this script.\n\n'

require_bundle_owned_packages_absent "${bundle_owned_packages[@]}"

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
	installed_version="$(pacman -Q "$package_name" 2>/dev/null | awk '{print $2}' || true)"
	repository_version="$(LC_ALL=C pacman -Si "$package_name" 2>/dev/null | awk \
		'/^Version[[:space:]]*:/ {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}' || true)"
	if [[ -z "$installed_version" || -z "$repository_version" ||
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

printf '\nChecking target kernel Binder support...\n'

kernel_release="$(target_kernel_release)"
binder_state="$(target_binder_state "$kernel_release")"
kernel_headers_package=""

printf '  Kernel release: %s\n' "$kernel_release"
printf '  Binder support: %s\n' "$binder_state"

if [[ "$binder_state" == "missing" ]]; then
	kernel_headers_package="$(require_matching_target_kernel_headers)"

	printf '  Kernel package:  %s\n' "$(target_kernel_package)"
	printf '  Headers package: %s\n' "$kernel_headers_package"
fi

printf '\nInstalling build-only tools. Review the transaction before accepting it.\n'
if [[ -n "$kernel_headers_package" ]]; then
	printf '\nInstalling tools for binder module as well.\n'
	pacman -S --needed \
		"${build_tool_packages[@]}" \
		"$kernel_headers_package"
else
	pacman -S --needed "${build_tool_packages[@]}"
fi

if [[ "$binder_state" == "missing" ]]; then
	printf '\nVerifying target kernel build tree...\n'
	kernel_build_dir="$(require_target_kernel_build_tree "$kernel_release")"
	printf '  OK      %s\n' "$kernel_build_dir"
fi

require_command pkg-config

printf '\nRestoring headers and pkg-config metadata omitted from SteamOS.\n'
printf 'Review the transaction: it should reinstall the same versions.\n'
pacman -S "${development_payload_packages[@]}"

printf '\nVerifying build dependencies...\n'
verification_failed=false
for dependency in "${required_pkg_config_dependencies[@]}"; do
	if dependency_version="$(pkg-config --modversion "$dependency" 2>/dev/null)"; then
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

python_header="$(python -c 'import sysconfig; print(sysconfig.get_config_var("INCLUDEPY"))')/Python.h"
if [[ ! -r "$python_header" ]]; then
	printf '  MISSING %s\n' "$python_header" >&2
	verification_failed=true
fi
if ! python -c 'import Cython, setuptools' 2>/dev/null; then
	printf '  MISSING Python Cython or setuptools module\n' >&2
	verification_failed=true
fi

[[ "$verification_failed" == false ]] ||
	die "copied rootfs preparation is incomplete; do not start the bundle build"

printf '\nConfirming preparation did not change the captured target ABI...\n'
prepared_fingerprint="$(mktemp)"
cleanup() {
	rm -f -- "$prepared_fingerprint"
}
trap cleanup EXIT
collect_target_fingerprint "$prepared_fingerprint"
captured_target="$(fingerprint_value "$TARGET_FINGERPRINT_FILE" TARGET_ENVIRONMENT_ID)"
prepared_target="$(fingerprint_value "$prepared_fingerprint" TARGET_ENVIRONMENT_ID)"
[[ -n "$captured_target" && "$prepared_target" == "$captured_target" ]] ||
	die "build tools changed the target ABI; discard this rootfs and investigate the pacman transaction"

printf '\nRootfs preparation passed. Build with:\n'
printf '  /repo/maintainer/build-bundle.sh\n'
