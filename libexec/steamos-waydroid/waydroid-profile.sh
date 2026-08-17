#!/usr/bin/env bash
# shellcheck disable=SC2034 # This sourced library intentionally sets API variables.

# Resolve the two approved Waydroid runtime profiles. Privileged callers must
# pass only a profile name; paths are derived here from the invoking user's
# passwd entry rather than from root's HOME.

waydroid_user_home() {
	local user_name passwd_entry user_home

	if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then
		user_name=$SUDO_USER
	elif ((EUID == 0)); then
		user_name=deck
	else
		user_home=${HOME:-}
		[[ "$user_home" == /* && "$user_home" != /root ]] || {
			printf 'error: unsafe home directory for the current user: %s\n' \
				"${user_home:-missing}" >&2
			return 1
		}
		printf '%s\n' "$user_home"
		return 0
	fi

	passwd_entry="$(getent passwd "$user_name" 2>/dev/null)" || {
		printf 'error: could not resolve the home directory for SteamOS user %s\n' \
			"$user_name" >&2
		return 1
	}
	user_home="$(cut -d: -f6 <<<"$passwd_entry")"
	[[ "$user_home" == /* && "$user_home" != /root ]] || {
		printf 'error: unsafe home directory for SteamOS user %s: %s\n' \
			"$user_name" "${user_home:-missing}" >&2
		return 1
	}
	printf '%s\n' "$user_home"
}

resolve_waydroid_profile() {
	local requested_profile="${1-main}"
	local user_home

	if (($# > 1)); then
		printf 'error: resolve_waydroid_profile accepts one profile name\n' >&2
		return 2
	fi
	case "$requested_profile" in
	main | test) ;;
	*)
		printf 'error: unsupported Waydroid profile: %s (expected main or test)\n' \
			"$requested_profile" >&2
		return 2
		;;
	esac

	user_home="$(waydroid_user_home)" || return
	WAYDROID_PROFILE=$requested_profile
	case "$WAYDROID_PROFILE" in
	main)
		WAYDROID_IMAGE="$user_home/Android_Waydroid/waydroid.img"
		WAYDROID_XDG_DATA_HOME="$user_home/.local/share"
		;;
	test)
		WAYDROID_IMAGE="$user_home/Android_Waydroid/test/waydroid.img"
		WAYDROID_XDG_DATA_HOME="$user_home/.local/share/waydroid-test"
		;;
	esac
	WAYDROID_USER_STATE="$WAYDROID_XDG_DATA_HOME/waydroid"
	WAYDROID_DATA="$WAYDROID_USER_STATE/data"
}
