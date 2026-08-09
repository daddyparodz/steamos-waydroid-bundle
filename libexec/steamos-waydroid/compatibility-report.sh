#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -r "$SCRIPT_DIR/lib/target-fingerprint.sh" ]]; then
    # shellcheck source=lib/target-fingerprint.sh
    source "$SCRIPT_DIR/lib/target-fingerprint.sh"
elif [[ -r "$SCRIPT_DIR/target-fingerprint.sh" ]]; then
    # Installed bundle layout.
    # shellcheck source=lib/target-fingerprint.sh
    source "$SCRIPT_DIR/target-fingerprint.sh"
else
    printf 'error: target fingerprint helper is missing\n' >&2
    exit 1
fi

BUNDLE_ROOT="${1:-}"
OUTPUT_FILE="${2:-/dev/stdout}"
EXPECTED="$BUNDLE_ROOT/target-fingerprint.env"
[[ -r "$EXPECTED" ]] || {
    printf 'error: bundle target fingerprint is missing: %s\n' "$EXPECTED" >&2
    exit 1
}

if [[ "$OUTPUT_FILE" != /dev/stdout ]]; then
    mkdir -p "$(dirname -- "$OUTPUT_FILE")"
fi

CURRENT="$(mktemp)"
cleanup() {
    rm -f -- "$CURRENT"
}
trap cleanup EXIT
collect_target_fingerprint "$CURRENT"

expected_version="$(fingerprint_value "$EXPECTED" STEAMOS_VERSION_ID)"
expected_build="$(fingerprint_value "$EXPECTED" STEAMOS_BUILD_ID)"
expected_abi="$(fingerprint_value "$EXPECTED" ABI_SHA256)"
current_version="$(fingerprint_value "$CURRENT" STEAMOS_VERSION_ID)"
current_build="$(fingerprint_value "$CURRENT" STEAMOS_BUILD_ID)"
current_abi="$(fingerprint_value "$CURRENT" ABI_SHA256)"

{
    printf '# SteamOS Waydroid compatibility report\n\n'
    # Literal backticks are Markdown; substitutions are printf arguments.
    # shellcheck disable=SC2016
    printf -- '- Generated (UTC): `%s`\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    # Literal backticks are Markdown; substitutions are printf arguments.
    # shellcheck disable=SC2016
    printf -- '- Host: `%s`\n' "$(hostname)"
    # Literal backticks are Markdown; substitutions are printf arguments.
    # shellcheck disable=SC2016
    printf -- '- Bundle: `%s`\n\n' "$(basename -- "$(readlink -f "$BUNDLE_ROOT")")"
    
    printf '| Check | Bundle target | Current Deck | Match |\n'
    printf '|---|---|---|---|\n'
    
    # Literal backticks are Markdown; substitutions are printf arguments.
    # shellcheck disable=SC2016
    printf '| SteamOS version | `%s` | `%s` | %s |\n' \
        "$expected_version" "$current_version" \
        "$([[ "$expected_version" == "$current_version" ]] && printf yes || printf no)"
    # Literal backticks are Markdown; substitutions are printf arguments.
    # shellcheck disable=SC2016
    printf '| SteamOS build | `%s` | `%s` | %s |\n' \
        "$expected_build" "$current_build" \
        "$([[ "$expected_build" == "$current_build" ]] && printf yes || printf no)"
    # Literal backticks are Markdown; substitutions are printf arguments.
    # shellcheck disable=SC2016
    printf '| Compatibility hash | `%s` | `%s` | %s |\n\n' \
        "$expected_abi" "$current_abi" \
        "$([[ "$expected_abi" == "$current_abi" ]] && printf yes || printf no)"

    printf '## Package differences\n\n'
    differences=0
    while IFS='=' read -r key expected_value; do
        [[ "$key" == PKG_* ]] || continue
        current_value="$(fingerprint_value "$CURRENT" "$key")"
        if [[ "$expected_value" != "$current_value" ]]; then
            # Literal backticks are Markdown; substitutions are printf arguments.
            # shellcheck disable=SC2016
            printf -- '- `%s`: bundle `%s`; Deck `%s`\n' \
                "${key#PKG_}" "$expected_value" "${current_value:-missing}"
            differences=$((differences + 1))
        fi
    done < "$EXPECTED"
    if (( differences == 0 )); then
        printf 'No tracked userspace package differences.\n'
    fi

    printf '\n## Assessment\n\n'
    if [[ "$expected_version" == "$current_version" ]] && \
        [[ "$expected_build" == "$current_build" ]] && \
        [[ "$expected_abi" == "$current_abi" ]]; then
        printf 'The bundle matches this target exactly. Investigate ELF resolution, runtime logs, or compositor behavior rather than rebuilding solely for compatibility.\n'
    elif [[ "$expected_abi" == "$current_abi" ]]; then
        printf 'SteamOS release metadata changed but the tracked userspace compatibility hash is unchanged. A controlled override test is possible, but a target-specific rebuild remains the conservative default.\n'
    else
        printf 'The tracked userspace stack changed. Create a fresh target snapshot and rebuild before activation. If compilation fails, inspect the Fedora build failure report for the dependency or API that changed.\n'
    fi

    printf '\n## Suggested commands\n\n```bash\n'
    printf 'maintainer/sync-steamos-rootfs.sh\n'
    printf 'maintainer/enter-build-rootfs.sh\n'
    printf '# inside the rootfs: /repo/maintainer/build-bundle.sh\n'
    printf 'maintainer/publish-bundle.sh\n'
    printf '# on the Deck: ./steamos-waydroid-installer.sh --repair\n'
    printf '```\n'
} > "$OUTPUT_FILE"

if [[ "$OUTPUT_FILE" != /dev/stdout ]]; then
    printf 'Compatibility report saved: %s\n' "$OUTPUT_FILE"
fi
