#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

CONFIG_FILE="$TEST_ROOT/build-config.env"
cat >"$CONFIG_FILE" <<'EOF'
WLROOTS_VERSION=0.19.3
CAGE_VERSION=v0.2.1
EOF

config_values="$({
	BUILD_CONFIG_FILE="$CONFIG_FILE"
	source "$REPO_ROOT/maintainer/lib/common.sh"
	printf '%s|%s|%s\n' "$WLROOTS_VERSION" "$CAGE_VERSION" "$WLROOTS_API_VERSION"
})"
[[ "$config_values" == '0.19.3|v0.2.1|0.19' ]]

propagated_values="$(
	WLROOTS_VERSION=0.20.1 \
		CAGE_VERSION=v0.3.0 \
		BUILD_CONFIG_FILE="$CONFIG_FILE" \
		bash -c '
			source "$1/maintainer/lib/common.sh"
			printf "%s|%s|%s\n" "$WLROOTS_VERSION" "$CAGE_VERSION" "$WLROOTS_API_VERSION"
		' bash "$REPO_ROOT"
)"
[[ "$propagated_values" == '0.20.1|v0.3.0|0.20' ]]

grep -Fq -- '--setenv="WLROOTS_VERSION=$WLROOTS_VERSION"' \
	"$REPO_ROOT/maintainer/enter-build-rootfs.sh"
grep -Fq -- '--setenv="CAGE_VERSION=$CAGE_VERSION"' \
	"$REPO_ROOT/maintainer/enter-build-rootfs.sh"

printf 'ok - maintainer compositor versions propagate through the rootfs boundary\n'
