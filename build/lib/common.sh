#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

BUILD_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd -- "$BUILD_SCRIPT_DIR/.." && pwd)"
BUILD_CONFIG_FILE="${BUILD_CONFIG_FILE:-$REPO_ROOT/.build-config.env}"
CALLER_BUNDLE_VERSION="${BUNDLE_VERSION:-}"
CALLER_REPORT_ROOT="${REPORT_ROOT:-}"

if [[ -f "$BUILD_CONFIG_FILE" ]]; then
    # This file is user-owned local configuration and is never run as root on
    # the Steam Deck.
    # shellcheck source=/dev/null
    source "$BUILD_CONFIG_FILE"
fi

BUILD_WORK_ROOT="${BUILD_WORK_ROOT:-$HOME/steamos-waydroid-personal}"
BUNDLE_VERSION="${CALLER_BUNDLE_VERSION:-${BUNDLE_VERSION:-auto}}"
BUNDLE_REVISION="${BUNDLE_REVISION:-r1}"
WLROOTS_VERSION="${WLROOTS_VERSION:-0.18.2}"
PUBLISH_ROOT="${PUBLISH_ROOT:-$BUILD_WORK_ROOT/publish}"
TARGET_FINGERPRINT_FILE="${TARGET_FINGERPRINT_FILE:-$BUILD_WORK_ROOT/target-fingerprint.env}"
TARGETS_ROOT="${TARGETS_ROOT:-$BUILD_WORK_ROOT/targets}"
TARGET_WORK_ROOT="${TARGET_WORK_ROOT:-}"
REPORT_ROOT="${CALLER_REPORT_ROOT:-${REPORT_ROOT:-$BUILD_WORK_ROOT/reports}}"
BUILD_FAILURE_REPORT_ENABLED=false
BUILD_REPORT_STAGE=initialization

die() {
    printf 'error: %s\n' "$*" >&2
    if [[ "$BUILD_FAILURE_REPORT_ENABLED" == true ]]; then
        write_build_failure_report 1 "${BASH_LINENO[0]:-unknown}" "error: $*"
    fi
    exit 1
}

require_command() {
    local command_name="$1"
    command -v "$command_name" >/dev/null 2>&1 || \
        die "required command not found: $command_name"
}

require_non_root() {
    [[ $EUID -ne 0 ]] || die "run this command as your normal Fedora user"
}

set_build_report_stage() {
    BUILD_REPORT_STAGE="$1"
}

write_build_failure_report() {
    local exit_code="$1"
    local line_number="$2"
    local failed_command="$3"
    local timestamp report_file log_file source_tree

    set +e
    mkdir -p "$REPORT_ROOT"
    timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    report_file="$REPORT_ROOT/${BUNDLE_VERSION:-unknown}-$timestamp-build-failure.md"
    source_tree="${SOURCE_ROOT:-/work/src}"
    {
        printf '# Private bundle build failure\n\n'
        printf -- '- Generated (UTC): `%s`\n' "$timestamp"
        printf -- '- Bundle: `%s`\n' "${BUNDLE_VERSION:-unknown}"
        printf -- '- Stage: `%s`\n' "$BUILD_REPORT_STAGE"
        printf -- '- Exit status: `%s`\n' "$exit_code"
        printf -- '- Script line: `%s`\n' "$line_number"
        printf -- '- Failed command: `%s`\n' "$failed_command"
        printf -- '- Host kernel: `%s`\n' "$(uname -r)"
        if command -v git > /dev/null && [[ -d "$REPO_ROOT/.git" ]]; then
            printf -- '- Source revision: `%s`\n' \
                "$(git -C "$REPO_ROOT" rev-parse HEAD 2> /dev/null)"
        fi
        if [[ -r "$TARGET_FINGERPRINT_FILE" ]]; then
            printf '\n## Target fingerprint\n\n```text\n'
            cat "$TARGET_FINGERPRINT_FILE"
            printf '```\n'
        fi
        printf '\n## Meson log tails\n'
        while IFS= read -r log_file; do
            printf '\n### `%s`\n\n```text\n' "$log_file"
            tail -n 120 "$log_file"
            printf '```\n'
        done < <(find "$source_tree" -type f -path '*/meson-logs/meson-log.txt' 2> /dev/null | sort)
        printf '\n## Next action\n\n'
        printf 'Start with the first error in the relevant Meson log. Compare the target package versions with the dependency requested there; do not bypass a SONAME or API mismatch.\n'
    } > "$report_file"
    printf 'Build failure report saved: %s\n' "$report_file" >&2
    set -e
}

build_failure_err_trap() {
    local exit_code="$1"
    local line_number="$2"
    local failed_command="$3"
    trap - ERR
    write_build_failure_report "$exit_code" "$line_number" "$failed_command"
    return "$exit_code"
}

enable_build_failure_report() {
    BUILD_FAILURE_REPORT_ENABLED=true
    trap 'build_failure_err_trap "$?" "$LINENO" "$BASH_COMMAND"' ERR
}

resolve_bundle_version() {
    local candidate candidate_version selected_fingerprint target_environment
    selected_fingerprint="$TARGET_FINGERPRINT_FILE"
    if [[ "$BUNDLE_VERSION" == auto ]]; then
        [[ -r "$selected_fingerprint" ]] || \
            die "target fingerprint missing; run build/sync-steamos-rootfs.sh first"
        # shellcheck source=target-fingerprint.sh
        source "$BUILD_SCRIPT_DIR/lib/target-fingerprint.sh"
        BUNDLE_VERSION="$(fingerprint_value \
            "$selected_fingerprint" SUGGESTED_BUNDLE_VERSION)"
    else
        # Locate retained target metadata when selecting an older manual
        # bundle version rather than the most recently synced target.
        for candidate in "$TARGETS_ROOT"/*/target-fingerprint.env; do
            [[ -r "$candidate" ]] || continue
            candidate_version="$(awk -F= \
                '$1 == "SUGGESTED_BUNDLE_VERSION" {print $2; exit}' "$candidate")"
            if [[ "$candidate_version" == "$BUNDLE_VERSION" ]]; then
                selected_fingerprint="$candidate"
                break
            fi
        done
    fi
    [[ "$BUNDLE_VERSION" =~ ^[A-Za-z0-9._-]+$ ]] || \
        die "unsafe BUNDLE_VERSION: $BUNDLE_VERSION"
    target_environment="$(awk -F= \
        '$1 == "TARGET_ENVIRONMENT_ID" {print $2; exit}' "$selected_fingerprint")"
    if [[ -n "$target_environment" ]] && \
        [[ -r "$TARGETS_ROOT/$target_environment/target-fingerprint.env" ]]; then
        TARGET_WORK_ROOT="$TARGETS_ROOT/$target_environment"
        TARGET_FINGERPRINT_FILE="$TARGET_WORK_ROOT/target-fingerprint.env"
    fi
}

require_steamos_root() {
    [[ -r /etc/os-release ]] || die "cannot read /etc/os-release"
    # shellcheck source=/dev/null
    source /etc/os-release
    [[ ${ID:-} == steamos ]] || \
        die "this build step must run inside the copied SteamOS rootfs"
    [[ $(uname -m) == x86_64 ]] || die "only x86_64 is supported"
}
