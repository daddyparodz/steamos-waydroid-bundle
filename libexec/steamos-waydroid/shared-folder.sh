#!/usr/bin/env bash

# Shared-folder lifecycle helpers shared by the unprivileged installer/launcher
# and the privileged startup/shutdown scripts.

waydroid_user_home() {
	local user_name="${SUDO_USER:-deck}"
	local passwd_entry user_home

	[[ -n "$user_name" && "$user_name" != root ]] || {
		printf 'error: could not identify the normal SteamOS user for the Waydroid shared folder\n' >&2
		return 1
	}
	passwd_entry="$(getent passwd "$user_name" 2>/dev/null)" || {
		printf 'error: could not resolve the home directory for SteamOS user %s\n' "$user_name" >&2
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

ensure_waydroid_share_source() {
	local user_home="$1"
	local share_source="$user_home/Waydroid Share"

	if [[ -e "$share_source" || -L "$share_source" ]]; then
		[[ -d "$share_source" && ! -L "$share_source" ]] || {
			printf 'error: Waydroid shared-folder path exists but is not a directory: %s\n' \
				"$share_source" >&2
			return 1
		}
		return 0
	fi

	mkdir -- "$share_source" || {
		printf 'error: could not create the Waydroid shared folder: %s\n' \
			"$share_source" >&2
		return 1
	}
	printf 'Created Waydroid shared folder: %s\n' "$share_source"
}

waydroid_share_is_correctly_mounted() {
	local share_source="$1"
	local share_target="$2"
	local source_identity target_identity

	findmnt --mountpoint "$share_target" >/dev/null 2>&1 || return 1
	source_identity="$(stat -Lc '%d:%i' -- "$share_source" 2>/dev/null)" || return 1
	target_identity="$(stat -Lc '%d:%i' -- "$share_target" 2>/dev/null)" || return 1
	[[ "$source_identity" == "$target_identity" ]]
}

wait_for_waydroid_emulated_storage() {
	local timeout_seconds="${1:-90}"
	local poll_seconds="${2:-2}"
	local query_timeout_seconds="${3:-5}"
	local deadline

	[[ "$timeout_seconds" =~ ^[0-9]+$ ]] || {
		printf 'error: invalid Waydroid emulated-storage timeout: %s\n' \
			"$timeout_seconds" >&2
		return 2
	}
	[[ "$poll_seconds" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
		printf 'error: invalid Waydroid emulated-storage polling interval: %s\n' \
			"$poll_seconds" >&2
		return 2
	}
	[[ "$query_timeout_seconds" =~ ^[1-9][0-9]*$ ]] || {
		printf 'error: invalid Waydroid storage-query timeout: %s\n' \
			"$query_timeout_seconds" >&2
		return 2
	}

	deadline=$((SECONDS + timeout_seconds))
	while true; do
		if timeout "$query_timeout_seconds" waydroid shell -- sh -c \
			'pm path android 2>/dev/null | grep -q "^package:" && test -d /storage/emulated/0 && test -r /storage/emulated/0 && test -w /storage/emulated/0' \
			>/dev/null 2>&1; then
			return 0
		fi

		if ! systemctl is-active --quiet waydroid-container.service; then
			printf 'error: Waydroid container stopped before Android user 0 emulated storage became ready\n' >&2
			systemctl status --no-pager waydroid-container.service >&2 || true
			return 1
		fi

		if ((SECONDS >= deadline)); then
			printf 'error: Android user 0 emulated storage did not become ready at /storage/emulated/0 within %s seconds\n' \
				"$timeout_seconds" >&2
			return 124
		fi

		sleep "$poll_seconds"
	done
}

mount_waydroid_share() {
	local user_home="$1"
	local share_source="$user_home/Waydroid Share"
	local share_target="$user_home/.local/share/waydroid/data/media/0/Waydroid Share"

	[[ -d "$share_source" && ! -L "$share_source" ]] || {
		printf 'error: Waydroid shared folder is missing: %s\n' "$share_source" >&2
		return 1
	}
	mkdir -p -- "$share_target" || {
		printf 'error: could not create the Android shared-folder mount point: %s\n' \
			"$share_target" >&2
		return 1
	}

	if findmnt --mountpoint "$share_target" >/dev/null 2>&1; then
		if waydroid_share_is_correctly_mounted "$share_source" "$share_target"; then
			printf 'Waydroid shared folder is already mounted.\n'
			return 0
		fi
		printf 'error: an unexpected filesystem is mounted at the Waydroid shared-folder target: %s\n' \
			"$share_target" >&2
		return 1
	fi

	mount --bind "$share_source" "$share_target" || {
		printf 'error: could not bind-mount Waydroid shared folder from %s to %s\n' \
			"$share_source" "$share_target" >&2
		return 1
	}
	if ! waydroid_share_is_correctly_mounted "$share_source" "$share_target"; then
		printf 'error: Waydroid shared-folder bind mount could not be verified: %s -> %s\n' \
			"$share_source" "$share_target" >&2
		if ! umount "$share_target"; then
			printf 'error: could not clean up the unverified Waydroid shared-folder bind mount: %s\n' \
				"$share_target" >&2
		fi
		return 1
	fi
	printf 'Mounted Waydroid shared folder: %s -> %s\n' "$share_source" "$share_target"
}

mount_waydroid_share_when_ready() {
	local user_home="$1"
	local timeout_seconds="${2:-90}"
	local poll_seconds="${3:-2}"

	wait_for_waydroid_emulated_storage "$timeout_seconds" "$poll_seconds" || return
	mount_waydroid_share "$user_home"
}

unmount_waydroid_share() {
	local user_home="$1"
	local share_target="$user_home/.local/share/waydroid/data/media/0/Waydroid Share"

	if ! findmnt --mountpoint "$share_target" >/dev/null 2>&1; then
		return 0
	fi
	umount "$share_target" || {
		printf 'error: could not unmount the Waydroid shared folder: %s\n' \
			"$share_target" >&2
		return 1
	}
	printf 'Unmounted Waydroid shared folder: %s\n' "$share_target"
}
