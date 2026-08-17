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
waydroid)
	attempt=0
	[[ ! -f "$MOCK_STATE/ready-attempts" ]] || attempt="$(<"$MOCK_STATE/ready-attempts")"
	attempt=$((attempt + 1))
	printf '%s\n' "$attempt" >"$MOCK_STATE/ready-attempts"
	[[ "$*" == 'shell -- am get-started-user-state 0' ]] || exit 2
	state="$(sed -n "${attempt}p" "$MOCK_STATE/user-states")"
	if [[ -z "$state" ]]; then
		state="$(tail -n 1 "$MOCK_STATE/user-states")"
	fi
	case "$state" in
	__UNAVAILABLE__) exit 1 ;;
	__EMPTY__) exit 0 ;;
	*) printf '%s\n' "$state" ;;
	esac
	;;
systemctl)
	if [[ ${1:-} == is-active ]]; then
		[[ ${MOCK_CONTAINER_ACTIVE:-true} == true ]]
	else
		printf 'mock Waydroid container status\n' >&2
	fi
	;;
sleep)
	printf 'sleep %s\n' "${1:-}" >>"$MOCK_STATE/counts"
	;;
*) exit 127 ;;
esac
EOF
chmod +x "$MOCK_BIN/shared-folder-command"
for command_name in getent findmnt mount umount stat waydroid systemctl sleep; do
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

mount_count_before="$(grep -c '^mount$' "$MOCK_STATE/counts")"

# Unavailable shell/state responses and all pre-unlock states must keep the
# readiness gate closed and continue polling.
for unavailable_state in __UNAVAILABLE__ __EMPTY__ BOOTING RUNNING_LOCKED; do
	printf '%s\n' "$unavailable_state" RUNNING_UNLOCKED >"$MOCK_STATE/user-states"
	rm -f -- "$MOCK_STATE/ready-attempts"
	MOCK_CONTAINER_ACTIVE=true wait_for_waydroid_emulated_storage 10 0
	[[ "$(<"$MOCK_STATE/ready-attempts")" == 2 ]] ||
		fail "$unavailable_state did not keep polling until RUNNING_UNLOCKED"
done
[[ "$(grep -c '^mount$' "$MOCK_STATE/counts")" == "$mount_count_before" ]] ||
	fail 'a pre-unlock state performed a bind mount'

# RUNNING_UNLOCKED is decisive even without the former package/path checks.
printf 'RUNNING_UNLOCKED\n' >"$MOCK_STATE/user-states"
rm -f -- "$MOCK_STATE/ready-attempts"
export MOCK_CONTAINER_ACTIVE=true
mount_waydroid_share_when_ready "$TEST_HOME" 10 0
[[ "$(<"$MOCK_STATE/ready-attempts")" == 1 ]] ||
	fail 'RUNNING_UNLOCKED did not immediately satisfy readiness'
[[ "$(grep -c '^mount$' "$MOCK_STATE/counts")" == $((mount_count_before + 1)) ]] ||
	fail 'share was not mounted after user 0 reached RUNNING_UNLOCKED'
unmount_waydroid_share "$TEST_HOME"

printf '%s\n' BOOTING RUNNING_LOCKED RUNNING_UNLOCKED >"$MOCK_STATE/user-states"
rm -f -- "$MOCK_STATE/ready-attempts"
mount_waydroid_share_when_ready "$TEST_HOME" 10 0
[[ "$(<"$MOCK_STATE/ready-attempts")" == 3 ]] ||
	fail 'delayed RUNNING_UNLOCKED state was not polled'
[[ "$(grep -c '^mount$' "$MOCK_STATE/counts")" == $((mount_count_before + 2)) ]] ||
	fail 'share was not mounted after delayed RUNNING_UNLOCKED state'

# A second post-readiness setup must recognize the existing bind rather than
# stacking another mount.
printf 'RUNNING_UNLOCKED\n' >"$MOCK_STATE/user-states"
mount_waydroid_share_when_ready "$TEST_HOME" 10 0
[[ "$(grep -c '^mount$' "$MOCK_STATE/counts")" == $((mount_count_before + 2)) ]] ||
	fail 'post-readiness setup duplicated the existing bind mount'
unmount_waydroid_share "$TEST_HOME"

printf 'BOOTING\n' >"$MOCK_STATE/user-states"
rm -f -- "$MOCK_STATE/ready-attempts"
if mount_waydroid_share_when_ready "$TEST_HOME" 0 0 \
	2>"$TEST_ROOT/readiness-timeout.log"; then
	fail 'RUNNING_UNLOCKED readiness timeout unexpectedly succeeded'
else
	readiness_status=$?
fi
[[ "$readiness_status" == 124 ]] ||
	fail "RUNNING_UNLOCKED readiness timeout returned $readiness_status instead of 124"
grep -Fq 'user 0 did not reach RUNNING_UNLOCKED within 0 seconds' \
	"$TEST_ROOT/readiness-timeout.log" ||
	fail 'readiness timeout did not report the required user state and timeout'
[[ "$(grep -c '^mount$' "$MOCK_STATE/counts")" == $((mount_count_before + 2)) ]] ||
	fail 'readiness timeout performed a bind mount'

rm -f -- "$MOCK_STATE/ready-attempts"
if MOCK_CONTAINER_ACTIVE=false mount_waydroid_share_when_ready "$TEST_HOME" 10 0 \
	2>"$TEST_ROOT/container-stopped.log"; then
	fail 'readiness wait succeeded after the container stopped'
else
	readiness_status=$?
fi
[[ "$readiness_status" == 1 ]] ||
	fail "stopped container returned $readiness_status instead of 1"
grep -Fq 'container stopped before Android user 0 reached RUNNING_UNLOCKED' \
	"$TEST_ROOT/container-stopped.log" ||
	fail 'stopped-container failure did not report the interrupted readiness state'
[[ "$(grep -c '^mount$' "$MOCK_STATE/counts")" == $((mount_count_before + 2)) ]] ||
	fail 'stopped container performed a bind mount'

if grep -Eq '(^|[[:space:]])mount_waydroid_share([[:space:]]|$)' \
	"$REPO_ROOT/extras/scripts/waydroid-mount"; then
	fail 'early Waydroid image mount phase still invokes the shared-folder bind'
fi
grep -Fq 'mount_waydroid_share_when_ready "$USER_HOME"' \
	"$REPO_ROOT/extras/scripts/waydroid-startup-scripts" ||
	fail 'post-startup script does not invoke the readiness-gated shared-folder bind'
ensure_line="$(grep -nF 'ensure_waydroid_share_source "$HOME"' \
	"$REPO_ROOT/extras/scripts/Android_Waydroid_Cage.sh" | cut -d: -f1)"
mount_phase_line="$(grep -nF 'sudo /usr/bin/waydroid-mount' \
	"$REPO_ROOT/extras/scripts/Android_Waydroid_Cage.sh" | cut -d: -f1)"
[[ -n "$ensure_line" && -n "$mount_phase_line" && "$ensure_line" -lt "$mount_phase_line" ]] ||
	fail 'launcher does not ensure the host share before the persistent-storage mount phase'

resolved_home="$(HOME=/root SUDO_USER=testuser waydroid_user_home)"
[[ "$resolved_home" == "$TEST_HOME" ]] ||
	fail 'privileged home resolution used root instead of the invoking user'

printf 'ok - shared-folder readiness, bind lifecycle, and user-home resolution\n'
