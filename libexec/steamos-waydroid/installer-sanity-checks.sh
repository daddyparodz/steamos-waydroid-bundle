#!/usr/bin/env bash

# Installer-only preflight functions. This file is sourced by
# steamos-waydroid-installer.sh and is not a standalone command.

sanity_fail() {
	printf 'Error: %s\n' "$*" >&2
	return 1
}

run_nonprivileged_sanity_checks() {
	local version_rest version_major version_minor free_home

	if [[ "${ID:-}" != steamos ]]
	then
		sanity_fail "this installer can only run on SteamOS"
		return 1
	fi

	if ! command -v xdpyinfo > /dev/null 2>&1 || ! xdpyinfo > /dev/null 2>&1
	then
		sanity_fail "run the installer locally from Konsole in SteamOS Desktop Mode"
		return 1
	fi
	printf 'Installer is running in Desktop Mode.\n'

	version_major="${STEAMOS_VERSION_ID%%.*}"
	version_rest="${STEAMOS_VERSION_ID#*.}"
	version_minor="${version_rest%%.*}"
	if [[ ! "$version_major" =~ ^[0-9]+$ || ! "$version_minor" =~ ^[0-9]+$ ]] || \
		(( version_major != 3 || version_minor != 8 ))
	then
		sanity_fail "SteamOS $STEAMOS_VERSION_ID is unsupported; this release supports SteamOS 3.8.x"
		return 1
	fi
	printf 'SteamOS %s (%s branch) detected.\n' "$STEAMOS_VERSION_ID" "$STEAMOS_BRANCH"

	case "$STEAMOS_BRANCH" in
		rel|beta)
			printf 'Supported SteamOS %s branch detected.\n' "$STEAMOS_BRANCH"
			;;
		main)
			if ! zenity --question \
				--title "SteamOS Waydroid Installer" \
				--text "WARNING: SteamOS main branch detected.\n\nThe installer is validated for the stable and beta branches. A compatible target bundle must still be published for this exact userspace.\n\nContinue?" \
				--width 650 --height 75 > /dev/null 2>&1
			then
				sanity_fail "installation cancelled on the SteamOS main branch"
				return 1
			fi
			printf 'Continuing on the SteamOS main branch at the user\047s request.\n'
			;;
		*)
			sanity_fail "unsupported or unknown SteamOS update branch: ${STEAMOS_BRANCH:-unknown}"
			return 1
			;;
	esac

	# Repair reuses the persistent Android image and does not create a new one.
	if [[ "${REPAIR_MODE:-false}" != true ]]
	then
		free_home="$(df --output=avail "$HOME" 2> /dev/null | awk 'NR == 2 {print $1}')"
		if [[ ! "$free_home" =~ ^[0-9]+$ ]]
		then
			sanity_fail "could not determine free space in $HOME"
			return 1
		fi
		printf 'Home filesystem has %s KiB free.\n' "$free_home"
		if (( free_home < 10000000 ))
		then
			sanity_fail "at least 10 GB of free home-filesystem space is required"
			return 1
		fi
	fi
}

ensure_sanity_bundle() {
	if STEAMOS_WAYDROID_INTERNAL=1 "$DECK_RUNTIME/ensure-bundle-on-deck.sh"
	then
		return 0
	fi

	cat >&2 <<EOF

No compatible Waydroid host bundle could be obtained for this SteamOS target.

  SteamOS version: $STEAMOS_VERSION_ID
  SteamOS build:   $STEAMOS_BUILD_ID
  SteamOS branch:  $STEAMOS_BRANCH

The configured bundle catalog may not have been published yet, this target may
not have an entry, or the artifact source may be temporarily unavailable. No
privileged SteamOS changes have been made and the Android image was not touched.

You can wait for a compatible bundle and run the installer again, return to a
previously supported SteamOS deployment, or build and publish a target bundle
using the maintainer procedure. A mismatched bundle should only be used for a
deliberate compatibility test.
EOF
	return 1
}

run_privileged_sanity_checks() {
	local password_status

	password_status="$(passwd --status "$(id -un)" 2> /dev/null | awk '{print $2}')"
	if [[ "$password_status" != P ]]
	then
		printf 'A sudo password is required. Set one with passwd, then rerun the installer.\n' >&2
		return 1
	fi

	IFS= read -r -s -p "Please enter current sudo password: " current_password
	printf '\nChecking the sudo password...\n'
	if ! printf '%s\n' "$current_password" | sudo -S -k -v > /dev/null 2>&1
	then
		printf 'The sudo password was not accepted. Rerun the installer and try again.\n' >&2
		return 1
	fi
	printf 'Sudo authentication succeeded.\n'

	# Read by steamos-waydroid-installer.sh after run_privileged_sanity_checks returns.
	# shellcheck disable=SC2034
	DECKY_LOADER_STOPPED=false
	if [[ "${REPAIR_MODE:-false}" != true ]] && \
		systemctl is-active --quiet plugin_loader.service
	then
		printf 'Temporarily stopping Decky Loader during installation...\n'
		if ! printf '%s\n' "$current_password" | \
			sudo -S systemctl stop plugin_loader.service
		then
			printf 'Could not stop the Decky Loader plugin service.\n' >&2
			return 1
		fi
		# Read by steamos-waydroid-installer.sh after run_privileged_sanity_checks returns.
		# shellcheck disable=SC2034
		DECKY_LOADER_STOPPED=true
		printf 'You will be asked whether to restart Decky Loader when installation finishes.\n'
	fi
}
