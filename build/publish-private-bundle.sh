#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/target-fingerprint.sh
source "$SCRIPT_DIR/lib/target-fingerprint.sh"

require_non_root
for command_name in git sha256sum tar; do
    require_command "$command_name"
done

resolve_bundle_version

[[ -z "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=all)" ]] || \
    die "commit the package recipes and build changes before publishing"

[[ "$BUNDLE_VERSION" =~ ^[A-Za-z0-9._-]+$ ]] || \
    die "BUNDLE_VERSION may contain only letters, numbers, dots, underscores, and hyphens"

BUNDLE_ROOT="$BUILD_WORK_ROOT/out/$BUNDLE_VERSION"
ARCHIVE_NAME="$BUNDLE_VERSION.tar.gz"
HASH_NAME="$ARCHIVE_NAME.sha256"
MANIFEST_NAME="$BUNDLE_VERSION.manifest"
LATEST_MANIFEST_NAME="latest.manifest"
TARGETS_MANIFEST_NAME="targets.manifest"

[[ -d "$BUNDLE_ROOT" ]] || die "built bundle not found: $BUNDLE_ROOT"
[[ -f "$BUNDLE_ROOT/.verified" ]] || die "bundle has no verification marker"

mkdir -p "$PUBLISH_ROOT"
for published_file in "$ARCHIVE_NAME" "$HASH_NAME" "$MANIFEST_NAME"; do
    [[ ! -e "$PUBLISH_ROOT/$published_file" ]] || \
        die "published artifact already exists: $PUBLISH_ROOT/$published_file"
done

STAGING_ROOT="$(mktemp -d "$PUBLISH_ROOT/.publish-$BUNDLE_VERSION.XXXXXX")"
cleanup() {
    rm -rf -- "$STAGING_ROOT"
}
trap cleanup EXIT

printf 'Creating immutable bundle archive...\n'
tar -C "$BUILD_WORK_ROOT/out" \
    --sort=name \
    --owner=0 --group=0 --numeric-owner \
    -czf "$STAGING_ROOT/$ARCHIVE_NAME" \
    "$BUNDLE_VERSION"

(
    cd "$STAGING_ROOT"
    sha256sum "$ARCHIVE_NAME" > "$HASH_NAME"
)

SOURCE_REVISION="$(git -C "$REPO_ROOT" rev-parse HEAD)"
ARCHIVE_SHA256="$(sha256sum "$STAGING_ROOT/$ARCHIVE_NAME" | awk '{print $1}')"
cat > "$STAGING_ROOT/$MANIFEST_NAME" <<EOF
format=1
bundle_version=$BUNDLE_VERSION
source_revision=$SOURCE_REVISION
archive=$ARCHIVE_NAME
sha256=$ARCHIVE_SHA256
EOF
cat "$BUNDLE_ROOT/target-fingerprint.env" >> "$STAGING_ROOT/$MANIFEST_NAME"
cp "$STAGING_ROOT/$MANIFEST_NAME" "$STAGING_ROOT/$LATEST_MANIFEST_NAME"

# Maintain a mutable target index alongside the immutable artifacts. There is
# one preferred bundle per exact SteamOS target; already-published artifacts
# remain available when an older SteamOS image is restored.
TARGET_ENVIRONMENT_ID="$(fingerprint_value \
    "$BUNDLE_ROOT/target-fingerprint.env" TARGET_ENVIRONMENT_ID)"
[[ -n "$TARGET_ENVIRONMENT_ID" ]] || die "bundle target environment ID is missing"
CATALOG_ENTRIES="$STAGING_ROOT/targets.entries"
for candidate_manifest in "$PUBLISH_ROOT"/*.manifest; do
    [[ -r "$candidate_manifest" ]] || continue
    case "$(basename -- "$candidate_manifest")" in
        latest.manifest|targets.manifest) continue ;;
    esac
    candidate_target="$(fingerprint_value \
        "$candidate_manifest" TARGET_ENVIRONMENT_ID)"
    candidate_version="$(fingerprint_value "$candidate_manifest" bundle_version)"
    if [[ -n "$candidate_target" && "$candidate_version" =~ ^[A-Za-z0-9._-]+$ ]]; then
        printf '%s|%s\n' "$candidate_target" "$candidate_version" >> "$CATALOG_ENTRIES"
    fi
done
# Ensure this invocation wins when several revisions exist for one target.
printf '%s|%s\n' "$TARGET_ENVIRONMENT_ID" "$BUNDLE_VERSION" >> "$CATALOG_ENTRIES"
{
    printf 'format=1\n'
    awk -F '|' '{selected[$1]=$2} END {for (target in selected) print target "|" selected[target]}' \
        "$CATALOG_ENTRIES" | sort | sed 's/^/target=/'
} > "$STAGING_ROOT/$TARGETS_MANIFEST_NAME"

# Publish immutable files first and mutable pointers last. All files have
# already been prepared, so a catalog-generation failure cannot strand an
# immutable artifact without a target index entry.
mv \
    "$STAGING_ROOT/$ARCHIVE_NAME" \
    "$STAGING_ROOT/$HASH_NAME" \
    "$STAGING_ROOT/$MANIFEST_NAME" \
    "$PUBLISH_ROOT/"
mv -f \
    "$STAGING_ROOT/$LATEST_MANIFEST_NAME" \
    "$STAGING_ROOT/$TARGETS_MANIFEST_NAME" \
    "$PUBLISH_ROOT/"

printf '\nPublished private bundle:\n'
printf '  %s/%s\n' "$PUBLISH_ROOT" "$ARCHIVE_NAME"
printf '  %s/%s\n' "$PUBLISH_ROOT" "$TARGETS_MANIFEST_NAME"
printf 'The Deck can now pull and verify this artifact.\n'
