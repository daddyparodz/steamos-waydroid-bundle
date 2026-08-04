#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
CONFIG_FILE="${DECK_CONFIG_FILE:-$REPO_ROOT/.deck-config.env}"
FORCE=false
USE_TRUSTED_DEFAULTS=false
OFFICIAL_GITHUB_REPOSITORY="pjohno/steamos-waydroid-bundle"
OFFICIAL_RELEASE_TAG="bundles"
OFFICIAL_ARTIFACT_SOURCE="https://github.com/$OFFICIAL_GITHUB_REPOSITORY/releases/download/$OFFICIAL_RELEASE_TAG"

case "${1:-}" in
    "") ;;
    --force) FORCE=true ;;
    --defaults) USE_TRUSTED_DEFAULTS=true ;;
    *)
        printf 'usage: %s [--force | --defaults]\n' "$0" >&2
        exit 1
        ;;
esac

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

[[ ${STEAMOS_WAYDROID_INTERNAL:-} == 1 ]] || \
    die "this is an internal helper; run ./steamos-waydroid-installer.sh --configure-artifacts"

if [[ -e "$CONFIG_FILE" && "$FORCE" != true ]]; then
    printf 'Deck artifact configuration already exists: %s\n' "$CONFIG_FILE"
    exit 0
fi
if [[ "$USE_TRUSTED_DEFAULTS" != true ]]; then
    [[ -t 0 && -t 1 ]] || \
        die "interactive setup requires a terminal; copy libexec/steamos-waydroid/deck-config.example.env to .deck-config.env and edit it"
fi

