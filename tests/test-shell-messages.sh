#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$REPO_ROOT/steamos-waydroid-installer.sh"
INSTALLER_FUNCTIONS="$REPO_ROOT/libexec/steamos-waydroid/installer-functions.sh"

if rg -n \
	'^\s*(no previous persistent image was found|inspect the timestamped archives before retrying\.)' \
	"$INSTALLER" "$INSTALLER_FUNCTIONS"; then
	printf 'not ok - installer prose is being parsed as a shell command\n' >&2
	exit 1
fi

grep -Fq -- \
	"printf 'Mode: install Android; no previous persistent image was found.\\n'" \
	"$INSTALLER"
grep -Fq -- \
	"'Automatic restoration was incomplete; inspect the timestamped archives before retrying.'" \
	"$INSTALLER_FUNCTIONS"

printf 'ok - installer status messages are emitted as data\n'
