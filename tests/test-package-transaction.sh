#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

MOCK_BIN="$TEST_ROOT/bin"
mkdir -p "$MOCK_BIN"

for package_name in libglibutil libgbinder python-gbinder waydroid; do
	: >"$TEST_ROOT/$package_name.pkg.tar.zst"
done

cat >"$MOCK_BIN/bsdtar" <<'EOF'
#!/usr/bin/env bash
package_file="${2:-}"
package_name="$(basename -- "$package_file" .pkg.tar.zst)"
printf 'pkgname = %s\n' "$package_name"
EOF

cat >"$MOCK_BIN/pacman" <<'EOF'
#!/usr/bin/env bash
tr ' ' '\n' <<<"${PLANNED_PACKAGES:?PLANNED_PACKAGES is required}"
EOF
chmod +x "$MOCK_BIN/bsdtar" "$MOCK_BIN/pacman"

# shellcheck source=/dev/null
source "$REPO_ROOT/libexec/steamos-waydroid/installer-functions.sh"

packages=(
	"$TEST_ROOT/libglibutil.pkg.tar.zst"
	"$TEST_ROOT/libgbinder.pkg.tar.zst"
	"$TEST_ROOT/python-gbinder.pkg.tar.zst"
	"$TEST_ROOT/waydroid.pkg.tar.zst"
)

PATH="$MOCK_BIN:/usr/bin:/bin" \
	PLANNED_PACKAGES='libglibutil libgbinder python-gbinder waydroid' \
	verify_bundle_only_pacman_transaction "${packages[@]}" >/dev/null

if PATH="$MOCK_BIN:/usr/bin:/bin" \
	PLANNED_PACKAGES='libglibutil libgbinder python-gbinder waydroid unexpected-system-library' \
	verify_bundle_only_pacman_transaction "${packages[@]}" \
	>"$TEST_ROOT/output" 2>&1; then
	printf 'not ok - external Pacman dependency was accepted\n' >&2
	exit 1
fi
grep -Fq -- 'unexpected-system-library' "$TEST_ROOT/output"

if PATH="$MOCK_BIN:/usr/bin:/bin" \
	PLANNED_PACKAGES='libglibutil libgbinder python-gbinder' \
	verify_bundle_only_pacman_transaction "${packages[@]}" \
	>"$TEST_ROOT/output" 2>&1; then
	printf 'not ok - incomplete Pacman preview was accepted\n' >&2
	exit 1
fi
grep -Fq -- 'waydroid' "$TEST_ROOT/output"

if rg -n -- \
	'libdisplay-info\.so\.[0-9]|pacman -U[^\n]*--nodeps|pacman -U[^\n]*-d([[:space:]]|$)' \
	"$REPO_ROOT/maintainer/build-bundle.sh" \
	"$REPO_ROOT/libexec/steamos-waydroid/verify-bundle.sh" \
	"$REPO_ROOT/steamos-waydroid-installer.sh"; then
	printf 'not ok - historical SONAME pin or disabled dependency checking remains\n' >&2
	exit 1
fi

printf 'ok - package installation is bundle-only and SONAME-neutral\n'
