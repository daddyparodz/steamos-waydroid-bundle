#!/bin/bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BUNDLE="$HOME/.local/opt/steamos-waydroid/current"
CAGE="$BUNDLE/bin/cage"
WLR_RANDR="$BUNDLE/bin/wlr-randr"
CONFIG_DIR="$SCRIPT_DIR/config"
RESOLUTION="$(xdpyinfo | awk '/dimensions/{print $2; exit}')"

if [ ! -x "$CAGE" ] || [ ! -x "$WLR_RANDR" ] || [ ! -f "$BUNDLE/.verified" ]
then
	kdialog --error "Private Cage bundle is missing or unverified. Run the Fedora deployment tool."
	exit 1
fi
if [ ! -x /usr/bin/waydroid ]
then
	kdialog --sorry "Cannot start Waydroid because the SteamOS host component is missing. \
\nIf SteamOS was recently updated, run the personal installer repair from Desktop Mode. \
\nSteamOS version: $(grep -i VERSION_ID /etc/os-release | cut -d '=' -f 2) \
\nKernel version: $(uname -r | cut -d '-' -f 1-5)"
	exit 1
fi

if [ -z "$RESOLUTION" ] || [ ! -r "$CONFIG_DIR/fake_wifi" ] || [ ! -r "$CONFIG_DIR/fake_touch" ]
then
	kdialog --error "Waydroid launcher configuration is incomplete. Reinstall the personal host component."
	exit 1
fi

export CONFIG_DIR RESOLUTION WLR_RANDR
cleanup_required=false

cleanup() {
	if [ "$cleanup_required" = true ]
	then
		cleanup_required=false
		sudo /usr/bin/waydroid-shutdown-scripts || true
	fi
}
trap cleanup EXIT HUP INT TERM

# Mount persistent Android state before starting the container. From this point
# onward the EXIT trap owns cleanup, including launch failures and signals.
sudo /usr/bin/waydroid-mount
cleanup_required=true

sudo /usr/bin/waydroid-firewall
if ! systemctl is-active --quiet waydroid-container.service
then
	kdialog --sorry "Something went wrong. The Waydroid container did not initialize correctly."
	exit 1
fi

if [ -z "${1:-}" ]
then
	"$CAGE" -- bash -c '
		"$WLR_RANDR" --output X11-1 --custom-mode "$RESOLUTION"
		/usr/bin/waydroid show-full-ui &
		sleep 10
		waydroid prop set persist.waydroid.fake_wifi "$(cat "$CONFIG_DIR/fake_wifi")"
		waydroid prop set persist.waydroid.fake_touch "$(cat "$CONFIG_DIR/fake_touch")"
		sudo /usr/bin/waydroid-startup-scripts
	'
else
	export PACKAGE="$1"
	"$CAGE" -- bash -c '
		"$WLR_RANDR" --output X11-1 --custom-mode "$RESOLUTION"
		/usr/bin/waydroid session start &
		sleep 10
		waydroid prop set persist.waydroid.fake_wifi "$(cat "$CONFIG_DIR/fake_wifi")"
		waydroid prop set persist.waydroid.fake_touch "$(cat "$CONFIG_DIR/fake_touch")"
		sudo /usr/bin/waydroid-startup-scripts
		sleep 1
		/usr/bin/waydroid app launch "$PACKAGE" &
		sleep 1
		/usr/bin/waydroid show-full-ui &
	'
fi
