#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=waydroid-profile.sh
source "$SCRIPT_DIR/waydroid-profile.sh"
# shellcheck source=installer-functions.sh
source "$SCRIPT_DIR/installer-functions.sh"

path_has_symlink_component() {
	local path=$1 component current=$TEST_USER_HOME
	local relative=${path#"$TEST_USER_HOME"/}
	local -a components

	[[ "$relative" != "$path" ]] || return 0
	IFS=/ read -r -a components <<<"$relative"
	for component in "${components[@]}"; do
		current="$current/$component"
		[[ ! -L "$current" ]] || return 0
	done
	return 1
}

validate_test_removal_paths() {
	local main_image main_xdg main_state

	TEST_USER_HOME="$(waydroid_user_home)" || return
	[[ "$TEST_USER_HOME" == /* && "$TEST_USER_HOME" != / &&
		"$TEST_USER_HOME" != /root && ! -L "$TEST_USER_HOME" ]] || {
		printf 'error: unsafe Waydroid user home: %s\n' "${TEST_USER_HOME:-missing}" >&2
		return 1
	}

	resolve_waydroid_profile test || return
	TEST_IMAGE=$WAYDROID_IMAGE
	TEST_IMAGE_ROOT=${WAYDROID_IMAGE%/*}
	TEST_XDG_ROOT=$WAYDROID_XDG_DATA_HOME
	TEST_USER_STATE=$WAYDROID_USER_STATE

	resolve_waydroid_profile main || return
	main_image=$WAYDROID_IMAGE
	main_xdg=$WAYDROID_XDG_DATA_HOME
	main_state=$WAYDROID_USER_STATE
	resolve_waydroid_profile test || return

	[[ "$TEST_IMAGE" == "${main_image%/*}/test/waydroid.img" &&
		"$TEST_IMAGE_ROOT" == "${main_image%/*}/test" &&
		"$TEST_XDG_ROOT" == "$main_xdg/waydroid-test" &&
		"$TEST_USER_STATE" == "$TEST_XDG_ROOT/waydroid" &&
		"$TEST_IMAGE_ROOT" != "${main_image%/*}" &&
		"$TEST_XDG_ROOT" != "$main_xdg" &&
		"$TEST_XDG_ROOT" != "$main_state" ]] || {
		printf 'error: refusing unexpected Waydroid Test profile paths\n' >&2
		return 1
	}

	if path_has_symlink_component "$TEST_IMAGE_ROOT" ||
		path_has_symlink_component "$TEST_XDG_ROOT"; then
		printf 'error: refusing a Waydroid Test path containing a symbolic link\n' >&2
		return 1
	fi
	if [[ (-e "$TEST_IMAGE_ROOT" || -L "$TEST_IMAGE_ROOT") &&
		(! -d "$TEST_IMAGE_ROOT" || -L "$TEST_IMAGE_ROOT") ]]; then
		printf 'error: Waydroid Test image state is not a real directory: %s\n' \
			"$TEST_IMAGE_ROOT" >&2
		return 1
	fi
	if [[ (-e "$TEST_XDG_ROOT" || -L "$TEST_XDG_ROOT") &&
		(! -d "$TEST_XDG_ROOT" || -L "$TEST_XDG_ROOT") ]]; then
		printf 'error: Waydroid Test user state is not a real directory: %s\n' \
			"$TEST_XDG_ROOT" >&2
		return 1
	fi
	if [[ -L "$TEST_IMAGE" ]]; then
		printf 'error: Waydroid Test image is a symbolic link: %s\n' "$TEST_IMAGE" >&2
		return 1
	fi
}

test_image_is_detached() {
	local attached_loops

	if ! attached_loops="$(sudo losetup -j "$TEST_IMAGE" 2>/dev/null)"; then
		printf 'error: could not verify that the Waydroid Test image is detached\n' >&2
		return 1
	fi
	if [[ -n "$attached_loops" ]]; then
		printf 'error: the Waydroid Test image is still attached; shut down Waydroid before removing it\n' >&2
		return 1
	fi
}

remove_test_environment() {
	local confirmation

	validate_test_removal_paths || return 1
	if [[ ! -e "$TEST_IMAGE_ROOT" && ! -L "$TEST_IMAGE_ROOT" &&
		! -e "$TEST_XDG_ROOT" && ! -L "$TEST_XDG_ROOT" ]]; then
		printf 'No Waydroid Test environment was found.\n'
		return 0
	fi

	cat <<'EOF'
The Waydroid Test Android environment will be permanently deleted.
Its installed Android apps, settings and data will be lost.
The normal Waydroid environment will not be changed.
Steam shortcuts will not be changed.
EOF
	IFS= read -r -p "Type REMOVE TEST to continue: " confirmation
	if [[ "$confirmation" != "REMOVE TEST" ]]; then
		printf 'Waydroid Test removal cancelled.\n'
		return 0
	fi

	sudo -v || {
		printf 'error: administrator authentication is required to remove Waydroid Test\n' >&2
		return 1
	}
	ensure_waydroid_runtime_inactive_for_test_operation "removing Waydroid Test" || return 1
	test_image_is_detached || return 1
	validate_test_removal_paths || return 1
	ensure_waydroid_runtime_inactive_for_test_operation "removing Waydroid Test" || return 1
	sudo rm -rf -- "$TEST_IMAGE_ROOT" "$TEST_XDG_ROOT"
	if [[ -e "$TEST_IMAGE_ROOT" || -L "$TEST_IMAGE_ROOT" ||
		-e "$TEST_XDG_ROOT" || -L "$TEST_XDG_ROOT" ]]; then
		printf 'error: Waydroid Test state could not be completely removed\n' >&2
		return 1
	fi

	cat <<'EOF'
Waydroid Test Android environment has been removed.
The normal Waydroid environment was not changed.
Steam shortcuts were not changed.
EOF
}

remove_test_environment
