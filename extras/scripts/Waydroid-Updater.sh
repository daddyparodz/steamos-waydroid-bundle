#!/bin/bash

set -e

checkout="$HOME/steamos-waydroid-personal"
repository="https://github.com/pjohno/steamos-waydroid-personal.git"

echo "Updating the SteamOS Waydroid Installer from its public repository."
sleep 2

if [ -d "$checkout/.git" ]; then
	git -C "$checkout" pull --ff-only
elif [ -e "$checkout" ]; then
	echo "Cannot clone: $checkout exists but is not a Git checkout." >&2
	exit 1
else
	git clone --depth=1 "$repository" "$checkout"
fi

exec "$checkout/steamos-waydroid-installer.sh"
