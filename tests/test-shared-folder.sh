#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

TEST_HOME="$TEST_ROOT/user-home"
MOCK_BIN="$TEST_ROOT/bin"
MOCK_STATE="$TEST_ROOT/state"
MOCK_LOG="$TEST_ROOT/commands.log"
mkdir -p "$TEST_HOME" "$MOCK_BIN" "$MOCK_STATE"
: >"$MOCK_LOG"

fail() {
	printf 'not ok - %s\n' "$*" >&2
	exit 1
}

cat >"$MOCK_BIN/shared-folder-command" <<'EOF'
#!/usr/bin/env bash
set -u
command_name="$(basename -- "$0")"
printf '%s %s\n' "$command_name" "$*" >>"$MOCK_LOG"
case "$command_name" in
getent)
	[[ ${1:-} == passwd && ${2:-} == testuser ]] || exit 1
	printf 'testuser:x:1000:1000:Test User:%s:/bin/bash\n' "$TEST_HOME"
	;;
findmnt)
	target="${!#}"
	[[ ${1:-} == --mountpoint ]] || exit 2
	[[ -f "$MOCK_STATE/mounted" ]] || exit 1
	[[ "$(<"$MOCK_STATE/target")" == "$target" ]]
	;;
mount)
	[[ ${1:-} == --bind ]] || exit 2
	printf '%s\n' "$2" >"$MOCK_STATE/source"
	printf '%s\n' "$3" >"$MOCK_STATE/target"
	: >"$MOCK_STATE/mounted"
	printf 'mount\n' >>"$MOCK_STATE/counts"
	;;
umount)
	[[ -f "$MOCK_STATE/mounted" ]] || exit 1
	[[ "$(<"$MOCK_STATE/target")" == "${1:-}" ]] || exit 2
	rm -f -- "$MOCK_STATE/mounted"
	printf 'umount\n' >>"$MOCK_STATE/counts"
	;;
stat)
	path="${!#}"
	if [[ "$path" == "$(<"$MOCK_STATE/source")" ]] ||
		{ [[ -f "$MOCK_STATE/mounted" ]] &&
			[[ "$path" == "$(<"$MOCK_STATE/target")" ]]; }; then
		printf '42:100\n'
	else
		printf '42:200\n'
	fi
	;;
*) exit 127 ;;
esac
EOF
chmod +x "$MOCK_BIN/shared-folder-command"
for command_name in getent findmnt mount umount stat; do
	ln -s shared-folder-command "$MOCK_BIN/$command_name"
done

export PATH="$MOCK_BIN:/usr/bin:/bin"
export TEST_HOME MOCK_STATE MOCK_LOG
# shellcheck source=../libexec/steamos-waydroid/shared-folder.sh
source "$REPO_ROOT/libexec/steamos-waydroid/shared-folder.sh"

SHARE_SOURCE="$TEST_HOME/Waydroid Share"
SHARE_TARGET="$TEST_HOME/.local/share/waydroid/data/media/0/Waydroid Share"
ensure_waydroid_share_source "$TEST_HOME"
[[ -d "$SHARE_SOURCE" ]] || fail 'absent host share was not created'
[[ "$(/usr/bin/stat -c %u -- "$SHARE_SOURCE")" == "$(id -u)" ]] ||
	fail 'host share was not created as the invoking user'

printf 'preserve me\n' >"$SHARE_SOURCE/existing.txt"
chmod 0711 "$SHARE_SOURCE"
ensure_waydroid_share_source "$TEST_HOME"
[[ "$(<"$SHARE_SOURCE/existing.txt")" == 'preserve me' ]] ||
	fail 'existing share contents were modified'
[[ "$(/usr/bin/stat -c %a -- "$SHARE_SOURCE")" == 711 ]] ||
	fail 'existing share permissions were modified'

mount_waydroid_share "$TEST_HOME"
[[ -d "$SHARE_TARGET" ]] || fail 'Android-side mount target was not created'
[[ "$(grep -c '^mount$' "$MOCK_STATE/counts")" == 1 ]] ||
	fail 'absent shared-folder mount was not performed once'
mount_waydroid_share "$TEST_HOME"
[[ "$(grep -c '^mount$' "$MOCK_STATE/counts")" == 1 ]] ||
	fail 'correct existing bind mount was duplicated'

unmount_waydroid_share "$TEST_HOME"
[[ "$(grep -c '^umount$' "$MOCK_STATE/counts")" == 1 ]] ||
	fail 'mounted shared folder was not unmounted'
unmount_waydroid_share "$TEST_HOME"
[[ "$(grep -c '^umount$' "$MOCK_STATE/counts")" == 1 ]] ||
	fail 'already-unmounted shutdown was not idempotent'

resolved_home="$(HOME=/root SUDO_USER=testuser waydroid_user_home)"
[[ "$resolved_home" == "$TEST_HOME" ]] ||
	fail 'privileged home resolution used root instead of the invoking user'

printf 'ok - shared-folder creation, bind lifecycle, and user-home resolution\n'
