#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_BUNDLE_SELECTOR="$SCRIPT_DIR/select-bundle"

if [ -x "$LOCAL_BUNDLE_SELECTOR" ] &&
	! SELECTOR_OUTPUT=$("$LOCAL_BUNDLE_SELECTOR" 2>&1); then
	kdialog --error "No installed Cage bundle matches this SteamOS build.

$SELECTOR_OUTPUT

Run the SteamOS Waydroid installer from Desktop Mode to fetch or repair the matching bundle."
	exit 1
fi

BUNDLE="$HOME/.local/opt/steamos-waydroid/current"
CAGE="$BUNDLE/bin/cage"
WLR_RANDR="$BUNDLE/bin/wlr-randr"
TARGET_CHECK="$BUNDLE/tools/check-bundle-target.sh"
COMPATIBILITY_REPORT="$BUNDLE/tools/compatibility-report.sh"
TARGET_ALLOW="$HOME/.local/opt/steamos-waydroid/allow-target-mismatch"
CONFIG_DIR="$SCRIPT_DIR/config"
RESOLUTION="$(xdpyinfo | awk '/dimensions/{print $2; exit}')"

if [ ! -x "$CAGE" ] ||
	[ ! -x "$WLR_RANDR" ] ||
	[ ! -x "$TARGET_CHECK" ] ||
	[ ! -f "$BUNDLE/.verified" ]; then
	kdialog --error "Cage bundle is missing or unverified. Run the installer from Desktop Mode."
	exit 1
fi

target_check_args=("$BUNDLE")
active_bundle_version="$(basename "$(readlink -f "$BUNDLE")")"

if [ -r "$TARGET_ALLOW" ] &&
	[ "$(cat "$TARGET_ALLOW")" = "$active_bundle_version" ]; then
	target_check_args+=(--allow-target-mismatch)
fi

if ! TARGET_CHECK_OUTPUT=$("$TARGET_CHECK" "${target_check_args[@]}" 2>&1); then
	REPORT_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/steamos-waydroid/reports/$(date -u +%Y%m%dT%H%M%SZ)-compatibility.md"

	if [ -x "$COMPATIBILITY_REPORT" ]; then
		"$COMPATIBILITY_REPORT" "$BUNDLE" "$REPORT_FILE" || true
	fi

	kdialog --error "The Cage bundle does not match this SteamOS build.

$TARGET_CHECK_OUTPUT

Compatibility report: $REPORT_FILE

Rebuild and install the bundle before launching Waydroid."
	exit 1
fi

if [ ! -x /usr/bin/waydroid ]; then
	kdialog --sorry "Cannot start Waydroid because the SteamOS host component is missing. \
\nIf SteamOS was recently updated, run the SteamOS Waydroid installer from Desktop Mode. \
\nSteamOS version: $(grep -i VERSION_ID /etc/os-release | cut -d '=' -f 2) \
\nKernel version: $(uname -r | cut -d '-' -f 1-5)"
	exit 1
fi

if [ -z "$RESOLUTION" ] ||
	[ ! -r "$CONFIG_DIR/fake_wifi" ] ||
	[ ! -r "$CONFIG_DIR/fake_touch" ]; then
	kdialog --error "Waydroid launcher configuration is incomplete. Reinstall the host component."
	exit 1
fi

cleanup_required=false
LAUNCH_ERROR_LOG="$(mktemp "${XDG_RUNTIME_DIR:-/tmp}/steamos-waydroid-launch.XXXXXX")"

cleanup() {
	if [ "$cleanup_required" = true ]; then
		cleanup_required=false
		sudo /usr/bin/waydroid-shutdown-scripts || true
	fi
	rm -f -- "$LAUNCH_ERROR_LOG"
}

show_launch_failure() {
	local launch_status="$1"
	local error_details

	error_details="$(tail -n 30 "$LAUNCH_ERROR_LOG" 2>/dev/null || true)"
	if [ -z "$error_details" ]; then
		error_details="Cage exited with status $launch_status without diagnostic output."
	fi
	cleanup
	kdialog --error "Waydroid could not finish starting.

$error_details

Run the SteamOS Waydroid installer in Desktop Mode to repair the reported problem."
	exit 1
}

trap cleanup EXIT
trap 'exit 130' HUP INT TERM