detect_github_repository() {
    local remote_url repository_path
    remote_url="$(git -C "$REPO_ROOT" remote get-url origin 2> /dev/null || true)"
    case "$remote_url" in
        git@github.com:*) repository_path="${remote_url#git@github.com:}" ;;
        https://github.com/*) repository_path="${remote_url#https://github.com/}" ;;
        ssh://git@github.com/*) repository_path="${remote_url#ssh://git@github.com/}" ;;
        *) return 0 ;;
    esac
    repository_path="${repository_path%.git}"
    if [[ "$repository_path" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
        printf '%s\n' "$repository_path"
    fi
}

prompt_value() {
    local label="$1"
    local default_value="$2"
    local entered_value

    if [[ -n "$default_value" ]]; then
        printf '%s [%s]: ' "$label" "$default_value"
    else
        printf '%s: ' "$label"
    fi
    IFS= read -r entered_value || die "input ended before setup was complete"
    PROMPT_VALUE="${entered_value:-$default_value}"
}

artifact_source=""
github_repository=""
github_release_tag=""
bundle_version=auto

if [[ "$USE_TRUSTED_DEFAULTS" == true ]]; then
    artifact_source="$OFFICIAL_ARTIFACT_SOURCE"
    printf 'Using the official public bundle source:\n  %s\n' "$artifact_source"
else
    default_repository="$(detect_github_repository)"
    if [[ -z "$default_repository" ]]; then
        default_repository="$OFFICIAL_GITHUB_REPOSITORY"
    fi

    printf '\nSteamOS Waydroid advanced artifact setup\n\n'
    printf 'Bundles contain packages installed into SteamOS with root privileges.\n'
    printf 'Only select a source that you control or fully trust.\n\n'
    printf '  1. Public GitHub Release\n'
    printf '  2. Private GitHub Release (requires an authenticated gh command)\n'
    printf '  3. Fedora or another host over SSH/rsync\n'
    printf '  4. Public HTTP(S) artifact directory\n\n'
    prompt_value "Artifact source" "1"
    source_choice="$PROMPT_VALUE"

    case "$source_choice" in
        1)
            prompt_value "GitHub repository (OWNER/REPOSITORY)" "$default_repository"
            github_repository="$PROMPT_VALUE"
            [[ "$github_repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || \
                die "GitHub repository must use the OWNER/REPOSITORY form"
            prompt_value "Release tag" "$OFFICIAL_RELEASE_TAG"
            github_release_tag="$PROMPT_VALUE"
            [[ "$github_release_tag" =~ ^[A-Za-z0-9._-]+$ ]] || \
                die "release tag contains unsafe characters"
            artifact_source="https://github.com/$github_repository/releases/download/$github_release_tag"
            ;;
        2)
            prompt_value "GitHub repository (OWNER/REPOSITORY)" "$default_repository"
            github_repository="$PROMPT_VALUE"
            [[ "$github_repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || \
                die "GitHub repository must use the OWNER/REPOSITORY form"
            prompt_value "Release tag" "$OFFICIAL_RELEASE_TAG"
            github_release_tag="$PROMPT_VALUE"
            [[ "$github_release_tag" =~ ^[A-Za-z0-9._-]+$ ]] || \
                die "release tag contains unsafe characters"
            if command -v gh > /dev/null 2>&1; then
                github_cli="$(command -v gh)"
            elif [[ -x "$HOME/.local/bin/gh" ]]; then
                github_cli="$HOME/.local/bin/gh"
            else
                die "gh is required for a private GitHub Release; install and authenticate it first"
            fi
            "$github_cli" auth status --hostname github.com > /dev/null 2>&1 || \
                die "GitHub CLI is not authenticated; run gh auth login on the Deck"
            artifact_source=github-release
            ;;
        3)
            prompt_value "SSH artifact source (HOST_ALIAS:PATH)" \
                "fedora-build:steamos-waydroid-build/public/publish"
            artifact_source="$PROMPT_VALUE"
            [[ "$artifact_source" =~ ^[A-Za-z0-9_.@-]+:[A-Za-z0-9_./~-]+$ ]] || \
                die "SSH source must use the HOST_ALIAS:PATH form without spaces"
            ;;
        4)
            prompt_value "Public HTTP(S) artifact directory" ""
            artifact_source="$PROMPT_VALUE"
            [[ "$artifact_source" =~ ^https?://[^[:space:]]+$ ]] || \
                die "artifact directory must be an http:// or https:// URL without spaces"
            artifact_source="${artifact_source%/}"
            ;;
        *) die "artifact source must be 1, 2, 3, or 4" ;;
    esac

    prompt_value "Bundle version" "auto"
    bundle_version="$PROMPT_VALUE"
    [[ "$bundle_version" == auto || "$bundle_version" =~ ^[A-Za-z0-9._-]+$ ]] || \
        die "bundle version contains unsafe characters"

    printf '\nConfiguration summary:\n'
    printf '  artifact source: %s\n' "$artifact_source"
    if [[ "$artifact_source" == github-release ]]; then
        printf '  repository:      %s\n' "$github_repository"
        printf '  release tag:     %s\n' "$github_release_tag"
    fi
    printf '  bundle version:  %s\n\n' "$bundle_version"

    trusted_source=false
    if [[ "$artifact_source" == "$OFFICIAL_ARTIFACT_SOURCE" ]] || \
        [[ "$artifact_source" == github-release && \
           "$github_repository" == "$OFFICIAL_GITHUB_REPOSITORY" && \
           "$github_release_tag" == "$OFFICIAL_RELEASE_TAG" ]]; then
        trusted_source=true
    fi
    if [[ "$trusted_source" != true ]]; then
        printf 'WARNING: this is not the official bundle source. Its packages will be installed as root.\n'
        prompt_value "Type TRUST CUSTOM SOURCE to continue" ""
        [[ "$PROMPT_VALUE" == "TRUST CUSTOM SOURCE" ]] || \
            die "custom artifact source was not accepted"
    fi

    prompt_value "Write this configuration? (Y/n)" "Y"
    case "$PROMPT_VALUE" in
        Y|y|yes|YES|Yes) ;;
        *) die "configuration was not changed" ;;
    esac
fi

config_directory="$(dirname -- "$CONFIG_FILE")"
[[ -d "$config_directory" ]] || die "configuration directory does not exist: $config_directory"
staging_file="$(mktemp "$config_directory/.deck-config.env.XXXXXX")"
cleanup() {
    rm -f -- "$staging_file"
}
trap cleanup EXIT HUP INT TERM

{
    printf '# Generated by the SteamOS Waydroid artifact configurator.\n'
    printf '# This machine-local file is ignored by Git.\n'
    printf 'ARTIFACT_SOURCE=%q\n' "$artifact_source"
    if [[ "$artifact_source" == github-release ]]; then
        printf 'GITHUB_REPOSITORY=%q\n' "$github_repository"
        printf 'GITHUB_RELEASE_TAG=%q\n' "$github_release_tag"
    fi
    printf 'BUNDLE_VERSION=%q\n' "$bundle_version"
} > "$staging_file"
chmod 0600 "$staging_file"
mv -f -- "$staging_file" "$CONFIG_FILE"
trap - EXIT HUP INT TERM

printf '\nDeck artifact configuration saved: %s\n' "$CONFIG_FILE"
