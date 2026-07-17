#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

require_non_root
for command_name in git sha256sum tar; do
    require_command "$command_name"
done

[[ "$BUNDLE_VERSION" =~ ^[A-Za-z0-9._-]+$ ]] || \
    die "BUNDLE_VERSION may contain only letters, numbers, dots, underscores, and hyphens"

BUNDLE_ROOT="$BUILD_WORK_ROOT/out/$BUNDLE_VERSION"
ARCHIVE_NAME="$BUNDLE_VERSION.tar.gz"
HASH_NAME="$ARCHIVE_NAME.sha256"
MANIFEST_NAME="$BUNDLE_VERSION.manifest"

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

mv \
    "$STAGING_ROOT/$ARCHIVE_NAME" \
    "$STAGING_ROOT/$HASH_NAME" \
    "$STAGING_ROOT/$MANIFEST_NAME" \
    "$PUBLISH_ROOT/"

printf '\nPublished private bundle:\n'
printf '  %s/%s\n' "$PUBLISH_ROOT" "$ARCHIVE_NAME"
printf 'The Deck can now pull and verify this artifact.\n'
