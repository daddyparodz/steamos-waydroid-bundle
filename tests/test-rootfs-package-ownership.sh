#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

MOCK_BIN="$TEST_ROOT/bin"
mkdir -p "$MOCK_BIN"

cat >"$MOCK_BIN/pacman" <<'EOF'
#!/usr/bin/env bash
printf '%s %s\n' "$1" "$2" >>"${PACMAN_LOG:?PACMAN_LOG is required}"
[[ $1 == -Q ]] || exit 2
if [[ $2 == "${INSTALLED_PACKAGE:-}" ]]; then
	printf '%s %s\n' "$2" "${INSTALLED_VERSION:?INSTALLED_VERSION is required}"
	exit 0
fi
exit 1
EOF
chmod +x "$MOCK_BIN/pacman"

# shellcheck source=/dev/null
source "$REPO_ROOT/maintainer/lib/common.sh"
# shellcheck source=/dev/null
source "$REPO_ROOT/maintainer/lib/package-ownership.sh"

packages=(libglibutil libgbinder python-gbinder waydroid)

PACMAN_LOG="$TEST_ROOT/pacman-absent.log" \
	PATH="$MOCK_BIN:/usr/bin:/bin" \
	require_bundle_owned_packages_absent "${packages[@]}" \
	>"$TEST_ROOT/absent-output"

grep -Fq -- 'Checking for SteamOS-provided packages that conflict with bundle ownership...' \
	"$TEST_ROOT/absent-output"
for package_name in "${packages[@]}"; do
	grep -Eq -- "^[[:space:]]+ABSENT[[:space:]]+$package_name$" \
		"$TEST_ROOT/absent-output"
	grep -Fxq -- "-Q $package_name" "$TEST_ROOT/pacman-absent.log"
done

if (
	PACMAN_LOG="$TEST_ROOT/pacman-installed.log" \
		INSTALLED_PACKAGE=libgbinder \
		INSTALLED_VERSION=1.1.55-1 \
		PATH="$MOCK_BIN:/usr/bin:/bin" \
		require_bundle_owned_packages_absent "${packages[@]}"
) >"$TEST_ROOT/installed-output" 2>"$TEST_ROOT/installed-error"; then
	printf 'not ok - an installed bundle-owned package was accepted\n' >&2
	exit 1
fi

grep -Eq -- '^[[:space:]]+UNEXPECTED[[:space:]]+libgbinder[[:space:]]+1\.1\.55-1$' \
	"$TEST_ROOT/installed-output"
grep -Fq -- 'SteamOS already provides package(s) currently owned by this bundle:' \
	"$TEST_ROOT/installed-error"
grep -Fq -- '  - libgbinder' "$TEST_ROOT/installed-error"
grep -Fq -- 'Host package ownership assumptions changed.' "$TEST_ROOT/installed-error"
grep -Fq -- 'Do not build or publish a bundle for this target' \
	"$TEST_ROOT/installed-error"

if grep -Fq -- '-Si' "$TEST_ROOT/pacman-absent.log" \
	"$TEST_ROOT/pacman-installed.log"; then
	printf 'not ok - package ownership check queried repository availability\n' >&2
	exit 1
fi

printf 'ok - copied rootfs rejects SteamOS-provided bundle-owned packages\n'