# A running Waydroid session remains bound to the Wayland compositor that
# started it. Stop it gracefully before waydroid-mount stops the container, so
# the session started below will bind to Cage instead of returning immediately
# through the stale session on the desktop compositor.
/usr/bin/waydroid session stop >/dev/null 2>&1 || true

# Mount persistent Android state before starting the container. From this point
# onward, the EXIT trap owns cleanup, including launch failures and signals.
if ! PREFLIGHT_OUTPUT=$(sudo /usr/bin/waydroid-mount 2>&1); then
	kdialog --error "Waydroid preflight failed before Cage was started.

$PREFLIGHT_OUTPUT

Run the SteamOS Waydroid installer in Desktop Mode to repair the reported problem."
	exit 1
fi
cleanup_required=true

if ! CONTAINER_OUTPUT=$(sudo /usr/bin/waydroid-firewall 2>&1); then
	kdialog --error "Waydroid container startup failed.

$CONTAINER_OUTPUT

Run the SteamOS Waydroid installer in Desktop Mode to repair the host integration."
	exit 1
fi

if ! systemctl is-active --quiet waydroid-container.service; then
	SERVICE_STATUS="$(systemctl status --no-pager waydroid-container.service 2>&1 || true)"
	kdialog --error "The Waydroid container did not remain active.

$SERVICE_STATUS

Run the SteamOS Waydroid installer in Desktop Mode to repair the host integration."
	exit 1
fi

if [ -z "${1:-}" ]; then

	# Variables inside this single-quoted command are intentionally expanded
	# by the inner bash process using the positional arguments supplied below.
	# shellcheck disable=SC2016
	if "$CAGE" -- bash -c '
		readonly WLR_RANDR="$1"
		readonly RESOLUTION="$2"
		readonly CONFIG_DIR="$3"

		"$WLR_RANDR" \
			--output X11-1 \
			--custom-mode "$RESOLUTION"

		/usr/bin/waydroid show-full-ui &
		readonly WAYDROID_SESSION_PID=$!
		sleep 10

		waydroid prop set \
			persist.waydroid.fake_wifi \
			"$(cat "$CONFIG_DIR/fake_wifi")"

		waydroid prop set \
			persist.waydroid.fake_touch \
			"$(cat "$CONFIG_DIR/fake_touch")"

		if ! sudo /usr/bin/waydroid-startup-scripts; then
			jobs -pr | while IFS= read -r child_pid; do
				kill "$child_pid" 2>/dev/null || true
			done
			wait 2>/dev/null || true
			exit 1
		fi

		wait "$WAYDROID_SESSION_PID"
	' bash "$WLR_RANDR" "$RESOLUTION" "$CONFIG_DIR" \
		>"$LAUNCH_ERROR_LOG" 2>&1; then
		:
	else
		launch_status=$?
		show_launch_failure "$launch_status"
	fi
else
	PACKAGE="$1"

	# Variables inside this single-quoted command are intentionally expanded
	# by the inner bash process using the positional arguments supplied below.
	# shellcheck disable=SC2016
	if "$CAGE" -- bash -c '
		readonly WLR_RANDR="$1"
		readonly RESOLUTION="$2"
		readonly CONFIG_DIR="$3"
		readonly PACKAGE="$4"

		"$WLR_RANDR" \
			--output X11-1 \
			--custom-mode "$RESOLUTION"

		/usr/bin/waydroid session start &
		readonly WAYDROID_SESSION_PID=$!
		sleep 10

		waydroid prop set \
			persist.waydroid.fake_wifi \
			"$(cat "$CONFIG_DIR/fake_wifi")"

		waydroid prop set \
			persist.waydroid.fake_touch \
			"$(cat "$CONFIG_DIR/fake_touch")"

		if ! sudo /usr/bin/waydroid-startup-scripts; then
			jobs -pr | while IFS= read -r child_pid; do
				kill "$child_pid" 2>/dev/null || true
			done
			wait 2>/dev/null || true
			exit 1
		fi
		sleep 1

		/usr/bin/waydroid app launch "$PACKAGE" &
		sleep 1

		/usr/bin/waydroid show-full-ui &
		wait "$WAYDROID_SESSION_PID"
	' bash "$WLR_RANDR" "$RESOLUTION" "$CONFIG_DIR" "$PACKAGE" \
		>"$LAUNCH_ERROR_LOG" 2>&1; then
		:
	else
		launch_status=$?
		show_launch_failure "$launch_status"
	fi
fi
