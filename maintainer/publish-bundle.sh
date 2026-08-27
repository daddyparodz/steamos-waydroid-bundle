#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=../libexec/steamos-waydroid/lib/target-fingerprint.sh
source "$REPO_ROOT/libexec/steamos-waydroid/lib/target-fingerprint.sh"

PROMOTE=false
while (($#)); do
	case "$1" in
	--promote)
		PROMOTE=true
		;;
	-h | --help)
		cat <<'EOF'
Usage: publish-bundle.sh [--promote]

Publish the selected bundle.

The first bundle published for a target automatically becomes preferred.
Later bundles do not replace the preferred bundle unless --promote is used.
EOF
		exit 0
		;;
	*)
		die "unknown argument: $1"
		;;
	esac
	shift
done

require_non_root
for command_name in git sha256sum tar; do
	require_command "$command_name"
done

resolve_bundle_version

if [[ "${ALLOW_DIRTY_PUBLISH:-0}" != 1 ]]; then
	[[ -z "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=all)" ]] ||
		die "commit the package recipes and build changes before publishing, or set ALLOW_DIRTY_PUBLISH=1 for testing"
fi

[[ "$BUNDLE_VERSION" =~ ^[A-Za-z0-9._-]+$ ]] ||
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
	[[ ! -e "$PUBLISH_ROOT/$published_file" ]] ||
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
	sha256sum "$ARCHIVE_NAME" >"$HASH_NAME"
)

SOURCE_REVISION="$(git -C "$REPO_ROOT" rev-parse HEAD)"
ARCHIVE_SHA256="$(sha256sum "$STAGING_ROOT/$ARCHIVE_NAME" | awk '{print $1}')"

cat >"$STAGING_ROOT/$MANIFEST_NAME" <<EOF
format=1
bundle_version=$BUNDLE_VERSION
source_revision=$SOURCE_REVISION
archive=$ARCHIVE_NAME
sha256=$ARCHIVE_SHA256
EOF

cat "$BUNDLE_ROOT/target-fingerprint.env" >>"$STAGING_ROOT/$MANIFEST_NAME"
cp "$STAGING_ROOT/$MANIFEST_NAME" "$STAGING_ROOT/$LATEST_MANIFEST_NAME"

TARGET_ENVIRONMENT_ID="$(fingerprint_value \
	"$BUNDLE_ROOT/target-fingerprint.env" TARGET_ENVIRONMENT_ID)"
[[ -n "$TARGET_ENVIRONMENT_ID" ]] || die "bundle target environment ID is missing"
ABI_SHA256="$(fingerprint_value "$BUNDLE_ROOT/target-fingerprint.env" ABI_SHA256)"
[[ "$ABI_SHA256" =~ ^[0-9a-f]{64}$ ]] || die "bundle ABI fingerprint is missing or invalid"

CATALOG_ENTRIES="$STAGING_ROOT/targets.entries"

for candidate_manifest in "$PUBLISH_ROOT"/*.manifest; do
	[[ -r "$candidate_manifest" ]] || continue
	case "$(basename -- "$candidate_manifest")" in
	latest.manifest | targets.manifest) continue ;;
	esac

	candidate_target="$(fingerprint_value \
		"$candidate_manifest" TARGET_ENVIRONMENT_ID)"
	candidate_version="$(fingerprint_value "$candidate_manifest" bundle_version)"
	candidate_abi="$(fingerprint_value "$candidate_manifest" ABI_SHA256)"

	if [[ -n "$candidate_target" && "$candidate_version" =~ ^[A-Za-z0-9._-]+$ ]]; then
		printf 'target|%s|%s\n' "$candidate_target" "$candidate_version" >>"$CATALOG_ENTRIES"
		if [[ "$candidate_abi" =~ ^[0-9a-f]{64}$ ]]; then
			printf 'abi|%s|%s\n' "$candidate_abi" "$candidate_version" >>"$CATALOG_ENTRIES"
		fi
	fi
done

existing_bundle=""

if [[ -r "$PUBLISH_ROOT/$TARGETS_MANIFEST_NAME" ]]; then
	existing_bundle="$(
		awk -F '[=|]' -v target="$TARGET_ENVIRONMENT_ID" \
			'$1 == "target" && $2 == target {print $3; exit}' \
			"$PUBLISH_ROOT/$TARGETS_MANIFEST_NAME"
	)"
fi

existing_abi_bundle=""
if [[ -r "$PUBLISH_ROOT/$TARGETS_MANIFEST_NAME" ]]; then
	existing_abi_bundle="$(
		awk -F '[=|]' -v abi="$ABI_SHA256" \
			'$1 == "abi" && $2 == abi {print $3; exit}' \
			"$PUBLISH_ROOT/$TARGETS_MANIFEST_NAME"
	)"
fi

if [[ -z "$existing_bundle" ]]; then
	preferred_bundle="$BUNDLE_VERSION"

	printf 'No preferred bundle exists for this target.\n'
	printf 'Selecting initial preferred bundle:\n'
	printf '  %s\n' "$preferred_bundle"

elif [[ "$existing_bundle" == "$BUNDLE_VERSION" ]]; then
	preferred_bundle="$existing_bundle"

	printf 'Bundle is already preferred for this target:\n'
	printf '  %s\n' "$preferred_bundle"

elif $PROMOTE; then
	preferred_bundle="$BUNDLE_VERSION"

	printf 'Promoting preferred bundle:\n'
	printf '  previous: %s\n' "$existing_bundle"
	printf '  new:      %s\n' "$preferred_bundle"

else
	preferred_bundle="$existing_bundle"

	printf 'Preferred bundle remains:\n'
	printf '  %s\n' "$preferred_bundle"
	printf 'Publishing without promotion:\n'
	printf '  %s\n' "$BUNDLE_VERSION"
fi

if [[ -z "$existing_abi_bundle" || "$existing_abi_bundle" == "$BUNDLE_VERSION" ]] || $PROMOTE; then
	preferred_abi_bundle="$BUNDLE_VERSION"
else
	preferred_abi_bundle="$existing_abi_bundle"
fi

printf 'target|%s|%s\n' \
	"$TARGET_ENVIRONMENT_ID" \
	"$preferred_bundle" \
	>>"$CATALOG_ENTRIES"
printf 'abi|%s|%s\n' \
	"$ABI_SHA256" \
	"$preferred_abi_bundle" \
	>>"$CATALOG_ENTRIES"

{
	printf 'format=2\n'
	awk -F '|' \
		'{selected[$1 FS $2]=$3} END {for (key in selected) print key "|" selected[key]}' \
		"$CATALOG_ENTRIES" |
		sort |
		sed 's/|/=/1'
} >"$STAGING_ROOT/$TARGETS_MANIFEST_NAME"

mv \
	"$STAGING_ROOT/$ARCHIVE_NAME" \
	"$STAGING_ROOT/$HASH_NAME" \
	"$STAGING_ROOT/$MANIFEST_NAME" \
	"$PUBLISH_ROOT/"

mv -f \
	"$STAGING_ROOT/$LATEST_MANIFEST_NAME" \
	"$STAGING_ROOT/$TARGETS_MANIFEST_NAME" \
	"$PUBLISH_ROOT/"

printf '\nPublished target-built bundle:\n'
printf '  %s/%s\n' "$PUBLISH_ROOT" "$ARCHIVE_NAME"
printf '  %s/%s\n' "$PUBLISH_ROOT" "$TARGETS_MANIFEST_NAME"
printf 'The Deck can now pull and verify this artifact.\n'
