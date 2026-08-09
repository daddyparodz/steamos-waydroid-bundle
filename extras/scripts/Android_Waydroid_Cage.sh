#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_BUNDLE_SELECTOR="$SCRIPT_DIR/select-bundle"

if [ -x "$LOCAL_BUNDLE_SELECTOR" ] &&
	! SELECTOR_OUTPUT=$("$LOCAL_BUNDLE_SELECTOR" 2>&1)
then
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
	[ ! -f "$BUNDLE/.verified" ]
then
	kdialog --error "Cage bundle is missing or unverified. Run the installer from Desktop Mode."
	exit 1
fi

target_check_args=("$BUNDLE")
active_bundle_version="$(basename "$(readlink -f "$BUNDLE")")"

if [ -r "$TARGET_ALLOW" ] &&
	[ "$(cat "$TARGET_ALLOW")" = "$active_bundle_version" ]
then
	target_check_args+=(--allow-target-mismatch)
fi

if ! TARGET_CHECK_OUTPUT=$("$TARGET_CHECK" "${target_check_args[@]}" 2>&1)
then
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
	[ ! -r "$CONFIG_DIR/fake_touch" ]
then
	kdialog --error "Waydroid launcher configuration is incomplete. Reinstall the host component."
	exit 1
fi

cleanup_required=false

cleanup() {
	if [ "$cleanup_required" = true ]; then
		cleanup_required=false
		sudo /usr/bin/waydroid-shutdown-scripts || true
	fi
}

trap cleanup EXIT HUP INT TERM

# Mount persistent Android state before starting the container. From this point
# onward, the EXIT trap owns cleanup, including launch failures and signals.
sudo /usr/bin/waydroid-mount
cleanup_required=true

sudo /usr/bin/waydroid-firewall

if ! systemctl is-active --quiet waydroid-container.service; then
	kdialog --sorry "Something went wrong. The Waydroid container did not initialize correctly."
	exit 1
fi

if [ -z "${1:-}" ]; then

	# Variables inside this single-quoted command are intentionally expanded
	# by the inner bash process using the positional arguments supplied below.
	# shellcheck disable=SC2016
	"$CAGE" -- bash -c '
		readonly WLR_RANDR="$1"
		readonly RESOLUTION="$2"
		readonly CONFIG_DIR="$3"

		"$WLR_RANDR" \
			--output X11-1 \
			--custom-mode "$RESOLUTION"

		/usr/bin/waydroid show-full-ui &
		sleep 10

		waydroid prop set \
			persist.waydroid.fake_wifi \
			"$(cat "$CONFIG_DIR/fake_wifi")"

		waydroid prop set \
			persist.waydroid.fake_touch \
			"$(cat "$CONFIG_DIR/fake_touch")"

		sudo /usr/bin/waydroid-startup-scripts
	' bash "$WLR_RANDR" "$RESOLUTION" "$CONFIG_DIR"
else
	PACKAGE="$1"

	# Variables inside this single-quoted command are intentionally expanded
	# by the inner bash process using the positional arguments supplied below.
	# shellcheck disable=SC2016
	"$CAGE" -- bash -c '
		readonly WLR_RANDR="$1"
		readonly RESOLUTION="$2"
		readonly CONFIG_DIR="$3"
		readonly PACKAGE="$4"

		"$WLR_RANDR" \
			--output X11-1 \
			--custom-mode "$RESOLUTION"

		/usr/bin/waydroid session start &
		sleep 10

		waydroid prop set \
			persist.waydroid.fake_wifi \
			"$(cat "$CONFIG_DIR/fake_wifi")"

		waydroid prop set \
			persist.waydroid.fake_touch \
			"$(cat "$CONFIG_DIR/fake_touch")"

		sudo /usr/bin/waydroid-startup-scripts
		sleep 1

		/usr/bin/waydroid app launch "$PACKAGE" &
		sleep 1

		/usr/bin/waydroid show-full-ui &
	' bash "$WLR_RANDR" "$RESOLUTION" "$CONFIG_DIR" "$PACKAGE"
fi

