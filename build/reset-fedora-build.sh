#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_non_root
require_command realpath
require_command sudo

INCLUDE_CONFIG=false
if [[ ${1:-} == --include-config ]]; then
    INCLUDE_CONFIG=true
elif [[ $# -ne 0 ]]; then
    die "usage: $0 [--include-config]"
fi

WORK_ROOT="$(realpath -m -- "$BUILD_WORK_ROOT")"
PUBLISH_PATH="$(realpath -m -- "$PUBLISH_ROOT")"
HOME_ROOT="$(realpath -e -- "$HOME")"
SOURCE_ROOT="$(realpath -e -- "$REPO_ROOT")"

case "$WORK_ROOT" in
    /|"$HOME_ROOT"|"$SOURCE_ROOT"|"$SOURCE_ROOT"/*)
        die "refusing unsafe BUILD_WORK_ROOT: $WORK_ROOT"
        ;;
esac
case "$SOURCE_ROOT/" in
    "$WORK_ROOT/"*) die "BUILD_WORK_ROOT contains the Git checkout: $WORK_ROOT" ;;
esac
case "$PUBLISH_PATH" in
    "$WORK_ROOT"|"$WORK_ROOT"/*) ;;
    *) die "PUBLISH_ROOT must be inside BUILD_WORK_ROOT for a full reset" ;;
esac

printf 'This permanently deletes the Fedora build workspace:\n  %s\n' "$WORK_ROOT"
if [[ "$INCLUDE_CONFIG" == true ]]; then
    printf 'It also deletes:\n  %s\n' "$BUILD_CONFIG_FILE"
fi
printf 'The Git checkout and SSH configuration are retained.\n\n'
read -r -p 'Type DELETE FEDORA BUILD to continue: ' confirmation
[[ "$confirmation" == "DELETE FEDORA BUILD" ]] || die "reset cancelled"

if [[ -e "$WORK_ROOT" ]]; then
    sudo rm -rf -- "$WORK_ROOT"
fi
if [[ "$INCLUDE_CONFIG" == true ]]; then
    rm -f -- "$BUILD_CONFIG_FILE"
fi

printf '\nFedora build workspace reset complete.\n'
